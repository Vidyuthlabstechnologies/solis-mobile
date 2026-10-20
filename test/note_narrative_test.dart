import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/data/sample_conversations.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';

ClinicalEncounter _note(String text) => LocalClinicalEngine.synthesizeOnDevice(
      rawSpeech: text,
      patientName: 'Test Patient',
      mrn: 'SOL-1',
      ageGender: '50M',
      attending: 'Dr. Test',
    );

ClinicalEncounter _sample(String key) => _note(sampleConversations[key]!);

const _stemi = 'Acute Inferior STEMI';
const _pneumonia = 'Community-Acquired Pneumonia';
const _migraine = 'Acute Migraine with Aura';
const _neuropathy = 'Diabetic Peripheral Neuropathy';
const _knee = 'Right Knee Meniscus Injury';

/// Diagnosis terms that must never appear in an assessment unless the
/// conversation itself used them.
const _diagnosisTerms = [
  'stemi',
  'myocardial infarction',
  'pneumonia',
  'bronchitis',
  'migraine',
  'neuropathy',
  'meniscal',
  'meniscus',
  'hemarthrosis',
  'diabetes',
  'type 2',
  'hypertension',
  'heart failure',
  'asthma',
  'copd',
  'fracture',
  'sprain',
  'internal derangement',
  'cruciate',
  'sinusitis',
  'gastroenteritis',
];

void main() {
  group('Subjective is a third-person HPI', () {
    for (final key in sampleConversations.keys) {
      test('$key: no first person, no small talk, concise', () {
        final s = _sample(key).subjective;
        expect(RegExp(r'\bI\b').hasMatch(s), isFalse, reason: s);
        expect(RegExp(r'\bmy\b', caseSensitive: false).hasMatch(s), isFalse, reason: s);
        expect(RegExp(r"\bI'(m|ve|d|ll)\b", caseSensitive: false).hasMatch(s), isFalse, reason: s);
        for (final w in ['basketball', 'Warriors', 'grandson', 'haha', 'Oh god', 'good morning', 'elephant', 'like crazy']) {
          expect(s.toLowerCase().contains(w.toLowerCase()), isFalse, reason: '"$w" in: $s');
        }
        expect(s.length, lessThan(700), reason: s);
        expect(s, startsWith('Patient presents with'));
      });
    }

    test('STEMI: character, radiation, diaphoresis and onset', () {
      final s = _sample(_stemi).subjective.toLowerCase();
      expect(s, contains('crushing'));
      expect(s, contains('chest pain'));
      expect(s, contains('radiating to the jaw and left arm'));
      expect(s, contains('diaphoresis'));
      expect(s, contains('45 minutes ago'));
      expect(s, contains('mowing the lawn'));
    });

    test('Pneumonia: productive cough, fever 101.5, right-sided pleuritic pain, exertional dyspnea', () {
      final s = _sample(_pneumonia).subjective.toLowerCase();
      expect(s, contains('productive cough'));
      expect(s, contains('green sputum'));
      expect(s, contains('fever to 101.5'));
      expect(s, contains('right-sided pleuritic chest pain'));
      expect(s, contains('dyspnea on exertion'));
      expect(s, contains('three or four days'));
    });

    test('Migraine: aura, photophobia, nausea and vomiting, 18 hours, pertinent negatives, failed ibuprofen', () {
      final s = _sample(_migraine).subjective.toLowerCase();
      expect(s, contains('headache'));
      expect(s, contains('visual aura'));
      expect(s, contains('photophobia'));
      expect(s, contains('phonophobia'));
      expect(s, contains('nausea and vomiting'));
      expect(s, contains('18 hours'));
      expect(s, contains('denies fever'));
      expect(s, contains('neck stiffness'));
      expect(s, contains('ibuprofen without relief'));
    });

    test('Neuropathy: bilateral burning paresthesias, nocturnal, numbness, diabetes history', () {
      final s = _sample(_neuropathy).subjective.toLowerCase();
      expect(s, contains('burning'));
      expect(s, contains('pins-and-needles'));
      expect(s, contains('both feet'));
      expect(s, contains('past couple of weeks'));
      expect(s, contains('worse at night'));
      expect(s, contains('numbness'));
      expect(s, contains('history of diabetes'));
    });

    test('Knee: mechanism, pop and swelling', () {
      final s = _sample(_knee).subjective.toLowerCase();
      expect(s, contains('twisting injury of the right knee'));
      expect(s, contains('playing pickup soccer'));
      expect(s, contains('audible pop'));
      expect(s, contains('swelling within an hour'));
    });
  });

  group('Objective holds stated vitals and findings only', () {
    test('Vitals summary lists only what was said', () {
      final o = _sample(_migraine).objective;
      expect(o, contains('Vitals: BP 128/82 mmHg, HR 74 bpm.'));
      expect(o, isNot(contains('SpO2')));
      expect(o, isNot(contains('Temp')));
      expect(o, contains('Pupils equal and reactive'));
    });

    test('Findings are written as findings, without conversation', () {
      final pneu = _sample(_pneumonia).objective;
      expect(pneu, contains('Temp 101.2 F'));
      expect(pneu, contains('crackles'));
      expect(pneu, isNot(contains('Take a deep breath')));
      final stemi = _sample(_stemi).objective;
      expect(stemi, contains('ST-segment elevation'));
      expect(stemi, isNot(contains('Looking at your')));
      final neuro = _sample(_neuropathy).objective;
      expect(neuro, contains('HbA1c 8.2'));
      expect(neuro, contains('reduced vibration sense'));
      expect(neuro, isNot(contains('consistent with')), reason: 'interpretation belongs in the assessment');
    });

    test('Says so honestly when nothing was examined', () {
      final e = _note('Patient reports a sore throat for two days. Start ibuprofen 400 mg every 6 hours as needed.');
      expect(e.objective, 'No exam findings documented.');
    });
  });

  group('Assessment states only coded diagnoses', () {
    for (final key in sampleConversations.keys) {
      test('$key: no diagnosis absent from the conversation', () {
        final a = _sample(key).assessment.toLowerCase();
        final convo = sampleConversations[key]!.toLowerCase();
        for (final term in _diagnosisTerms) {
          if (a.contains(term)) {
            expect(convo.contains(term), isTrue, reason: '"$term" in assessment but never said: $a');
          }
        }
        expect(a.length, lessThan(500), reason: a);
      });
    }

    test('Confirmed diagnoses appear as stated', () {
      expect(_sample(_stemi).assessment, contains('Acute inferior wall STEMI'));
      expect(_sample(_migraine).assessment, contains('Acute migraine with aura'));
    });

    test('Uncertain diagnoses carry their qualifier and pending test', () {
      final pneu = _sample(_pneumonia).assessment;
      expect(pneu, contains('Suspected community-acquired pneumonia in the right lower lobe'));
      expect(pneu, contains('chest X-ray pending'));
      final knee = _sample(_knee).assessment;
      expect(knee, contains('Suspected medial meniscal tear with traumatic hemarthrosis, right knee'));
      expect(knee, contains('MRI of the right knee pending'));
      final neuro = _sample(_neuropathy).assessment;
      expect(neuro, contains('Findings consistent with diabetic peripheral neuropathy'));
    });

    test('No diagnosis is inferred from symptoms alone', () {
      // Chest pain radiating to the jaw is not a STEMI until the physician says so.
      final e = _note('Patient reports crushing chest pain radiating to the jaw and left arm. BP 130/80. Obtain ECG and troponin.');
      expect(e.assessment.toLowerCase(), isNot(contains('stemi')));
      expect(e.assessment.toLowerCase(), isNot(contains('infarction')));
      expect(e.assessment, contains('No diagnosis stated'));
    });
  });

  group('Plan is numbered discrete actions', () {
    test('Medications keep the dose, route and frequency that were said', () {
      String plan(String key) => _sample(key).plan.toLowerCase();
      expect(plan(_neuropathy), contains('gabapentin 300 mg at bedtime'));
      expect(plan(_neuropathy), contains('metformin 1000 mg twice daily with meals'));
      expect(plan(_migraine), contains('sumatriptan 50 mg'));
      expect(plan(_migraine), contains('ondansetron 4 mg'));
      expect(plan(_stemi), contains('aspirin 325 mg'));
      expect(plan(_stemi), contains('ticagrelor 180 mg'));
      expect(plan(_pneumonia), contains('augmentin 875 mg twice a day for 7 days'));
    });

    test('Tests, referrals, instructions, follow-up and return precautions', () {
      final knee = _sample(_knee).plan;
      expect(knee, contains('MRI of the right knee'));
      expect(knee, contains('referral to Dr. Martinez in orthopedic surgery'));
      expect(knee, contains('non-weight bearing'));
      expect(knee, isNot(contains('using crutches today')), reason: 'an observation is not an order');
      final pneu = _sample(_pneumonia).plan;
      expect(pneu, contains('2-view chest X-ray'));
      expect(pneu, contains('Return precautions:'));
      expect(_sample(_neuropathy).plan, contains('Follow up in 6 weeks'));
    });

    test('Every plan line is numbered and the plan is short', () {
      for (final key in sampleConversations.keys) {
        final lines = _sample(key).plan.split('\n');
        for (var i = 0; i < lines.length; i++) {
          expect(lines[i], startsWith('${i + 1}. '), reason: '$key: ${lines[i]}');
        }
        expect(_sample(key).plan.length, lessThan(800));
      }
    });

    test('Nothing is planned that was not said', () {
      final e = _note('Right knee injury with swelling and pain after fall. BP 120/80, pulse 70.');
      expect(e.plan, 'No plan documented.');
      expect(e.plan, isNot(contains('MRI')));
    });
  });

  group('CDI recommendations come from the note itself', () {
    test('Uncertain diagnosis awaiting a test', () {
      final cdi = _sample(_pneumonia).cdiRecommendations;
      expect(cdi.any((c) => c.contains('pneumonia') && c.contains('chest X-ray')), isTrue, reason: cdi.join('\n'));
      expect(cdi.any((c) => c.startsWith('Azithromycin') && c.contains('without a dose')), isTrue);
    });

    test('A complete, confirmed note has no recommendations', () {
      expect(_sample(_migraine).cdiRecommendations, isEmpty);
    });

    test('Symptom-only and missing laterality are flagged; no boilerplate', () {
      final e = _note('Patient reports knee pain after a twisting injury. BP 120/80.');
      expect(e.cdiRecommendations.any((c) => c.contains('Laterality')), isTrue, reason: e.cdiRecommendations.join('\n'));
      expect(e.cdiRecommendations.any((c) => c.contains('Only symptoms')), isTrue);
      for (final key in sampleConversations.keys) {
        for (final c in _sample(key).cdiRecommendations) {
          expect(c, isNot(contains('maximal medical necessity')));
          expect(c, isNot(contains('confirm patient adherence')));
        }
      }
    });
  });

  group('Input formats', () {
    test('Unlabeled single-speaker dictation', () {
      final e = _note(
        'Patient is a 62 year old with crushing substernal chest pain for 2 hours radiating to the left arm. He denies shortness of breath. '
        'On exam lungs are clear. BP 150/90, heart rate 96. Assessment is acute coronary syndrome versus unstable angina. '
        'Give aspirin 325 mg now, obtain ECG and troponin, and admit to telemetry.',
      );
      expect(e.subjective, contains('chest pain'));
      expect(e.subjective, contains('for 2 hours'));
      expect(e.subjective, contains('left arm'));
      expect(e.subjective.toLowerCase(), contains('denies shortness of breath'));
      expect(e.objective, contains('Vitals: BP 150/90 mmHg, HR 96 bpm.'));
      expect(e.objective.toLowerCase(), contains('lungs are clear'));
      expect(e.plan.toLowerCase(), contains('aspirin 325 mg'));
      expect(e.plan.toLowerCase(), contains('troponin'));
    });

    test('Unlabeled live speech', () {
      final e = _note(
        'What brings you in today? I have had a pounding headache for two days and I threw up this morning. '
        'Any fever? No fever. On exam your neck is supple. I am prescribing sumatriptan 50 mg.',
      );
      expect(e.subjective, startsWith('Patient presents with pounding headache for two days'));
      expect(e.subjective, contains('vomiting'));
      expect(e.subjective, contains('Denies fever'));
      expect(e.subjective, isNot(contains('I have')));
      expect(e.objective, contains('Neck is supple'));
      expect(e.plan, contains('Sumatriptan 50 mg'));
    });

    test('Explicit SOAP headings are kept in the physician\'s words', () {
      final e = _note('Subjective: cough for 3 days. Objective: lungs clear. Assessment: acute bronchitis. Plan: supportive care, fluids.');
      expect(e.subjective, 'cough for 3 days.');
      expect(e.objective, 'lungs clear.');
      expect(e.assessment, 'acute bronchitis.');
      expect(e.plan, 'supportive care, fluids.');
    });

    test('Output uses plain characters only', () {
      for (final key in sampleConversations.keys) {
        final e = _sample(key);
        final all = [e.subjective, e.objective, e.assessment, e.plan, ...e.cdiRecommendations].join('\n');
        expect(all.runes.every((r) => r < 0x2000), isTrue, reason: '$key has a non-plain character');
      }
    });
  });
}
