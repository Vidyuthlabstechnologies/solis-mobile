// The five sample conversations, coded and scrubbed with the real bundled
// code sets and knowledge-base assets: the knowledge-base checks must not add
// false-positive errors to these clean demo visits.

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/data/sample_conversations.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';
import 'support/test_provider.dart';

const _samples = {
  'Acute Migraine with Aura': ('11', PatientSex.male, 45),
  'Community-Acquired Pneumonia': ('11', PatientSex.female, 52),
  'Right Knee Meniscus Injury': ('11', PatientSex.male, 34),
  'Acute Inferior STEMI': ('23', PatientSex.male, 58),
  'Diabetic Peripheral Neuropathy': ('11', PatientSex.female, 66),
};

List<ClaimIssue> _scrub(String key) {
  final (pos, sex, age) = _samples[key]!;
  final text = sampleConversations[key]!;
  final encounter = LocalClinicalEngine.synthesizeOnDevice(rawSpeech: text, patientName: 'Test', mrn: 'SOL-1', ageGender: '${age}M', attending: 'Dr. Test');
  final provider = testProvider();
  final result = ClinicalCoder.code(
    turns: ClinicalCoder.diarize(text),
    vitals: encounter.vitals,
    context: CodingContext(dateOfService: DateTime(2026, 10, 15), placeOfService: pos, sex: sex, age: age, feeSchedule: provider.feeSchedule),
  );
  final visit = Visit(number: 1, dateOfService: '2026-10-15', placeOfService: pos, createdAtUtc: DateTime(2026));
  final account = PatientAccount(
    accountNumber: 'SOL-10000017',
    firstName: 'Pat',
    lastName: 'Lee',
    sex: sex,
    dateOfBirth: DateTime(2026 - age, 5, 1),
    createdAtUtc: DateTime(2026),
    insurance: InsuranceCoverage(payerName: provider.acceptedPayers.first, memberId: 'W1'),
    visits: [visit],
  );
  return ClaimScrubber.check(
    claim: ClaimDraft(diagnoses: result.diagnoses, lines: result.lines, generatedAtUtc: DateTime(2026)),
    account: account,
    visit: visit,
    provider: provider,
    noteSigned: true,
  );
}

void main() {
  setUpAll(() async {
    CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes'));
    await ReferenceData.load();
  });
  tearDownAll(() {
    ReferenceData.clear();
    CodeSetLoader.useSource(const AssetCodeSetSource());
  });

  for (final key in _samples.keys) {
    test('$key: no coding errors with the real knowledge base', () {
      final issues = _scrub(key);
      // ignore: avoid_print
      print('$key\n${issues.map((i) => '  ${i.severity.name} ${i.title}').join('\n')}');
      expect(issues.where((i) => i.severity == IssueSeverity.error).map((i) => i.title), isEmpty);
    });
  }
}
