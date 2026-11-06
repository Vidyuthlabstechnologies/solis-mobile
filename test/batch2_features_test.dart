import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/claim_tab.dart';
import 'package:solis_mobile/services/billing/claim_submission_service.dart';
import 'package:solis_mobile/services/billing/clearinghouse.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/em_time.dart';
import 'package:solis_mobile/services/coding/rule_citations.g.dart';

import 'support/billing_fixtures.dart';
import 'support/fake_clearinghouse.dart';
import 'support/test_provider.dart';

const _medicare = InsuranceCoverage(payerName: 'Medicare Part B', payerId: '01112', memberId: '1EG4TE5MK73');
const _aetna = InsuranceCoverage(payerName: 'Aetna', payerId: '60054', memberId: 'W123456789');

ClaimDraft _claim(String em, {List<String> modifiers = const [], List<String> extra = const []}) => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 15),
      diagnoses: const [ClaimDiagnosis(code: 'E11.9', description: 'Type 2 diabetes', source: DxSource.physicianConfirmed)],
      lines: [
        ServiceLine(code: em, description: 'Office visit', modifiers: modifiers, charge: 150, diagnosisCodes: const ['E11.9']),
        for (final c in extra) ServiceLine(code: c, description: c, charge: 10, diagnosisCodes: const ['E11.9']),
      ],
    );

void main() {
  group('E/M by total time', () {
    test('office levels by minimum minutes', () {
      expect(officeEmForTime('99213', 9), isNull);
      expect(officeEmForTime('99213', 10), '99212');
      expect(officeEmForTime('99213', 29), '99213');
      expect(officeEmForTime('99212', 30), '99214');
      expect(officeEmForTime('99214', 40), '99215');
      expect(officeEmForTime('99203', 44), '99203');
      expect(officeEmForTime('99203', 60), '99205');
      expect(officeEmForTime('99283', 60), isNull, reason: 'ED visits are not billed by time');
    });

    test('prolonged services: CPT 99417 and Medicare G2212 thresholds', () {
      expect(prolongedFor('99215', 54, medicare: false), isNull);
      expect(prolongedFor('99215', 55, medicare: false), const ProlongedService('99417', 1));
      expect(prolongedFor('99215', 70, medicare: false), const ProlongedService('99417', 2));
      expect(prolongedFor('99205', 74, medicare: false), isNull);
      expect(prolongedFor('99205', 75, medicare: false), const ProlongedService('99417', 1));
      expect(prolongedFor('99215', 68, medicare: true), isNull);
      expect(prolongedFor('99215', 69, medicare: true), const ProlongedService('G2212', 1));
      expect(prolongedFor('99215', 84, medicare: true), const ProlongedService('G2212', 2));
      expect(prolongedFor('99205', 88, medicare: true), isNull);
      expect(prolongedFor('99205', 89, medicare: true), const ProlongedService('G2212', 1));
      expect(prolongedFor('99214', 200, medicare: false), isNull, reason: 'only after the top level');
    });

    test('applyTotalTime sets the level and the prolonged line, and replaces an old one', () {
      final fees = {'99215': 210.0, '99417': 30.0, '99214': 160.0};
      final c = applyTotalTime(_claim('99213', extra: ['36415']), 72, fees, medicare: false)!;
      expect(c.lines.map((l) => '${l.code}x${l.units}'), ['99215x1', '99417x2', '36415x1']);
      expect(c.lines.first.charge, 210);
      expect(c.lines.first.evidence, contains('72 minutes'));
      expect(c.lines[1].diagnosisCodes, ['E11.9']);

      final shorter = applyTotalTime(c, 32, fees, medicare: false)!;
      expect(shorter.lines.map((l) => l.code), ['99214', '36415'], reason: 'the old 99417 goes away');

      expect(applyTotalTime(_claim('99213'), 5, fees, medicare: false), isNull);
      expect(applyTotalTime(_claim('99283'), 60, fees, medicare: false), isNull);
    });
  });

  group('G2211 visit-complexity add-on', () {
    test('suggested for a Medicare office visit, with a one-tap add', () {
      final i = ClaimScrubber.complexityAddOnIssue(_claim('99214'), _medicare)!;
      expect(i.ruleId, 'CLAIM-G2211-01');
      expect(i.severity, IssueSeverity.info);
      expect(i.fix!.kind, FixKind.addService);
      final added = applyClaimFix(_claim('99214'), i.fix!, const {'G2211': 16.0})!;
      expect(added.lines.map((l) => l.code), ['99214', 'G2211']);
      expect(added.lines.last.diagnosisCodes, ['E11.9']);
      expect(added.lines.last.charge, 16);
      expect(applyClaimFix(added, i.fix!, const {}), isNull, reason: 'never added twice');
    });

    test('not suggested off Medicare, with modifier 25, for 99211, or when already billed', () {
      expect(ClaimScrubber.complexityAddOnIssue(_claim('99214'), _aetna), isNull);
      expect(ClaimScrubber.complexityAddOnIssue(_claim('99214', modifiers: ['25']), _medicare), isNull);
      expect(ClaimScrubber.complexityAddOnIssue(_claim('99211'), _medicare), isNull);
      expect(ClaimScrubber.complexityAddOnIssue(_claim('99214', extra: ['G2211']), _medicare), isNull);
      expect(ClaimScrubber.complexityAddOnIssue(_claim('99283'), _medicare), isNull);
      expect(ruleCitations['CLAIM-G2211-01'], isNotEmpty);
    });
  });

  group('unidentified patient', () {
    test('placeholder name is unique per minute and blocks billing', () async {
      final n = unidentifiedName(DateTime(2026, 11, 6, 14, 42));
      expect(n.first, 'Unidentified');
      expect(n.last, 'Patient 1106-1442');
      final repo = await realRepo();
      final a = await repo.createAccount(firstName: n.first, lastName: n.last);
      expect(a.isUnidentified, isTrue);
      final v = await visitWith(repo, a);
      final ids = ClaimScrubber.check(claim: v.claim!, account: a, visit: v, provider: testProvider(), noteSigned: true).map((i) => i.ruleId);
      expect(ids, contains('CLAIM-PATIENT-02'));
      expect(ruleCitations['CLAIM-PATIENT-02'], isNotEmpty);
      final named = a.copyWith(firstName: 'Maria', lastName: 'Lopez');
      expect(named.isUnidentified, isFalse);
    });
  });

  group('corrected and void claims from the visit', () {
    Future<(ClaimSubmissionService, FakeClearinghouse, String, int)> sent({String? icn = '2026288123456', VisitStatus status = VisitStatus.denied}) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      await repo.updateVisit(a.accountNumber, v.copyWith(status: status, submission: {'patientControlNumber': '${a.accountNumber}-V${v.number}', 'payerClaimNumber': ?icn}));
      final ch = FakeClearinghouse();
      final settings = await submitterSettings();
      return (ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings), ch, a.accountNumber, v.number);
    }

    test('a denied claim is corrected with frequency 7 and REF*F8', () async {
      final (service, ch, acct, n) = await sent();
      final r = await service.sendReplacement(acct, n, ClaimFrequency.replacement);
      expect(r.status, SendStatus.accepted);
      final x12 = ch.submitted.single.$1;
      expect(x12, contains(':B:7*'));
      expect(x12, contains('REF*F8*2026288123456~'));
    });

    test('a paid claim can be voided with frequency 8', () async {
      final (service, ch, acct, n) = await sent(status: VisitStatus.paid);
      final r = await service.sendReplacement(acct, n, ClaimFrequency.voided);
      expect(r.status, SendStatus.accepted);
      expect(ch.submitted.single.$1, contains(':B:8*'));
    });

    test('no payer claim number: refused and nothing sent', () async {
      final (service, ch, acct, n) = await sent(icn: null);
      final r = await service.sendReplacement(acct, n, ClaimFrequency.replacement);
      expect(r.status, SendStatus.blocked);
      expect(ch.submitted, isEmpty);
    });

    test('a rejected correction resends as a correction, never as a new original', () async {
      final (service, ch, acct, n) = await sent();
      ch.submitAnswers = [
        const ClaimSubmissionResult(outcome: SubmissionOutcome.rejected, httpStatus: 200, rawResponse: '{}', errors: [ClearinghouseError(description: 'bad')]),
        FakeClearinghouse.accepted(),
      ];
      expect((await service.sendReplacement(acct, n, ClaimFrequency.replacement)).status, SendStatus.rejected);
      final r = await service.send(acct, n);
      expect(r.status, SendStatus.accepted);
      expect(ch.submitted, hasLength(2));
      expect(ch.submitted.last.$1, allOf(contains(':B:7*'), contains('REF*F8*2026288123456~')));
    });
  });
}
