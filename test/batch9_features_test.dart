import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/billing/claim_submission_service.dart';
import 'package:solis_mobile/services/billing/rejection_fixes.dart';

import 'support/billing_fixtures.dart';
import 'support/fake_clearinghouse.dart';

void main() {
  group('clinician confirms the codes', () {
    test('the fingerprint covers codes, modifiers, units and pointers', () {
      final c = cleanClaim();
      final same = ClaimDraft.fromJson(c.toJson());
      expect(same.codeFingerprint, c.codeFingerprint);
      final level = c.copyWith(lines: [c.lines.single.copyWith(code: '99214')]);
      final mod = c.copyWith(lines: [c.lines.single.copyWith(modifiers: ['25'])]);
      final units = c.copyWith(lines: [c.lines.single.copyWith(units: 2)]);
      final dx = c.copyWith(diagnoses: [...c.diagnoses, const ClaimDiagnosis(code: 'I10', description: 'HTN', source: DxSource.physicianConfirmed)]);
      for (final changed in [level, mod, units, dx]) {
        expect(changed.codeFingerprint, isNot(c.codeFingerprint));
      }
      expect(c.codeSummary, '99213, J06.9');
      expect(c.emLine!.code, '99213');
    });

    test('a claim cannot send until its current codes are confirmed', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a);
      // The clinician changes the level after confirming: the old confirmation no longer counts.
      final changed = v.copyWith(claim: v.claim!.copyWith(lines: [v.claim!.lines.single.copyWith(code: '99214')]));
      await repo.updateVisit(a.accountNumber, changed);
      final ch = FakeClearinghouse();
      final settings = await submitterSettings();
      final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings);

      var r = await service.send(a.accountNumber, v.number);
      expect(r.status, SendStatus.blocked);
      expect(r.problems, contains(ClaimSubmissionService.codesNotConfirmed));
      expect(ch.submitted, isEmpty);

      final c = changed.claim!;
      await repo.updateVisit(
        a.accountNumber,
        changed.copyWith(codeConfirmation: CodeConfirmation(atUtc: DateTime.now().toUtc(), by: 'Dr. Test', fingerprint: c.codeFingerprint, codes: c.codeSummary)),
      );
      r = await service.send(a.accountNumber, v.number);
      expect(r.status, SendStatus.accepted);
      final saved = repo.byNumber(a.accountNumber)!.visit(v.number)!;
      expect(saved.audit.last.action, 'Claim sent');
      expect(saved.audit.last.detail, startsWith('99214, J06.9'));
    });

    test('the audit trail and confirmation survive a save', () {
      final v = Visit(number: 1, dateOfService: '2026-11-11', placeOfService: '11', createdAtUtc: DateTime.utc(2026, 11, 11))
          .withAudit('Dr. A', 'Signed note', atUtc: DateTime.utc(2026, 11, 11, 10))
          .withAudit('Dr. A', 'Changed codes', detail: 'from 99213 to 99214', atUtc: DateTime.utc(2026, 11, 11, 10, 5))
          .copyWith(codeConfirmation: CodeConfirmation(atUtc: DateTime.utc(2026, 11, 11, 10, 6), by: 'Dr. A', fingerprint: 'f', codes: '99214'));
      final back = Visit.fromJson(v.toJson());
      expect(back.audit.map((e) => e.action), ['Signed note', 'Changed codes']);
      expect(back.audit.last.toLine(), '2026-11-11T10:05:00.000Z\tDr. A\tChanged codes\tfrom 99213 to 99214');
      expect(back.codeConfirmation!.codes, '99214');
      expect(Visit.fromJson({...v.toJson(), 'audit': ['junk', {'atUtc': 'bad'}]}).audit, isEmpty);
    });
  });

  group('one-tap fixes for rejections', () {
    test('rejection messages map to the place that fixes them', () {
      expect(RejectionFixes.forMessages(['Subscriber/Insured ID is invalid']).single.kind, FixKind.scanCard);
      expect(RejectionFixes.forMessages(['Patient birth date does not match']).single.kind, FixKind.editPatient);
      expect(RejectionFixes.forMessages(['Billing provider NPI not found in NPPES']).map((f) => f.kind), contains(FixKind.editProvider));
      expect(RejectionFixes.forMessages(['Invalid diagnosis code pointer']).single, RejectionFixes.reviewCodes);
      expect(RejectionFixes.forMessages(['Duplicate claim']), isEmpty);
      // One button per fix, whatever the number of messages naming it.
      expect(RejectionFixes.forMessages(['Member ID invalid', 'Subscriber not found']), hasLength(1));
    });
  });
}
