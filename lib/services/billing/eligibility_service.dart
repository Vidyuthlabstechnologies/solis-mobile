import '../../models/patient_account.dart';
import '../account_repository.dart';
import '../integrations.dart';
import 'clearinghouse.dart';

/// How an eligibility summary reads on the visit and the claim.
enum EligibilityState { notChecked, active, inactive, failed }

/// Real-time eligibility (270/271), shared by the chart, the visit and the
/// claim. Results are saved on the visit so the copay and coverage are known
/// before the patient leaves.
class EligibilityService {
  final AccountRepository _repo;
  final ClearinghouseClient? Function() _client;
  final DateTime Function() _now;

  EligibilityService({AccountRepository? repo, ClearinghouseClient? Function()? client, DateTime Function()? now})
      : _repo = repo ?? AccountRepository.instance,
        _client = client ?? Integrations.clearinghouse,
        _now = now ?? DateTime.now;

  /// A check older than this is run again automatically.
  static const maxAge = Duration(hours: 24);

  bool get isConfigured => _client() != null;

  /// True when [visit] has no check for its date of service, or the last one
  /// is older than [maxAge].
  bool isStale(Visit visit) {
    final e = visit.eligibility;
    if (e == null) return true;
    if (e['dateOfService'] != null && e['dateOfService'] != visit.dateOfService) return true;
    final at = DateTime.tryParse(e['checkedAtUtc']?.toString() ?? '');
    return at == null || _now().toUtc().difference(at) > maxAge;
  }

  /// Runs the check for [visitNumber] when it is missing or stale and a
  /// clearinghouse and payer ID are available. Never throws; returns the
  /// saved summary, or null when nothing was run.
  Future<Map<String, dynamic>?> ensureFresh(String accountNumber, int visitNumber) async {
    final visit = _repo.byNumber(accountNumber)?.visit(visitNumber);
    if (visit == null || !isStale(visit)) return null;
    return check(accountNumber, visitNumber: visitNumber);
  }

  /// Runs the check and saves it on the visit (or returns it unsaved when
  /// there is no visit). Returns null when no clearinghouse or payer ID is
  /// set. Network failures are saved as a failed check, not thrown.
  Future<Map<String, dynamic>?> check(String accountNumber, {int? visitNumber}) async {
    final client = _client();
    final account = _repo.byNumber(accountNumber);
    final ins = account?.insurance;
    if (client == null || account == null || ins == null || (ins.payerId ?? '').isEmpty) return null;
    final visit = visitNumber == null ? null : account.visit(visitNumber);
    final dos = visit?.dateOfService ?? _now().toIso8601String().split('T').first;
    Map<String, dynamic> summary;
    try {
      final r = await client.checkEligibility(EligibilityRequest(account: account, provider: _repo.provider, payerId: ins.payerId!, dateOfService: dos));
      summary = summarize(r, dateOfService: dos, now: _now());
    } catch (e) {
      summary = {
        'checkedAtUtc': _now().toUtc().toIso8601String(),
        'dateOfService': dos,
        'success': false,
        'errors': ['Could not reach the clearinghouse'],
      };
    }
    if (visit != null) {
      final latest = _repo.byNumber(accountNumber)?.visit(visit.number);
      if (latest != null) await _repo.updateVisit(accountNumber, latest.copyWith(eligibility: summary));
    }
    return summary;
  }

  static Map<String, dynamic> summarize(EligibilityResult r, {required String dateOfService, DateTime? now}) => {
        'checkedAtUtc': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'dateOfService': dateOfService,
        'success': r.success,
        'active': r.activeCoverage,
        'planName': r.planName,
        'copay': r.copay,
        'coinsurancePercent': r.coinsurancePercent,
        'deductibleRemaining': r.deductibleRemaining,
        'outOfPocketRemaining': r.outOfPocketRemaining,
        'testMode': r.testMode,
        'errors': r.errors.map((e) => e.description).toList(),
      };

  static EligibilityState stateOf(Map<String, dynamic>? e) {
    if (e == null) return EligibilityState.notChecked;
    if (e['success'] != true) return EligibilityState.failed;
    if (e['active'] == false) return EligibilityState.inactive;
    return EligibilityState.active;
  }

  /// One line for the visit and the claim: "Active, copay $25 to collect".
  /// Only what the payer returned; nothing is filled in.
  static String describe(Map<String, dynamic>? e, {bool configured = true}) {
    switch (stateOf(e)) {
      case EligibilityState.notChecked:
        return configured ? 'Coverage not checked yet' : 'Coverage not checked. Connect a clearinghouse in Integrations.';
      case EligibilityState.failed:
        final errors = e!['errors'] as List?;
        return 'Coverage check failed${errors?.isNotEmpty == true ? ': ${errors!.first}' : ''}';
      case EligibilityState.inactive:
        return 'Coverage not active for the date of service';
      case EligibilityState.active:
        return [
          if (e!['active'] == true) 'Active' else 'Coverage found',
          if (e['copay'] != null) 'copay \$${e['copay']} to collect',
          if (e['coinsurancePercent'] != null) 'coinsurance ${e['coinsurancePercent']}%',
          if (e['deductibleRemaining'] != null) 'deductible left \$${e['deductibleRemaining']}',
          if (e['testMode'] == true) 'test mode',
        ].join(', ');
    }
  }
}
