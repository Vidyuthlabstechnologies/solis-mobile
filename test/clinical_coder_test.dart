import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/data/sample_conversations.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/coding/code_rules.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';

CodingResult _code(String key, {String pos = '11', bool newPatient = false, PatientSex sex = PatientSex.male, int age = 50}) {
  final text = sampleConversations[key]!;
  final encounter = LocalClinicalEngine.synthesizeOnDevice(
    rawSpeech: text,
    patientName: 'Test',
    mrn: 'SOL-1',
    ageGender: '50M',
    attending: 'Dr. Test',
  );
  return ClinicalCoder.code(
    turns: ClinicalCoder.diarize(text),
    vitals: encounter.vitals,
    context: CodingContext(placeOfService: pos, newPatient: newPatient, sex: sex, age: age),
  );
}

List<String> _billable(CodingResult r) => r.billable.map((d) => d.code).toList();
ClaimDiagnosis? _dx(CodingResult r, String code) {
  for (final d in r.diagnoses) {
    if (d.code == code) return d;
  }
  return null;
}

void main() {
  group('Speaker separation', () {
    test('uses Doctor:/Patient: labels when present', () {
      final turns = ClinicalCoder.diarize('Doctor: What brings you in?\nPatient: My head is pounding.');
      expect(turns.map((t) => t.speaker), ['Doctor', 'Patient']);
    });

    test('infers speakers from unlabeled live speech', () {
      const live = 'What brings you in today? I have had a pounding headache for two days and I threw up this morning. '
          'Any fever? No fever. On exam your neck is supple. I am prescribing sumatriptan 50 mg.';
      final turns = ClinicalCoder.diarize(live);
      final patient = turns.where((t) => t.speaker == 'Patient').map((t) => t.text).join(' ');
      final doctor = turns.where((t) => t.speaker == 'Doctor').map((t) => t.text).join(' ');
      expect(patient, contains('pounding headache'));
      expect(doctor, contains('What brings you in'));
      expect(doctor, contains('prescribing sumatriptan'));
    });
  });

  group('Diagnosis coding', () {
    test('STEMI: confirmed diagnosis is primary, its symptoms are not coded separately', () {
      final r = _code('Acute Inferior STEMI', pos: '23');
      expect(_billable(r).first, 'I21.19');
      expect(_dx(r, 'R07.89')?.status, DxStatus.integral, reason: 'chest pressure is part of the MI');
      expect(_dx(r, 'R68.84')?.status, DxStatus.integral);
      expect(_billable(r), isNot(contains('I10')), reason: 'a blood pressure reading is not a hypertension diagnosis');
    });

    test('Pneumonia: "sounds like" is uncertain, so the visit is coded to the patient symptoms', () {
      final r = _code('Community-Acquired Pneumonia');
      expect(_dx(r, 'J18.1')?.status, DxStatus.uncertain);
      expect(_billable(r), containsAll(['R05.9', 'R50.9', 'R06.02']));
      expect(_billable(r), contains('R07.81'), reason: 'sharp pain on deep breath is pleurodynia');
    });

    test('Migraine: confirmed diagnosis absorbs headache, nausea and light sensitivity', () {
      final r = _code('Acute Migraine with Aura');
      expect(_billable(r).first, 'G43.109');
      for (final s in ['R51.9', 'R11.2']) {
        expect(_dx(r, s)?.status, DxStatus.integral, reason: '$s is part of migraine');
      }
      expect(_billable(r), isNot(contains('R50.9')), reason: 'patient said "no fever"');
    });

    test('Knee: "suspicious for" tear is not coded; pain and effusion are, with laterality', () {
      final r = _code('Right Knee Meniscus Injury');
      expect(_dx(r, 'S83.241A')?.status, DxStatus.uncertain);
      expect(_billable(r), containsAll(['M25.561', 'M25.461']));
    });

    test('Neuropathy: diabetes coded from history and management; neuropathy waits for confirmation', () {
      final r = _code('Diabetic Peripheral Neuropathy', sex: PatientSex.female, age: 66);
      expect(_billable(r), contains('E11.9'));
      expect(_dx(r, 'E11.42')?.status, DxStatus.uncertain);
      expect(_billable(r), contains('R20.2'), reason: 'burning, pins and needles in the patient words');
    });
  });

  group('Procedure coding', () {
    test('E/M follows place of service and new vs established', () {
      expect(_code('Acute Migraine with Aura', newPatient: true).lines.first.code, '99204');
      expect(_code('Acute Migraine with Aura').lines.first.code, '99214');
      expect(_code('Acute Inferior STEMI', pos: '23').lines.first.code, '99285');
      expect(_code('Acute Migraine with Aura', pos: '32').lines.first.code, '99309');
      expect(_code('Acute Migraine with Aura', pos: '12').lines.first.code, '99349');
    });

    test('ambulance bills HCPCS transport, not an E/M', () {
      final codes = _code('Acute Inferior STEMI', pos: '41').lines.map((l) => l.code);
      expect(codes, containsAll(['A0427', 'A0425']));
      expect(codes.any((c) => c.startsWith('99')), isFalse);
    });

    test('EKG read in the ED is interpretation only; ordered imaging is not billed', () {
      final ed = _code('Acute Inferior STEMI', pos: '23').lines.map((l) => l.code);
      expect(ed, contains('93010'));
      expect(ed, isNot(contains('93000')));
      final pneumonia = _code('Community-Acquired Pneumonia').lines.map((l) => l.code);
      expect(pneumonia, isNot(contains('71046')), reason: 'the X-ray is done down the hall, billed by radiology');
    });

    test('every service line points at a supporting diagnosis', () {
      final r = _code('Acute Inferior STEMI', pos: '23');
      final ekg = r.lines.firstWhere((l) => l.code == '93010');
      expect(ekg.diagnosisCodes, contains('I21.19'));
    });
  });

  group('Code rules', () {
    test('headache does not support an upper GI endoscopy', () {
      expect(diagnosisSupportsProcedure('R51.9', '43235'), isFalse);
      expect(diagnosisSupportsProcedure('K21.9', '43235'), isTrue);
      expect(diagnosisSupportsProcedure('R51.9', '99214'), isTrue);
    });

    test('sex and age restrictions', () {
      expect(icdSexRestriction('O80'), PatientSex.female);
      expect(icdSexRestriction('N40.0'), PatientSex.male);
      expect(icdSexRestriction('Z01.419'), PatientSex.female);
      expect(icdSexRestriction('Z02.0'), isNull);
      expect(procedureSexRestriction('55700'), PatientSex.male);
      expect(procedureSexRestriction('76805'), PatientSex.female);
      expect(icdAgeRange('O80')!.contains(70), isFalse);
      expect(procedureAgeRange('99385')!.contains(45), isFalse);
    });
  });
}
