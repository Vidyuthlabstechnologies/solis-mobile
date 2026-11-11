import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/billing/integration_settings.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';

import 'test_provider.dart';

/// A real-mode store with a complete provider.
Future<AccountRepository> realRepo() async {
  final repo = AccountRepository.memory();
  AccountRepository.instance = repo;
  await repo.saveProvider(testProvider());
  return repo;
}

/// A patient with everything an 837P needs.
Future<PatientAccount> billablePatient(AccountRepository repo, {String first = 'Jane', String payer = 'Aetna'}) => repo.createAccount(
      firstName: first,
      lastName: 'Doe',
      dateOfBirth: DateTime(1970, 1, 2),
      sex: PatientSex.female,
      addressLine1: '12 Oak St',
      city: 'Oakland',
      state: 'CA',
      zip: '94607',
      insurance: InsuranceCoverage(payerName: payer, payerId: '60054', memberId: 'W123456789'),
    );

ClaimDraft cleanClaim() => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 15),
      diagnoses: const [ClaimDiagnosis(code: 'J06.9', description: 'Acute upper respiratory infection', source: DxSource.physicianConfirmed)],
      lines: const [ServiceLine(code: '99213', description: 'Office visit', charge: 140, diagnosisCodes: ['J06.9'])],
    );

/// Adds a visit with [claim] at [status].
Future<Visit> visitWith(AccountRepository repo, PatientAccount a,
    {VisitStatus status = VisitStatus.signed, ClaimDraft? claim, String dos = '2026-10-15', String pos = '11'}) async {
  final v = await repo.addVisit(a.accountNumber, dateOfService: DateTime.parse(dos), placeOfService: pos);
  final c = claim ?? cleanClaim();
  // The clinician confirmed these codes when signing.
  final updated = v.copyWith(
    status: status,
    claim: c,
    encounter: const {'subjective': 'x'},
    codeConfirmation: CodeConfirmation(atUtc: DateTime.utc(2026, 10, 15), by: 'Test', fingerprint: c.codeFingerprint, codes: c.codeSummary),
  );
  await repo.updateVisit(a.accountNumber, updated);
  return updated;
}

/// Settings with no submitter configured.
IntegrationSettings emptySettings() => IntegrationSettings.inMemory();

Future<IntegrationSettings> submitterSettings({bool test = true}) async {
  final s = IntegrationSettings.inMemory();
  await s.setSubmitterConfig(SubmitterConfig(
    submitterName: 'Clinic',
    submitterId: '123',
    isaSenderId: 'CLINIC',
    isaReceiverId: 'STEDI',
    usageIndicator: test ? 'T' : 'P',
  ));
  return s;
}
