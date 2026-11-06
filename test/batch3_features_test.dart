import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/billing/billing_queue.dart';
import 'package:solis_mobile/services/billing/billing_stats.dart';
import 'package:solis_mobile/services/billing/claim_submission_service.dart';
import 'package:solis_mobile/services/billing/clearinghouse.dart';

import 'support/billing_fixtures.dart';
import 'support/fake_clearinghouse.dart';
import 'support/test_provider.dart';

ClaimDraft _claim(double charge) => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 1),
      diagnoses: const [ClaimDiagnosis(code: 'J06.9', description: 'URI', source: DxSource.physicianConfirmed)],
      lines: [ServiceLine(code: '99213', description: 'Office visit', charge: charge, diagnosisCodes: const ['J06.9'])],
    );

Visit _v(int n, String dos, VisitStatus status, double charge, {Map<String, dynamic>? submission}) => Visit(
      number: n,
      dateOfService: dos,
      placeOfService: '11',
      createdAtUtc: DateTime.parse('${dos}T10:00:00Z'),
      status: status,
      claim: _claim(charge),
      submission: submission,
      encounter: const {'subjective': 'x'},
    );

PatientAccount _a(List<Visit> visits) => PatientAccount(accountNumber: 'SOL-1', firstName: 'A', lastName: 'B', createdAtUtc: DateTime.utc(2026), visits: visits);

void main() {
  final today = DateTime(2026, 11, 6);

  test('A/R aging counts only claims waiting on a payer, by days since the visit', () {
    final aging = arAging([
      _a([
        _v(1, '2026-11-01', VisitStatus.submitted, 100),
        _v(2, '2026-09-20', VisitStatus.denied, 50),
        _v(3, '2026-08-20', VisitStatus.rejected, 25),
        _v(4, '2026-06-01', VisitStatus.queued, 10),
        _v(5, '2026-10-01', VisitStatus.paid, 999),
        _v(6, '2026-10-01', VisitStatus.signed, 999),
      ]),
    ], today: today);
    expect(aging.buckets, [100, 50, 25, 10]);
    expect(aging.counts, [1, 1, 1, 1]);
    expect(aging.total, 185);
  });

  test('month totals: billed claims and paid amounts for the month of service', () {
    final t = monthTotals([
      _a([
        _v(1, '2026-11-02', VisitStatus.paid, 140, submission: {'paidAmount': '98.40'}),
        _v(2, '2026-11-03', VisitStatus.submitted, 60),
        _v(3, '2026-11-04', VisitStatus.signed, 500),
        _v(4, '2026-10-30', VisitStatus.paid, 70, submission: {'paidAmount': '70'}),
      ]),
    ], month: today);
    expect(t.claims, 2);
    expect(t.billed, 200);
    expect(t.paid, closeTo(98.40, 0.001));
  });

  test('day summary and denial work queue order', () {
    final items = classifyVisits([
      _a([
        _v(1, '2026-11-06', VisitStatus.inProgress, 0),
        _v(2, '2026-10-10', VisitStatus.denied, 10),
        _v(3, '2026-09-10', VisitStatus.denied, 10),
        _v(4, '2026-11-01', VisitStatus.submitted, 10),
        _v(5, '2026-11-02', VisitStatus.submitted, 10),
      ]),
    ], testProvider());
    final d = daySummary(items);
    expect(d.unsigned, 1);
    expect(d.clear, isFalse);
    final denied = items.where((i) => i.bucket == BillingBucket.denied).map((i) => i.visit.number);
    expect(denied, [3, 2], reason: 'oldest denial first');
    final awaiting = items.where((i) => i.bucket == BillingBucket.awaitingPayer).map((i) => i.visit.number);
    expect(awaiting, [5, 4], reason: 'other buckets stay newest first');
    expect(daySummary(const []).clear, isTrue);
  });

  test('claim history: queued, accepted and payer status are kept in order', () async {
    final repo = await realRepo();
    final a = await billablePatient(repo);
    final v = await visitWith(repo, a);
    final ch = FakeClearinghouse()
      ..submitAnswers = [FakeClearinghouse.offline(), FakeClearinghouse.accepted()]
      ..statusAnswer = const ClaimStatusResult(success: true, httpStatus: 200, rawResponse: '', claims: [
        ClaimStatusEntry(statusCategoryCode: 'F1', statusDescription: 'Paid', paidAmount: '90', payerClaimNumber: 'P9', serviceDate: '2026-10-15'),
      ]);
    final settings = await submitterSettings();
    var clock = DateTime.utc(2026, 11, 6, 9);
    final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings, now: () => clock);

    await service.send(a.accountNumber, v.number);
    clock = clock.add(const Duration(minutes: 5));
    await service.retryQueued();
    clock = clock.add(const Duration(hours: 2));
    await service.refreshStatus(a.accountNumber, v.number);
    await service.refreshStatus(a.accountNumber, v.number); // same answer: not repeated

    final s = repo.byNumber(a.accountNumber)!.visit(v.number)!.submission!;
    final events = [for (final e in s['history'] as List) (e as Map)['event'] as String];
    expect(events, [
      'Claim queued: no connection (attempt 1)',
      'Claim accepted by the clearinghouse (test)',
      'Payer status: Finalized: paid. Payer says: "Paid".',
    ]);
    final lines = claimHistoryLines(s);
    expect(lines.first, endsWith('Payer status: Finalized: paid. Payer says: "Paid".'));
    expect(lines, hasLength(3));
  });

  test('history is capped', () {
    Map<String, dynamic>? s;
    for (var i = 0; i < 40; i++) {
      s = {'history': ClaimSubmissionService.appendHistory(s, '2026-11-06T00:00:00Z', 'e$i')};
    }
    final h = s!['history'] as List;
    expect(h, hasLength(ClaimSubmissionService.historyLimit));
    expect((h.last as Map)['event'], 'e39');
  });
}
