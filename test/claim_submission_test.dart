import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/billing/billing_queue.dart';
import 'package:solis_mobile/services/billing/claim_submission_service.dart';
import 'package:solis_mobile/services/billing/clearinghouse.dart';
import 'package:solis_mobile/services/billing/eligibility_service.dart';

import 'support/billing_fixtures.dart';
import 'support/fake_clearinghouse.dart';
import 'support/test_provider.dart';

void main() {
  group('Sending claims', () {
    test('a signed, clean claim is sent once with an idempotency key and marked submitted', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      final ch = FakeClearinghouse();
      final settings = await submitterSettings();
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings);

      final r = await service.send(a.accountNumber, v.number);
      expect(r.status, SendStatus.accepted);
      expect(ch.submitted, hasLength(1));
      expect(ch.submitted.single.$2, startsWith('solis-${a.accountNumber}-V${v.number}-'));
      final saved = repo.byNumber(a.accountNumber)!.visit(v.number)!;
      expect(saved.status, VisitStatus.submitted);
      expect(saved.submission!['patientControlNumber'], '${a.accountNumber}-V${v.number}');

      // A second send of a submitted claim is refused, never sent twice.
      final again = await service.send(a.accountNumber, v.number);
      expect(again.status, SendStatus.blocked);
      expect(ch.submitted, hasLength(1));
    });

    test('offline: the claim is queued and later retried with the same file and key', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      final ch = FakeClearinghouse()..submitAnswers = [FakeClearinghouse.offline(), FakeClearinghouse.offline(), FakeClearinghouse.accepted()];
      final settings = await submitterSettings();
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings);

      final r = await service.send(a.accountNumber, v.number);
      expect(r.status, SendStatus.queued);
      var saved = repo.byNumber(a.accountNumber)!.visit(v.number)!;
      expect(saved.status, VisitStatus.queued);
      expect(saved.submission!['attempts'], 1);

      expect(await service.retryQueued(), 0, reason: 'still offline');
      saved = repo.byNumber(a.accountNumber)!.visit(v.number)!;
      expect(saved.status, VisitStatus.queued);
      expect(saved.submission!['attempts'], 2);

      expect(await service.retryQueued(), 1);
      saved = repo.byNumber(a.accountNumber)!.visit(v.number)!;
      expect(saved.status, VisitStatus.submitted);
      expect(ch.submitted, hasLength(3));
      // Every attempt carried the same interchange and the same key.
      expect(ch.submitted.map((s) => s.$2).toSet(), hasLength(1));
      expect(ch.submitted.map((s) => s.$1).toSet(), hasLength(1));
    });

    test('a thrown network error also queues; a missing key does not', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      final settings = await submitterSettings();
      final thrower = FakeClearinghouse()..throwOnSubmit = true;
      final r = await ClaimSubmissionService(repo: repo, client: () => thrower, settings: () => settings).send(a.accountNumber, v.number);
      expect(r.status, SendStatus.queued);

      expect(
        ClaimSubmissionService.isRetryable(const ClaimSubmissionResult(
          outcome: SubmissionOutcome.failed,
          httpStatus: 0,
          rawResponse: '',
          errors: [ClearinghouseError(description: 'No Stedi API key is set.')],
        )),
        isFalse,
      );
      expect(ClaimSubmissionService.isRetryable(const ClaimSubmissionResult(outcome: SubmissionOutcome.failed, httpStatus: 503, rawResponse: '')), isTrue);
      expect(ClaimSubmissionService.isRetryable(const ClaimSubmissionResult(outcome: SubmissionOutcome.failed, httpStatus: 401, rawResponse: '')), isFalse);
    });

    test('nothing is sent for an unsigned note, an incomplete or demo profile, or no submitter', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final unsigned = await visitWith(repo, a, status: VisitStatus.inProgress);
      final ch = FakeClearinghouse();
      final settings = await submitterSettings();
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings);
      expect((await service.send(a.accountNumber, unsigned.number)).problems, contains('Sign the note first.'));

      final signed = await visitWith(repo, a);
      await repo.saveProvider(ProviderProfile.demo());
      final demo = await service.send(a.accountNumber, signed.number);
      expect(demo.status, SendStatus.blocked);
      expect(demo.problems.join(' '), contains('demo NPI'));

      await repo.saveProvider(ProviderProfile.empty());
      expect((await service.send(a.accountNumber, signed.number)).problems.join(' '), contains('Complete your provider profile'));

      await repo.saveProvider(testProvider());
      final noSubmitter = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => emptySettings());
      expect((await noSubmitter.send(a.accountNumber, signed.number)).problems.join(' '), contains('submitter'));
      expect(ch.submitted, isEmpty);
    });
  });

  group('Claim status', () {
    test('matches the claim by its control number, not the first claim of the day', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a, status: VisitStatus.submitted);
      await repo.updateVisit(a.accountNumber, v.copyWith(submission: {'patientControlNumber': '${a.accountNumber}-V${v.number}'}));
      final ch = FakeClearinghouse()
        ..statusAnswer = ClaimStatusResult(success: true, httpStatus: 200, rawResponse: '', claims: [
          const ClaimStatusEntry(statusCategoryCode: 'F1', statusDescription: 'Paid', patientAccountNumber: 'SOL-OTHER-V1', paidAmount: '10'),
          ClaimStatusEntry(statusCategoryCode: 'F2', statusDescription: 'Denied', patientAccountNumber: '${a.accountNumber}-V${v.number}'),
        ]);
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => emptySettings());
      final r = await service.refreshStatus(a.accountNumber, v.number);
      expect(r.updated, isTrue);
      expect(repo.byNumber(a.accountNumber)!.visit(v.number)!.status, VisitStatus.denied);
    });

    test('matchClaim refuses to guess between two claims on one date', () {
      const two = [ClaimStatusEntry(statusCategoryCode: 'F1'), ClaimStatusEntry(statusCategoryCode: 'F2')];
      expect(ClaimSubmissionService.matchClaim(two, pcn: 'SOL-1-V1', dateOfService: '2026-10-15'), isNull);
      const one = [ClaimStatusEntry(statusCategoryCode: 'F1', serviceDate: '20261015')];
      expect(ClaimSubmissionService.matchClaim(one, pcn: 'SOL-1-V1', dateOfService: '2026-10-15')?.paid, isTrue);
      const other = [ClaimStatusEntry(statusCategoryCode: 'F1', patientAccountNumber: 'SOL-9-V2')];
      expect(ClaimSubmissionService.matchClaim(other, pcn: 'SOL-1-V1', dateOfService: '2026-10-15'), isNull);
    });

    test('refreshAll checks only submitted claims older than the minimum age', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final fresh = await visitWith(repo, a, status: VisitStatus.submitted);
      await repo.updateVisit(a.accountNumber, fresh.copyWith(submission: {'statusCheckedAtUtc': DateTime.now().toUtc().toIso8601String()}));
      final old = await visitWith(repo, a, status: VisitStatus.submitted);
      await repo.updateVisit(a.accountNumber, old.copyWith(submission: {'patientControlNumber': '${a.accountNumber}-V${old.number}'}));
      await visitWith(repo, a, status: VisitStatus.paid);
      final ch = FakeClearinghouse()
        ..statusAnswer = ClaimStatusResult(success: true, httpStatus: 200, rawResponse: '', claims: [
          ClaimStatusEntry(statusCategoryCode: 'F1', statusDescription: 'Paid', patientAccountNumber: '${a.accountNumber}-V${old.number}', paidAmount: '98.20'),
        ]);
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => emptySettings());
      expect(await service.refreshAll(), 1);
      expect(ch.statusRequests, hasLength(1));
      final paid = repo.byNumber(a.accountNumber)!.visit(old.number)!;
      expect(paid.status, VisitStatus.paid);
      expect(paid.submission!['paidAmount'], '98.20');
      expect(paid.submission!['paidAtUtc'], isNotNull);
    });
  });

  group('Billing queue', () {
    test('visits fall into the bucket of what they need next', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final draft = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: '11');
      await repo.updateVisit(a.accountNumber, draft.copyWith(encounter: const {'subjective': 'x'}, claim: cleanClaim()));
      await visitWith(repo, a); // signed, clean
      await visitWith(repo, a, claim: cleanClaim().copyWith(lines: const [])); // signed, no services
      await visitWith(repo, a, status: VisitStatus.queued);
      await visitWith(repo, a, status: VisitStatus.submitted);
      await visitWith(repo, a, status: VisitStatus.denied);
      final empty = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: '11');
      final items = classifyVisits(repo.accounts, repo.provider);
      final buckets = items.map((i) => i.bucket).toList();
      expect(buckets, [
        BillingBucket.needsSignature,
        BillingBucket.needsFixes,
        BillingBucket.readyToSend,
        BillingBucket.queued,
        BillingBucket.awaitingPayer,
        BillingBucket.denied,
      ]);
      expect(items.any((i) => i.visit.number == empty.number), isFalse, reason: 'no note yet, nothing to bill');
      expect(batchSendable(items), hasLength(1));
    });

    test('claims with warnings wait for their own review', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo, payer: 'Tiny Local Plan');
      await visitWith(repo, a);
      final items = classifyVisits(repo.accounts, repo.provider);
      expect(items.single.bucket, BillingBucket.readyToSend);
      expect(items.single.warnings, greaterThan(0));
      expect(batchSendable(items), isEmpty);
    });

    test('Today lists only visits on today\'s date, unfinished first', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final today = DateTime.now().toIso8601String().split('T').first;
      await visitWith(repo, a, dos: today, status: VisitStatus.submitted);
      await visitWith(repo, a, dos: today, status: VisitStatus.inProgress);
      await visitWith(repo, a, dos: '2020-01-01');
      final list = visitsOn(repo.accounts);
      expect(list, hasLength(2));
      expect(list.first.$2.status, VisitStatus.inProgress);
    });
  });

  group('Eligibility', () {
    test('is saved on the visit, read back as one line, and rechecked after a day', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      var now = DateTime.utc(2026, 10, 15, 9);
      final ch = FakeClearinghouse();
      final svc = EligibilityService(repo: repo, client: () => ch, now: () => now);
      expect(svc.isStale(v), isTrue);
      await svc.ensureFresh(a.accountNumber, v.number);
      final saved = repo.byNumber(a.accountNumber)!.visit(v.number)!;
      expect(EligibilityService.describe(saved.eligibility), 'Active, copay \$25 to collect');
      expect(svc.isStale(saved), isFalse);
      expect(await svc.ensureFresh(a.accountNumber, v.number), isNull, reason: 'fresh results are not rechecked');
      now = now.add(const Duration(hours: 25));
      expect(svc.isStale(saved), isTrue);
    });

    test('inactive coverage is a claim error with a rescan fix; no check is only a note', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      final ch = FakeClearinghouse()..eligibilityAnswer = const EligibilityResult(success: true, httpStatus: 200, rawResponse: '', activeCoverage: false);
      await EligibilityService(repo: repo, client: () => ch).check(a.accountNumber, visitNumber: v.number);
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => emptySettings());
      final account = repo.byNumber(a.accountNumber)!;
      expect(service.blockers(account, account.visit(v.number)!), contains('Coverage not active on the date of service'));
      expect(EligibilityService.describe(account.visit(v.number)!.eligibility), 'Coverage not active for the date of service');
    });
  });
}
