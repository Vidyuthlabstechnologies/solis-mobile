import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/patient_account.dart';
import '../models/provider_profile.dart';
import 'patient_merge.dart';

/// Local store for patient accounts, visits and the provider profile.
///
/// Data lives in the app's private support directory, which Android encrypts
/// at rest with file-based encryption and which other apps cannot read.
///
/// Concurrency: changes to the in-memory lists are synchronous (no await
/// between reading and replacing an account), so two callers can never
/// interleave a read-modify-write. Disk writes go through one queue: each
/// write takes a snapshot when it is queued and runs after the previous one
/// finished, so the file always ends at the latest state and two writes never
/// share a temp file. Each write goes to a uniquely named temp file that is
/// flushed and then renamed over the target, so a crash mid-write never leaves
/// a half-written file. [eraseAll] runs in the same queue, so a write queued
/// before it cannot bring deleted data back.
class AccountRepository extends ChangeNotifier {
  AccountRepository._(this._directory);

  /// In-memory repository for tests and previews.
  AccountRepository.memory() : _directory = null;

  static AccountRepository? _instance;
  static AccountRepository get instance => _instance ??= AccountRepository.memory();

  /// Opens the on-device store and makes it the shared instance.
  static Future<AccountRepository> open() async {
    final dir = await getApplicationSupportDirectory();
    final repo = AccountRepository._(dir);
    await repo._load();
    _instance = repo;
    return repo;
  }

  @visibleForTesting
  static set instance(AccountRepository repo) => _instance = repo;

  /// Opens a store in [dir] (tests use a temp directory).
  @visibleForTesting
  static Future<AccountRepository> openAt(Directory dir) async {
    final repo = AccountRepository._(dir);
    await repo._load();
    return repo;
  }

  final Directory? _directory;
  final List<PatientAccount> _accounts = [];
  ProviderProfile _provider = ProviderProfile.empty();
  ProviderProfile _demoProvider = ProviderProfile.demo();
  int _nextSequence = 1000001;
  bool _demoMode = false;

  /// How long a deleted patient stays restorable before it is erased.
  static const softDeleteWindow = Duration(days: 30);

  /// Demo mode shows only sample patients and the demo provider; a signed-in
  /// clinician sees only their own patients and their own profile. The two
  /// never mix, so a fictional identity can never reach a real claim.
  bool get demoMode => _demoMode;

  void setDemoMode(bool on) {
    if (_demoMode == on) return;
    _demoMode = on;
    notifyListeners();
  }

  /// Patients of the current mode, newest first, without deleted ones.
  List<PatientAccount> get accounts =>
      List.unmodifiable(_accounts.where((a) => !a.isDeleted && a.isSample == _demoMode));

  /// Deleted patients of the current mode that can still be restored.
  List<PatientAccount> get recentlyDeleted =>
      List.unmodifiable(_accounts.where((a) => a.isDeleted && a.isSample == _demoMode));

  /// The billing identity in use: the clinician's own profile, or the demo
  /// provider in demo mode.
  ProviderProfile get provider => _demoMode ? _demoProvider : _provider;

  File? get _accountsFile => _directory == null ? null : File('${_directory.path}/solis_accounts.json');
  File? get _providerFile => _directory == null ? null : File('${_directory.path}/solis_provider.json');

  Future<void> _load() async {
    try {
      final f = _accountsFile;
      if (f != null && await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _nextSequence = data['nextSequence'] ?? _nextSequence;
        _accounts
          ..clear()
          ..addAll([for (final a in (data['accounts'] as List? ?? const [])) PatientAccount.fromJson((a as Map).cast<String, dynamic>())]);
      }
      final p = _providerFile;
      if (p != null && await p.exists()) {
        final saved = ProviderProfile.fromJson(jsonDecode(await p.readAsString()) as Map<String, dynamic>);
        // Older builds saved the demo provider as everyone's starting profile.
        // It is fiction, so a real clinician starts from an empty profile.
        _provider = saved.isDemoIdentity ? ProviderProfile.empty() : saved;
      }
      _purgeExpired();
    } catch (e) {
      debugPrint('Account store could not be read: $e');
    }
  }

  /// Tail of the disk queue. Every write and erase chains onto it.
  Future<void> _diskQueue = Future.value();
  int _tmpCounter = 0;

  /// Runs [job] after every earlier disk job has finished. A failing job is
  /// logged and does not stop the queue.
  Future<void> _enqueue(String what, Future<void> Function() job) {
    final next = _diskQueue.then((_) => job()).catchError((Object e) {
      debugPrint('$what failed: $e');
    });
    _diskQueue = next;
    return next;
  }

  /// Completes when every queued disk write has finished.
  Future<void> flush() => _diskQueue;

  Future<void> _save() {
    notifyListeners();
    final f = _accountsFile;
    if (f == null) return Future.value();
    // Snapshot now: later changes queue their own write.
    final contents = jsonEncode({'nextSequence': _nextSequence, 'accounts': _accounts.map((a) => a.toJson()).toList()});
    return _enqueue('Account store write', () => _atomicWrite(f, contents));
  }

  Future<void> _atomicWrite(File target, String contents) async {
    final tmp = File('${target.path}.${pid}_${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsString(contents, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> saveProvider(ProviderProfile profile) {
    if (_demoMode) {
      // Demo edits stay in memory and never touch the clinician's profile.
      _demoProvider = profile;
      notifyListeners();
      return Future.value();
    }
    _provider = profile;
    notifyListeners();
    final p = _providerFile;
    if (p == null) return Future.value();
    final contents = jsonEncode(profile.toJson());
    return _enqueue('Provider profile write', () => _atomicWrite(p, contents));
  }

  /// Removes every patient account, visit and the saved provider profile from
  /// this phone. Used when the clinician deletes their SOLIS account.
  Future<void> eraseAll() {
    _accounts.clear();
    _provider = ProviderProfile.empty();
    _demoProvider = ProviderProfile.demo();
    _nextSequence = 1000001;
    notifyListeners();
    return _enqueue('Local data erase', () async {
      for (final f in [_accountsFile, _providerFile]) {
        if (f != null && await f.exists()) await f.delete();
      }
    });
  }

  /// Account numbers are SOL- plus a 6-digit sequence and a Luhn check digit,
  /// so a mistyped number is caught before it reaches a claim.
  String _newAccountNumber() {
    String number;
    do {
      final base = '${_nextSequence++}';
      number = 'SOL-$base${_luhnDigit(base)}';
    } while (_accounts.any((a) => a.accountNumber == number));
    return number;
  }

  static int _luhnDigit(String digits) {
    var sum = 0;
    var dbl = true;
    for (var i = digits.length - 1; i >= 0; i--) {
      var d = int.parse(digits[i]);
      if (dbl) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
      dbl = !dbl;
    }
    return (10 - sum % 10) % 10;
  }

  static bool isValidAccountNumber(String n) {
    final m = RegExp(r'^SOL-(\d+)(\d)$').firstMatch(n.trim().toUpperCase());
    return m != null && _luhnDigit(m.group(1)!) == int.parse(m.group(2)!);
  }

  PatientAccount? byNumber(String accountNumber) {
    for (final a in _accounts) {
      if (a.accountNumber == accountNumber && !a.isDeleted) return a;
    }
    return null;
  }

  Future<PatientAccount> createAccount({
    required String firstName,
    required String lastName,
    String? middleName,
    DateTime? dateOfBirth,
    PatientSex sex = PatientSex.unknown,
    String? addressLine1,
    String? city,
    String? state,
    String? zip,
    String? phone,
    String? driverLicenseNumber,
    String? driverLicenseState,
    String? ssnLast4,
    InsuranceCoverage? insurance,
    String? sampleConversationKey,
    bool? isSample,
  }) async {
    final account = PatientAccount(
      isSample: isSample ?? _demoMode,
      accountNumber: _newAccountNumber(),
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      middleName: middleName?.trim().isEmpty ?? true ? null : middleName!.trim(),
      dateOfBirth: dateOfBirth,
      sex: sex,
      addressLine1: addressLine1,
      city: city,
      state: state,
      zip: zip,
      phone: phone,
      driverLicenseNumber: driverLicenseNumber,
      driverLicenseState: driverLicenseState,
      ssnLast4: ssnLast4,
      insurance: insurance,
      createdAtUtc: DateTime.now().toUtc(),
      sampleConversationKey: sampleConversationKey,
    );
    _accounts.insert(0, account);
    await _save();
    return account;
  }

  Future<void> updateAccount(PatientAccount account) async {
    final i = _accounts.indexWhere((a) => a.accountNumber == account.accountNumber);
    if (i < 0) return;
    _accounts[i] = account;
    await _save();
  }

  /// Hides a patient (soft delete). The account stays restorable for
  /// [softDeleteWindow], then it is erased for good.
  Future<PatientAccount?> deletePatient(String accountNumber, {DateTime? now}) async {
    final i = _accounts.indexWhere((a) => a.accountNumber == accountNumber);
    if (i < 0 || _accounts[i].isDeleted) return null;
    final deleted = _accounts[i].copyWith(deletedAtUtc: (now ?? DateTime.now()).toUtc());
    _accounts[i] = deleted;
    await _save();
    return deleted;
  }

  /// Merges the [duplicate] chart into [keep] (see [planMerge]). The
  /// duplicate is soft-deleted, so the merge can be undone by restoring it
  /// within [softDeleteWindow]; its visits stay on the kept chart.
  Future<MergePlan> mergePatients(String keep, String duplicate, {DateTime? now}) async {
    final a = byNumber(keep);
    final b = byNumber(duplicate);
    if (a == null || b == null || a.isDeleted || b.isDeleted) {
      return MergePlan(merged: a ?? b!, blocked: 'One of the charts no longer exists.');
    }
    final plan = planMerge(a, b);
    if (plan.blocked != null) return plan;
    final ia = _accounts.indexWhere((x) => x.accountNumber == keep);
    final ib = _accounts.indexWhere((x) => x.accountNumber == duplicate);
    _accounts[ia] = plan.merged;
    _accounts[ib] = b.copyWith(deletedAtUtc: (now ?? DateTime.now()).toUtc(), visits: const []);
    await _save();
    return plan;
  }

  /// Brings back a patient deleted within [softDeleteWindow].
  Future<bool> restorePatient(String accountNumber) async {
    final i = _accounts.indexWhere((a) => a.accountNumber == accountNumber);
    if (i < 0 || !_accounts[i].isDeleted) return false;
    _accounts[i] = _accounts[i].copyWith(restore: true);
    await _save();
    return true;
  }

  /// Erases patients whose soft-delete window has passed.
  @visibleForTesting
  Future<int> purgeExpired({DateTime? now}) async {
    final n = _purgeExpired(now: now);
    if (n > 0) await _save();
    return n;
  }

  int _purgeExpired({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(softDeleteWindow);
    final before = _accounts.length;
    _accounts.removeWhere((a) => a.deletedAtUtc != null && a.deletedAtUtc!.isBefore(cutoff));
    return before - _accounts.length;
  }

  /// Finds existing accounts that match scanned details: same member ID, or
  /// same name and date of birth. Prevents duplicate charts for one person.
  List<PatientAccount> findMatches({String? memberId, String? firstName, String? lastName, DateTime? dateOfBirth}) {
    String n(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return accounts.where((a) {
      if (memberId != null && n(memberId).length >= 5 && n(a.insurance?.memberId) == n(memberId)) return true;
      final sameName = n(a.lastName) == n(lastName) && n(a.firstName) == n(firstName) && n(lastName).isNotEmpty;
      if (!sameName) return false;
      if (dateOfBirth == null || a.dateOfBirth == null) return true;
      return a.dateOfBirth!.year == dateOfBirth.year && a.dateOfBirth!.month == dateOfBirth.month && a.dateOfBirth!.day == dateOfBirth.day;
    }).toList();
  }

  /// Opens the next numbered visit for a date of service.
  Future<Visit> addVisit(String accountNumber, {required DateTime dateOfService, required String placeOfService, String? posSource}) async {
    final account = byNumber(accountNumber)!;
    final number = account.visits.fold<int>(0, (m, v) => max(m, v.number)) + 1;
    final visit = Visit(
      number: number,
      dateOfService: dateOfService.toIso8601String().split('T').first,
      placeOfService: placeOfService,
      createdAtUtc: DateTime.now().toUtc(),
      posSource: posSource,
    );
    await updateAccount(account.copyWith(visits: [...account.visits, visit]));
    return visit;
  }

  Future<void> updateVisit(String accountNumber, Visit visit) async {
    final account = byNumber(accountNumber);
    if (account == null) return;
    await updateAccount(account.copyWith(visits: [for (final v in account.visits) v.number == visit.number ? visit : v]));
  }

  /// Removes a visit entirely (accidental recordings must not leave a record).
  Future<void> deleteVisit(String accountNumber, int visitNumber) async {
    final account = byNumber(accountNumber);
    if (account == null) return;
    await updateAccount(account.copyWith(visits: account.visits.where((v) => v.number != visitNumber).toList()));
  }

  /// Turns on demo mode and seeds the sample patients the first time, so the
  /// app can be tried end to end. Only demo mode calls this; a signed-in
  /// clinician never sees these patients.
  Future<void> seedDemoIfEmpty() async {
    setDemoMode(true);
    if (_accounts.any((a) => a.isSample)) return;
    final samples = [
      ('Marcus', 'Thorne', DateTime(1981, 3, 14), PatientSex.male,
          const InsuranceCoverage(payerName: 'Cigna', memberId: 'U48213907', groupNumber: '3341870', planType: 'PPO', planName: 'Open Access Plus', payerId: '62308', rxBin: '017010', rxPcn: '02950000', copays: {'PCP': '\$30', 'Specialist': '\$60'}),
          'Acute Migraine with Aura'),
      ('Elena', 'Rostova', DateTime(1974, 9, 2), PatientSex.female,
          const InsuranceCoverage(payerName: 'UnitedHealthcare', memberId: '9174452031', groupNumber: '705214', planType: 'Choice Plus', payerId: '87726', copays: {'PCP': '\$25', 'ER': '\$300'}),
          'Community-Acquired Pneumonia'),
      ('David', 'Miller', DateTime(1992, 6, 21), PatientSex.male,
          const InsuranceCoverage(payerName: 'Blue Cross Blue Shield', memberId: 'XYZ882410397', groupNumber: '00412', planType: 'PPO', payerId: '00590', copays: {'PCP': '\$20', 'Specialist': '\$45'}),
          'Right Knee Meniscus Injury'),
      ('Robert', 'Hayes', DateTime(1968, 1, 30), PatientSex.male,
          const InsuranceCoverage(payerName: 'Medicare', memberId: '1EG4TE5MK73', planType: 'Medicare Part B', payerId: '01112'),
          'Acute Inferior STEMI'),
      ('Margaret', 'Vance', DateTime(1959, 11, 8), PatientSex.female,
          const InsuranceCoverage(payerName: 'Aetna', memberId: 'W281947365', groupNumber: '285214-010', planType: 'PPO', payerId: '60054', rxBin: '610502', rxPcn: 'MEDDAET', copays: {'PCP': '\$25', 'Specialist': '\$50'}),
          'Diabetic Peripheral Neuropathy'),
    ];
    for (final s in samples) {
      await createAccount(
        firstName: s.$1,
        lastName: s.$2,
        dateOfBirth: s.$3,
        sex: s.$4,
        insurance: s.$5,
        city: 'San Francisco',
        state: 'CA',
        sampleConversationKey: s.$6,
        isSample: true,
      );
    }
  }
}
