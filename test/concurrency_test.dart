import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/billing/claim_idempotency.dart';
import 'package:solis_mobile/services/net/pinned_http.dart';
import 'package:solis_mobile/services/net/pinned_roots.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('solis_repo_'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  List<String> leftovers() => dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')).toList();

  group('AccountRepository under concurrent use', () {
    test('50 concurrent creates: unique account numbers, all on disk, no temp files', () async {
      final repo = await AccountRepository.openAt(dir);
      await Future.wait([
        for (var i = 0; i < 50; i++) repo.createAccount(firstName: 'P$i', lastName: 'Test'),
      ]);
      await repo.flush();
      final numbers = repo.accounts.map((a) => a.accountNumber).toSet();
      expect(numbers, hasLength(50));
      expect(numbers.every(AccountRepository.isValidAccountNumber), isTrue);

      final reopened = await AccountRepository.openAt(dir);
      expect(reopened.accounts.map((a) => a.accountNumber).toSet(), numbers);
      expect(leftovers(), isEmpty);
      // The file is complete JSON (a torn write would not parse).
      final raw = jsonDecode(File('${dir.path}/solis_accounts.json').readAsStringSync()) as Map;
      expect((raw['accounts'] as List), hasLength(50));
    });

    test('concurrent visits on one account get distinct numbers and all persist', () async {
      final repo = await AccountRepository.openAt(dir);
      final a = await repo.createAccount(firstName: 'Ada', lastName: 'Lovelace');
      final visits = await Future.wait([
        for (var i = 0; i < 10; i++) repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 1 + i), placeOfService: '11'),
      ]);
      expect(visits.map((v) => v.number).toSet(), {for (var i = 1; i <= 10; i++) i});
      await repo.flush();
      final reopened = await AccountRepository.openAt(dir);
      expect(reopened.byNumber(a.accountNumber)!.visits, hasLength(10));
    });

    test('interleaved updates end with the latest state on disk', () async {
      final repo = await AccountRepository.openAt(dir);
      final a = await repo.createAccount(firstName: 'Ada', lastName: 'Lovelace');
      final futures = <Future<void>>[];
      for (var i = 0; i < 30; i++) {
        futures.add(repo.updateAccount(repo.byNumber(a.accountNumber)!.copyWith(phone: '555-01${i.toString().padLeft(2, '0')}')));
        futures.add(repo.saveProvider(repo.provider.copyWith(practiceName: 'Practice $i')));
      }
      await Future.wait(futures);
      final reopened = await AccountRepository.openAt(dir);
      expect(reopened.byNumber(a.accountNumber)!.phone, '555-0129');
      expect(reopened.provider.practiceName, 'Practice 29');
      expect(leftovers(), isEmpty);
    });

    test('erase after queued writes leaves nothing behind', () async {
      final repo = await AccountRepository.openAt(dir);
      for (var i = 0; i < 20; i++) {
        // Not awaited: these are still in the write queue when erase starts.
        repo.createAccount(firstName: 'P$i', lastName: 'Test').ignore();
      }
      repo.saveProvider(ProviderProfile.demo().copyWith(practiceName: 'Gone')).ignore();
      await repo.eraseAll();
      await repo.flush();
      expect(File('${dir.path}/solis_accounts.json').existsSync(), isFalse);
      expect(File('${dir.path}/solis_provider.json').existsSync(), isFalse);
      final reopened = await AccountRepository.openAt(dir);
      expect(reopened.accounts, isEmpty);
      // Writes after the erase still work.
      await reopened.createAccount(firstName: 'New', lastName: 'Start', sex: PatientSex.female);
      await reopened.flush();
      expect((await AccountRepository.openAt(dir)).accounts, hasLength(1));
    });
  });

  group('Claim idempotency key', () {
    const claim = 'ISA*00*          *00*          *ZZ*SOLIS          *ZZ*RECEIVER       *261017*1200*^*00501*000000101*0*T*:~'
        'GS*HC*SOLIS*RECEIVER*20261017*1200*101*X*005010X222A1~ST*837*0101*005010X222A1~BHT*0019*00*0101*20261017*1200*CH~'
        'NM1*41*2*SOLIS*****46*SOLIS~CLM*SOL-1000017-V1*125***11:B:1*Y*A*Y*Y~HI*ABK:G43109~SV1*HC:99213*125*UN*1***1~SE*8*0101~GE*1*101~IEA*1*000000101~';

    test('the same claim re-built with new control numbers keeps its key', () {
      final rebuilt = claim
          .replaceAll('000000101', '000000102')
          .replaceAll('*101*', '*102*')
          .replaceAll('0101', '0102')
          .replaceAll('1200', '1305');
      expect(claimIdempotencyKey(rebuilt, 'SOL-1000017-V1'), claimIdempotencyKey(claim, 'SOL-1000017-V1'));
      expect(claimIdempotencyKey('$claim\n', 'SOL-1000017-V1'), claimIdempotencyKey(claim, 'SOL-1000017-V1'));
    });

    test('a changed claim gets a new key', () {
      final changed = claim.replaceAll('SV1*HC:99213*125', 'SV1*HC:99214*175');
      expect(claimIdempotencyKey(changed, 'SOL-1000017-V1'), isNot(claimIdempotencyKey(claim, 'SOL-1000017-V1')));
      final key = claimIdempotencyKey(claim, 'SOL-1000017-V1');
      expect(key, startsWith('solis-SOL-1000017-V1-'));
      expect(key.length, lessThanOrEqualTo(255));
    });
  });

  group('TLS pinning', () {
    test('the bundled root set parses and covers the Cloudflare CAs', () {
      expect(pinnedRootCount, greaterThanOrEqualTo(10));
      expect(PinnedHttp.pinnedContext, returnsNormally);
      for (final cn in ['GTS Root R1', 'GTS Root R4', 'ISRG Root X1', 'SSL.com TLS RSA Root CA 2022', 'Sectigo Public Server Authentication Root R46']) {
        expect(pinnedRootsPem.isNotEmpty && File('lib/services/net/pinned_roots.dart').readAsStringSync().contains(cn), isTrue, reason: cn);
      }
    });

    test('pins are enforced and their expiry is at least a year away (move it forward each release)', () {
      expect(PinnedHttp.enabled, isTrue);
      expect(PinnedHttp.enforcedUntil.difference(DateTime.now().toUtc()).inDays, greaterThan(365));
    });
  });
}
