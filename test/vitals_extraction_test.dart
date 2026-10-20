import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';

ClinicalEncounter _synth(String speech) => LocalClinicalEngine.synthesizeOnDevice(
      rawSpeech: speech,
      patientName: 'Test Patient',
      mrn: 'MRN-1',
      ageGender: '58M',
      attending: 'Dr. Test',
    );

String? _vital(ClinicalEncounter e, String label) {
  for (final v in e.vitals) {
    if (v.label == label) return v.value;
  }
  return null;
}

void main() {
  group('Vitals extraction', () {
    test('reads the stated heart rate, not the first number in the conversation', () {
      final e = _synth(
        'Patient: It started 45 minutes ago while mowing the lawn.\n'
        'Doctor: BP is 92 over 58, heart rate is 112, oxygen saturation is 93%.',
      );
      expect(_vital(e, 'Heart Rate'), '112 bpm');
      expect(_vital(e, 'BP'), '92/58 mmHg');
      expect(_vital(e, 'SpO2'), '93%');
    });

    test('does not invent vitals that were never mentioned', () {
      final e = _synth('Patient: My knee has been hurting for 3 days after 2 falls.\nDoctor: Let us get an MRI.');
      expect(e.vitals, isEmpty);
    });

    test('ignores pulse oximetry when looking for pulse', () {
      final e = _synth('Doctor: Pulse ox is 97 percent and pulse 68.');
      expect(_vital(e, 'Heart Rate'), '68 bpm');
      expect(_vital(e, 'SpO2'), '97%');
    });

    test('reads blood pressure phrased with filler words', () {
      final e = _synth('Doctor: Nurse took your blood pressure, looks like 138 over 86, pulse is 76.');
      expect(_vital(e, 'BP'), '138/86 mmHg');
      expect(_vital(e, 'Heart Rate'), '76 bpm');
    });

    test('flags abnormal values', () {
      final e = _synth('Doctor: temperature is 101.2F, heart rate 120, blood pressure 118/76.');
      final temp = e.vitals.firstWhere((v) => v.label == 'Temp');
      final hr = e.vitals.firstWhere((v) => v.label == 'Heart Rate');
      final bp = e.vitals.firstWhere((v) => v.label == 'BP');
      expect(temp.isAbnormal, isTrue);
      expect(hr.isAbnormal, isTrue);
      expect(bp.isAbnormal, isFalse);
    });
  });
}
