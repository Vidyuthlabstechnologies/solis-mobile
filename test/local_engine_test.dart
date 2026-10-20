import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';

void main() {
  group('LocalClinicalEngine Autonomous Tests', () {
    test('Synthesizes Diabetic Neuropathy encounter quickly on device', () {
      final rawSpeech =
          'Patient has severe burning sensation in feet at night. BP is 135/85, pulse 74, SpO2 98%. Need to adjust metformin and add gabapentin.';

      ClinicalEncounter run() => LocalClinicalEngine.synthesizeOnDevice(
            rawSpeech: rawSpeech,
            patientName: 'Margaret Vance',
            mrn: 'MRN-101',
            ageGender: '67F',
            attending: 'Dr. Sarah Lin, MD',
          );
      // Warm up once (JIT), then time the median of five runs so a busy test
      // machine running suites in parallel does not fail a speed check.
      final encounter = run();
      final times = <int>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        run();
        sw.stop();
        times.add(sw.elapsedMicroseconds);
      }
      times.sort();
      final medianMs = times[2] / 1000;

      expect(encounter.patientName, 'Margaret Vance');
      expect(encounter.vitals.any((v) => v.label == 'BP' && v.value == '135/85 mmHg'), isTrue);
      // Dictation reports a symptom and medication changes, but never states
      // a diagnosis, so the symptom is coded, not a presumed diabetes code.
      expect(encounter.codes.any((c) => c.code == 'R20.2'), isTrue);
      expect(encounter.codes.any((c) => c.code.startsWith('E11')), isFalse);
      expect(encounter.codes.any((c) => c.code == '99214'), isTrue, reason: 'prescription drug management is moderate MDM');
      expect(encounter.soapSections['Subjective']!.isNotEmpty, isTrue);
      expect(encounter.soapSections['Plan']!.isNotEmpty, isTrue);
      expect(encounter.isLocalEngine, isTrue);
      expect(medianMs, lessThan(100));
    });

    test('Synthesizes Acute Inferior STEMI with immediate cath lab plan', () {
      final rawSpeech =
          'Crushing chest pain radiating to jaw with ST elevation. BP 90/60, heart rate 110, oxygen 92%. Immediate cath lab required.';

      final encounter = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: rawSpeech,
        patientName: 'Robert Hayes',
        mrn: 'MRN-202',
        ageGender: '58M',
        attending: 'Dr. Sarah Lin, MD',
      );

      expect(encounter.patientName, 'Robert Hayes');
      // "ST elevation" is a finding, not a stated diagnosis; the dictated chest
      // pain is coded, and the cath lab decision makes it high MDM.
      expect(encounter.codes.any((c) => c.code == 'R07.89'), isTrue);
      expect(encounter.codes.any((c) => c.code.startsWith('I21')), isFalse);
      expect(encounter.codes.any((c) => c.code == '99215'), isTrue);
    });

    test('Synthesizes Knee Derangement with MRI plan', () {
      final rawSpeech =
          'Right knee injury with swelling and pain after fall. BP 120/80, pulse 70, o2 99%.';

      final encounter = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: rawSpeech,
        patientName: 'David Miller',
        mrn: 'MRN-303',
        ageGender: '34M',
        attending: 'Dr. Sarah Lin, MD',
      );

      expect(encounter.patientName, 'David Miller');
      expect(encounter.codes.any((c) => c.code == 'M25.461'), isTrue);
      // This dictation never mentions an MRI or any other order. The note
      // used to insert "Order urgent right knee MRI..." whenever "knee"
      // appeared, putting an order the physician never gave into a signed
      // note. The written plan now says only what was said; the MRI stays
      // available as a suggested next step derived from the codes.
      expect(encounter.soapSections['Plan']!.first, 'No plan documented.');
      expect(encounter.plan, isNot(contains('MRI')));
      expect(encounter.nextSteps.any((a) => a.title.contains('MRI')), isTrue);
    });

    test('Parses multi-speaker dialogue into organized turns with speaker isolation', () {
      const dialogue = '''
Doctor: Good morning Mrs. Vance! Did you watch the Warriors game last night?
Patient: Good morning Doctor! Yes, we won in overtime! But my feet have been burning.
Doctor: On examination, vibration sense is diminished.
''';

      final turns = LocalClinicalEngine.parseSpeakers(dialogue);
      expect(turns.length, 3);
      expect(turns[0].speaker, 'Doctor');
      expect(turns[0].text, contains('Warriors game'));
      expect(turns[1].speaker, 'Patient');
      expect(turns[1].text, contains('feet have been burning'));
      expect(turns[2].speaker, 'Doctor');
      expect(turns[2].text, contains('vibration sense is diminished'));
    });

    test('Integrates medical codes into actionable clinical next steps (orders, Rx, referrals)', () {
      final encounter = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: 'Patient has diabetic neuropathy with burning feet and A1c 8.2.',
        patientName: 'Margaret Vance',
        mrn: 'MRN-101',
        ageGender: '67F',
        attending: 'Dr. Sarah Lin, MD',
      );

      expect(encounter.nextSteps.isNotEmpty, isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('A1c Glycemic Panel')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('Gabapentin')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('Podiatry')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('MDM Audit Validation')), isTrue);
    });

    test('Generates urgent STEMI next steps (Cath Lab, Stat Aspirin, Ticagrelor, Heparin)', () {
      final encounter = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: 'Acute STEMI with ST elevation in leads II, III, aVF.',
        patientName: 'Robert Hayes',
        mrn: 'MRN-202',
        ageGender: '58M',
        attending: 'Dr. Sarah Lin, MD',
      );

      expect(encounter.nextSteps.any((a) => a.urgency == 'Stat' && a.title.contains('Cath Lab')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('Chewable Aspirin')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('Ticagrelor')), isTrue);
    });

    test('Generates knee injury next steps with Prior Auth and Orthopedic surgery referral', () {
      final encounter = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: 'Right knee meniscus injury with hemarthrosis after sports fall.',
        patientName: 'David Miller',
        mrn: 'MRN-303',
        ageGender: '34M',
        attending: 'Dr. Sarah Lin, MD',
      );

      expect(encounter.nextSteps.any((a) => a.title.contains('3T MRI')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('Prior Auth')), isTrue);
      expect(encounter.nextSteps.any((a) => a.title.contains('Orthopedic Sports Surgery')), isTrue);
    });
  });
}
