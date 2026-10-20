// One focused test per knowledge-base rule closed from knowledge/GAP_REPORT.md,
// with small injected fixtures (ReferenceData.inject), plus the rule id and
// citation contract every ClaimIssue now carries.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/coding/rule_citations.g.dart';
import 'support/test_provider.dart';

final _provider = testProvider();

const _dos = '2026-10-15';

Visit _visit({int number = 1, String dos = _dos, String pos = '11', ClaimDraft? claim}) =>
    Visit(number: number, dateOfService: dos, placeOfService: pos, createdAtUtc: DateTime(2026), claim: claim);

PatientAccount _patient({int age = 46, PatientSex sex = PatientSex.male, List<Visit>? visits}) => PatientAccount(
      accountNumber: 'SOL-10000017',
      firstName: 'Pat',
      lastName: 'Lee',
      sex: sex,
      dateOfBirth: DateTime(2026 - age, 5, 1),
      createdAtUtc: DateTime(2026),
      insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: 'W1'),
      visits: visits ?? [_visit()],
    );

ServiceLine _line(String code, {List<String> modifiers = const [], int units = 1}) =>
    ServiceLine(code: code, description: code, modifiers: modifiers, units: units, charge: 100);

ClaimDraft _claim(List<String> dx, List<ServiceLine> lines) => ClaimDraft(
      diagnoses: [for (final d in dx) ClaimDiagnosis(code: d, description: d, source: DxSource.manual)],
      lines: [for (final l in lines) l.copyWith(diagnosisCodes: dx.take(4).toList())],
      generatedAtUtc: DateTime(2026),
    );

List<ClaimIssue> _check(
  List<String> dx, {
  List<ServiceLine>? lines,
  int age = 46,
  PatientSex sex = PatientSex.male,
  List<Visit>? history,
  Visit? visit,
}) {
  final v = visit ?? _visit();
  return ClaimScrubber.check(
    claim: _claim(dx, lines ?? [_line('99214')]),
    account: _patient(age: age, sex: sex, visits: [...?history, v]),
    visit: v,
    provider: _provider,
    noteSigned: true,
  );
}

List<ClaimIssue> _rule(List<ClaimIssue> issues, String id) => issues.where((i) => i.ruleId == id).toList();

const _icdFixture = 'E11.9\t1\tType 2 diabetes mellitus without complications\n'
    'E11.42\t1\tType 2 diabetes mellitus with diabetic polyneuropathy\n'
    'G62.9\t1\tPolyneuropathy, unspecified\n'
    'G63\t1\tPolyneuropathy in diseases classified elsewhere\n'
    'E85.0\t1\tNon-neuropathic heredofamilial amyloidosis\n'
    'I11.0\t1\tHypertensive heart disease with heart failure\n'
    'I50.9\t1\tHeart failure, unspecified\n'
    'I21.19\t1\tST elevation (STEMI) myocardial infarction involving other coronary artery of inferior wall\n'
    'R07.9\t1\tChest pain, unspecified\n'
    'R53.83\t1\tOther fatigue\n'
    'M17\t0\tOsteoarthritis of knee\n'
    'M17.0\t1\tBilateral primary osteoarthritis of knee\n'
    'M17.11\t1\tUnilateral primary osteoarthritis, right knee\n'
    'M17.12\t1\tUnilateral primary osteoarthritis, left knee\n'
    'H66.91\t1\tOtitis media, unspecified, right ear\n'
    'H66.92\t1\tOtitis media, unspecified, left ear\n'
    'H66.93\t1\tOtitis media, unspecified, bilateral\n'
    'M25.569\t1\tPain in unspecified knee\n'
    'C50.911\t1\tMalignant neoplasm of unspecified site of right female breast\n'
    'Z85.3\t1\tPersonal history of malignant neoplasm of breast\n'
    'J20.9\t1\tAcute bronchitis, unspecified\n'
    'J42\t1\tUnspecified chronic bronchitis\n'
    'J96.00\t1\tAcute respiratory failure, unspecified whether with hypoxia or hypercapnia\n'
    'J96.10\t1\tChronic respiratory failure, unspecified whether with hypoxia or hypercapnia\n'
    'J96.20\t1\tAcute and chronic respiratory failure, unspecified whether with hypoxia or hypercapnia\n'
    'J45.909\t1\tUnspecified asthma, uncomplicated\n'
    'R06.2\t1\tWheezing\n'
    'S83.241A\t1\tOther tear of medial meniscus, current injury, right knee, initial encounter\n'
    'S83.241D\t1\tOther tear of medial meniscus, current injury, right knee, subsequent encounter\n'
    'S83.241S\t1\tOther tear of medial meniscus, current injury, right knee, sequela\n'
    'N39.0\t1\tUrinary tract infection, site not specified\n'
    'B96.20\t1\tUnspecified Escherichia coli [E. coli] as the cause of diseases classified elsewhere\n'
    'Z87.891\t1\tPersonal history of nicotine dependence\n'
    'I10\t1\tEssential (primary) hypertension\n'
    'Z01.818\t1\tEncounter for other preprocedural examination\n'
    'Z34.00\t1\tEncounter for supervision of normal first pregnancy, unspecified trimester\n'
    'O99.891\t1\tOther specified diseases and conditions complicating pregnancy\n'
    'Z3A.20\t1\t20 weeks gestation of pregnancy\n'
    'T36.0X5A\t1\tAdverse effect of penicillins, initial encounter\n'
    'T36.0X6A\t1\tUnderdosing of penicillins, initial encounter\n'
    'T36.0X1A\t1\tPoisoning by penicillins, accidental (unintentional), initial encounter\n'
    'L27.0\t1\tGeneralized skin eruption due to drugs and medicaments taken internally\n'
    'Z94.1\t1\tHeart transplant status\n'
    'T86.21\t1\tHeart transplant rejection\n'
    'Y92.9\t1\tUnspecified place or not applicable\n'
    'Y99.0\t1\tCivilian activity done for income or pay\n'
    'Y99.8\t1\tOther external cause status\n'
    'W19.XXXA\t1\tUnspecified fall, initial encounter\n'
    'Z51.11\t1\tEncounter for antineoplastic chemotherapy\n'
    'Z48.02\t1\tEncounter for removal of sutures\n'
    'O80\t1\tEncounter for full-term uncomplicated delivery\n';

const _indexFixture = 'Diabetes, diabetic|type 2\tE11.9\n'
    'Diabetes, diabetic|type 2|with|polyneuropathy\tE11.42\n'
    'Polyneuropathy\tG62.9\n'
    'Failure, failed|respiration, respiratory|acute\tJ96.00\n'
    'Failure, failed|respiration, respiratory|chronic\tJ96.10\n'
    'Failure, failed|respiration, respiratory|acute and chronic\tJ96.20\n'
    'Bronchitis|acute or subacute\tJ20.9\n'
    'Bronchitis|chronic\tJ42\n'
    'History|personal|malignant neoplasm|breast\tZ85.3\n';

const _notesFixture = 'G63\tCF\tunderlying disease, such as:\t\n'
    'G63\tCF\tamyloidosis (E85.-)\tE85.-\n'
    'I50\tCF\theart failure due to hypertension (I11.0)\tI11.0\n'
    'E11\tUA\tcode to identify control using:\t\n'
    'E11\tUA\tinsulin (Z79.4)\tZ79.4\n'
    'E11\tUA\toral antidiabetic drugs (Z79.84)\tZ79.84\n'
    'N39.0\tUA\tcode (B95-B97), to identify infectious agent.\tB95-B97\n'
    'J44\tCA\ttype of asthma, if applicable (J45.-)\tJ45.-\n'
    'Z3A\tCF\tobstetric condition or encounter for delivery (O09-O60, O80-O82, O94-O9A)\tO09-O60,O80-O82,O94-O9A\n'
    'A00-B99\tUA\tcode to identify resistance to antimicrobial drugs (Z16.-)\tZ16.-\n';

const _feeFixture = '27447\tA\t34.71\t34.71\t090\t19.11\t0\t1\n'
    '17000\tA\t1.99\t1.43\t010\t0.59\t0\t0\n'
    '20610\tA\t2.06\t1.19\t000\t0.77\t0\t1\n'
    '96372\tA\t0.46\t0.46\tXXX\t0.17\t5\t0\n'
    '93000\tA\t0.46\t0.46\tXXX\t0.17\t4\t0\n'
    '99214\tA\t4.06\t2.53\tXXX\t1.92\t0\t0\n'
    '69210\tA\t1.43\t0.81\t000\t0.59\t0\t2\n'
    '64483\tA\t7.93\t2.98\t000\t1.85\t0\t1\n'
    '96413\tA\t3.99\t3.99\tXXX\t0.28\t5\t0\n'
    '80053\tX\t0\t0\tXXX\t0\t9\t9\n';

void _injectAll() {
  ReferenceData.inject(
    icd: {2027: IcdCatalog.parse(_icdFixture, fiscalYear: 2027)},
    index: {2027: IcdIndex.parse(_indexFixture, fiscalYear: 2027)},
    icdNotes: IcdNotes.parse(_notesFixture),
    feeSchedule: FeeSchedule.parse(_feeFixture),
    seventhCharacters: SeventhCharacters.parse('S83\tA=initial encounter|D=subsequent encounter|S=sequela\n'
        'T36\tA=initial encounter|D=subsequent encounter|S=sequela\n'),
    mceLists: Mce.parse('manifestation_not_principal\t\t\tG63\nunspecified_with_laterality_available\t\t\tM25.569\n'),
    excludes1Notes: Excludes1.parse('J45\tR06.2\n'),
  );
}

CodingResult _code(String text, {Set<String> prior = const {}}) => ClinicalCoder.code(
      turns: ClinicalCoder.diarize(text),
      vitals: const [],
      context: CodingContext(age: 60, sex: PatientSex.female, dateOfService: DateTime(2026, 10, 15), priorDiagnosisCodes: prior),
    );

void main() {
  setUp(_injectAll);
  tearDown(ReferenceData.clear);

  group('Tabular notes', () {
    test('ICD-DUP-01: a code listed twice is an error', () {
      expect(_rule(_check(['I10', 'I10']), 'ICD-DUP-01').single.severity, IssueSeverity.error);
      expect(_rule(_check(['I10', 'E11.9']), 'ICD-DUP-01'), isEmpty);
    });

    test('ICD-CODEFIRST-01: the condition a code-first note names goes first, and the coder reorders', () {
      final issues = _rule(_check(['I50.9', 'I11.0']), 'ICD-CODEFIRST-01');
      expect(issues.single.title, 'List I11.0 before I50.9');
      expect(issues.single.citation, 'ICD-10-CM Guidelines I.A.13');
      expect(_rule(_check(['I11.0', 'I50.9']), 'ICD-CODEFIRST-01'), isEmpty);
      final ordered = ClinicalCoder.finalizeDiagnoses([
        const ClaimDiagnosis(code: 'I50.9', description: 'HF', source: DxSource.manual),
        const ClaimDiagnosis(code: 'I11.0', description: 'HHD', source: DxSource.manual),
      ]);
      expect(ordered.map((d) => d.code), ['I11.0', 'I50.9']);
      final pinned = ClinicalCoder.finalizeDiagnoses(ordered.reversed.toList(), pinnedOrder: ['I50.9']);
      expect(pinned.first.code, 'I50.9', reason: 'a physician-pinned first code stays first');
    });

    test('ICD-MANIF-01: the etiology named in the manifestation note is listed before it', () {
      final issues = _rule(_check(['I10', 'G63', 'E85.0']), 'ICD-MANIF-01');
      expect(issues.single.title, 'Underlying disease listed after its manifestation: E85.0');
      expect(_rule(_check(['E85.0', 'G63']), 'ICD-MANIF-01'), isEmpty);
    });

    test('ICD-USEADD-01: a use-additional-code note without its code is a suggestion', () {
      final issues = _rule(_check(['N39.0']), 'ICD-USEADD-01');
      expect(issues.single.severity, IssueSeverity.info);
      expect(issues.single.detail, contains('B95-B97'));
      expect(_rule(_check(['N39.0', 'B96.20']), 'ICD-USEADD-01'), isEmpty);
    });

    test('ICD-CODEALSO-01: code-also notes are informational', () {
      expect(_rule(_check(['J44.9']), 'ICD-CODEALSO-01').single.severity, IssueSeverity.info);
      expect(_rule(_check(['J44.9', 'J45.909']), 'ICD-CODEALSO-01'), isEmpty);
    });

    test('notes are skipped silently when the notes asset is not loaded', () {
      ReferenceData.notes = null;
      final issues = _check(['I50.9', 'I11.0', 'N39.0']);
      expect(issues.where((i) => i.ruleId == 'ICD-CODEFIRST-01' || i.ruleId == 'ICD-USEADD-01'), isEmpty);
    });
  });

  group('Diabetes (CH4-DM-01)', () {
    test('scrubber suggests the Z79 group; one Z79 code satisfies it', () {
      expect(_rule(_check(['E11.9']), 'CH4-DM-01').single.detail, contains('Z79.4'));
      expect(_rule(_check(['E11.9', 'Z79.84']), 'CH4-DM-01'), isEmpty);
    });

    test('coder adds Z79.84 for current metformin and not Z79.4 for temporary insulin', () {
      final r = _code('Doctor: Your type 2 diabetes is stable. Keep taking your metformin twice daily.\n'
          'Doctor: I gave a temporary insulin dose in the office today to bring the sugar down.');
      final codes = r.billable.map((d) => d.code).toList();
      expect(codes, contains('Z79.84'));
      expect(codes, isNot(contains('Z79.4')));
    });
  });

  group('Sequencing', () {
    test('ICD-SEQUELA-01: a sequela code follows its residual condition', () {
      expect(_rule(_check(['S83.241S']), 'ICD-SEQUELA-01').single.title, contains('without the residual condition'));
      expect(_rule(_check(['S83.241S', 'M17.11']), 'ICD-SEQUELA-01').single.title, contains('listed first'));
      expect(_rule(_check(['M17.11', 'S83.241S']), 'ICD-SEQUELA-01'), isEmpty);
    });

    test('ICD-SYMPTOM-02 and CH2-NEO-02: a symptom is not first before its diagnosis or a malignancy', () {
      expect(_rule(_check(['R07.9', 'I21.19']), 'ICD-SYMPTOM-02'), hasLength(1));
      expect(_rule(_check(['I21.19', 'R07.9']), 'ICD-SYMPTOM-02'), isEmpty);
      expect(_rule(_check(['R53.83', 'C50.911'], sex: PatientSex.female), 'CH2-NEO-02'), hasLength(1));
    });

    test('OP-FIRSTLISTED-01: a history code is not the first-listed diagnosis', () {
      expect(_rule(_check(['Z87.891', 'I10']), 'OP-FIRSTLISTED-01'), hasLength(1));
      expect(_rule(_check(['I10', 'Z87.891']), 'OP-FIRSTLISTED-01'), isEmpty);
    });

    test('OP-PREOP-01: the coder lists Z01.81- first and the scrubber cites IV.M when it is not', () {
      final r = _code('Doctor: This is a preoperative evaluation before your knee surgery. Your hypertension is controlled on lisinopril.');
      expect(r.billable.first.code, 'Z01.818');
      final issues = _rule(_check(['I10', 'Z01.818']), 'OP-PREOP-01');
      expect(issues.single.severity, IssueSeverity.error);
      expect(issues.single.citation, 'ICD-10-CM Guidelines IV.M');
    });

    test('OP-THERAPY-01: a chemotherapy administration visit lists Z51.11 first', () {
      expect(_rule(_check(['C50.911'], lines: [_line('96413')], sex: PatientSex.female), 'OP-THERAPY-01'), hasLength(1));
      expect(_rule(_check(['Z51.11', 'C50.911'], lines: [_line('96413')], sex: PatientSex.female), 'OP-THERAPY-01'), isEmpty);
    });

    test('CH15-OB-02/03/04: pregnancy sequencing', () {
      final f = PatientSex.female;
      expect(_rule(_check(['Z34.00', 'O99.891'], age: 30, sex: f), 'CH15-OB-03').single.severity, IssueSeverity.error);
      expect(_rule(_check(['I10', 'O99.891'], age: 30, sex: f), 'CH15-OB-02'), hasLength(1));
      expect(_rule(_check(['O99.891', 'I10'], age: 30, sex: f), 'CH15-OB-02'), isEmpty);
      expect(_rule(_check(['Z3A.20'], age: 30, sex: f), 'CH15-OB-04').single.title, contains('without an obstetric code'));
      expect(_rule(_check(['Z3A.20', 'O80'], age: 30, sex: f), 'CH15-OB-04').single.title, contains('listed first'));
      final ordered = ClinicalCoder.finalizeDiagnoses([
        const ClaimDiagnosis(code: 'I10', description: 'HTN', source: DxSource.manual),
        const ClaimDiagnosis(code: 'O99.891', description: 'OB', source: DxSource.manual),
      ]);
      expect(ordered.first.code, 'O99.891', reason: 'the coder gives Chapter 15 codes sequencing priority');
    });

    test('CH19-POIS-01: underdosing never first, adverse effect after its effect, poisoning first', () {
      expect(_rule(_check(['T36.0X6A', 'I10']), 'CH19-POIS-01').single.severity, IssueSeverity.error);
      expect(_rule(_check(['T36.0X5A', 'L27.0']), 'CH19-POIS-01').single.severity, IssueSeverity.warning);
      expect(_rule(_check(['L27.0', 'T36.0X5A']), 'CH19-POIS-01'), isEmpty);
      expect(_rule(_check(['L27.0', 'T36.0X1A']), 'CH19-POIS-01').single.title, contains('Poisoning code not listed first'));
    });
  });

  group('Code combinations', () {
    test('CH21-Z-02: the transplant complication already includes the status', () {
      expect(_rule(_check(['T86.21', 'Z94.1']), 'CH21-Z-02').single.code, 'Z94.1');
      expect(_rule(_check(['Z94.1', 'I10']), 'CH21-Z-02'), isEmpty);
    });

    test('CH2-NEO-01: current malignancy and history of the same site', () {
      expect(_rule(_check(['C50.911', 'Z85.3'], sex: PatientSex.female), 'CH2-NEO-01'), hasLength(1));
    });

    test('ICD-EXTCAUSE-02: one Y99, no Y92.9, and with an external cause code', () {
      final issues = _rule(_check(['S83.241A', 'W19.XXXA', 'Y92.9', 'Y99.0', 'Y99.8']), 'ICD-EXTCAUSE-02');
      expect(issues.map((i) => i.title), containsAll(['More than one external cause status: Y99.0, Y99.8', 'Unspecified place or status: Y92.9']));
      expect(_rule(_check(['S83.241A', 'Y99.0']), 'ICD-EXTCAUSE-02').single.title, contains('without its external cause'));
    });

    test('ICD-LAT-01: right and left codes when a bilateral code exists', () {
      expect(_rule(_check(['M17.11', 'M17.12']), 'ICD-LAT-01').single.title, 'Use the bilateral code: M17.0');
      expect(_rule(_check(['H66.91', 'H66.92']), 'ICD-LAT-01').single.title, 'Use the bilateral code: H66.93');
      expect(_rule(_check(['M17.11']), 'ICD-LAT-01'), isEmpty);
    });

    test('ICD-LAT-02: unspecified side from the MCE edit 20 list', () {
      expect(_rule(_check(['M25.569']), 'ICD-LAT-02').single.severity, IssueSeverity.warning);
      expect(_check(['M25.569']).where((i) => i.ruleId == 'ICD-UNSPEC-01'), isEmpty, reason: 'one message per code');
    });

    test('ICD-COMBO-01: the Index "with" combination, in the scrubber and the coder', () {
      expect(_rule(_check(['E11.9', 'G62.9']), 'ICD-COMBO-01').single.detail, contains('E11.42'));
      final found = {
        'E11.9': const ClaimDiagnosis(code: 'E11.9', description: 'DM2', source: DxSource.physicianConfirmed),
        'G62.9': const ClaimDiagnosis(code: 'G62.9', description: 'PN', source: DxSource.physicianConfirmed),
      };
      ClinicalCoder.combineFromIndex(found, DateTime(2026, 10, 15));
      expect(found.keys, ['E11.42'], reason: 'E11.42 has no use-additional note naming G62.9, so G62.9 is dropped');
    });

    test('ICD-ACUTECHRONIC-01: acute first; an acute and chronic code replaces both', () {
      expect(_rule(_check(['J42', 'J20.9']), 'ICD-ACUTECHRONIC-01').single.title, 'List the acute code first: J20.9');
      expect(_rule(_check(['J20.9', 'J42']), 'ICD-ACUTECHRONIC-01'), isEmpty);
      final combo = _rule(_check(['J96.00', 'J96.10']), 'ICD-COMBO-01');
      expect(combo.single.title, 'Acute and chronic combination code: J96.20');
    });

    test('ICD-SYMPTOM-01: an Excludes1 note of a confirmed chronic diagnosis folds its symptom', () {
      final r = _code('Patient: I have been wheezing a lot.\nDoctor: Your asthma is acting up; keep using the albuterol inhaler.');
      final wheeze = r.diagnoses.where((d) => d.code == 'R06.2').single;
      expect(wheeze.status, DxStatus.integral);
    });
  });

  group('Injuries (CH19-INJ-01)', () {
    test('aftercare Z code with an injury', () {
      expect(_rule(_check(['S83.241A', 'Z48.02']), 'CH19-INJ-01').single.title, 'Aftercare code with an injury: Z48.02');
    });

    test('an injury coded A on an earlier visit is flagged on the follow-up, and the coder picks D', () {
      final first = _visit(number: 1, dos: '2026-10-01', claim: _claim(['S83.241A'], [_line('99214')]));
      final followUp = _visit(number: 2, dos: '2026-10-15');
      expect(_rule(_check(['S83.241A'], history: [first], visit: followUp), 'CH19-INJ-01').single.detail, contains('S83.241D'));
      expect(_rule(_check(['S83.241A'], visit: followUp), 'CH19-INJ-01'), isEmpty);
      const text = 'Doctor: Your right knee medial meniscus tear is healing well. Keep up the exercises.';
      expect(_code(text).billable.map((d) => d.code), contains('S83.241A'));
      expect(_code(text, prior: {'S83.241A'}).billable.map((d) => d.code), contains('S83.241D'));
    });
  });

  group('NCCI services', () {
    test('NCCI-EM-02: E/M with a 090 procedure needs 57', () {
      expect(_rule(_check(['M17.11'], lines: [_line('99214'), _line('27447')]), 'NCCI-EM-02'), hasLength(1));
      expect(_rule(_check(['M17.11'], lines: [_line('99214', modifiers: ['57']), _line('27447')]), 'NCCI-EM-02'), isEmpty);
    });

    test('NCCI-EM-03: E/M with an XXX procedure with physician work needs 25; diagnostic tests do not', () {
      expect(_rule(_check(['I10'], lines: [_line('99214'), _line('96372')]), 'NCCI-EM-03'), hasLength(1));
      expect(_rule(_check(['I10'], lines: [_line('99214', modifiers: ['25']), _line('96372')]), 'NCCI-EM-03'), isEmpty);
      expect(_rule(_check(['I10'], lines: [_line('99214'), _line('93000')]), 'NCCI-EM-03'), isEmpty);
    });

    test('NCCI-GLOBAL-01: E/M inside the global period of an earlier procedure needs 24', () {
      final surgery = _visit(number: 1, dos: '2026-10-05', claim: _claim(['M17.11'], [_line('27447')]));
      final later = _visit(number: 2, dos: '2026-10-15');
      expect(_rule(_check(['I10'], history: [surgery], visit: later), 'NCCI-GLOBAL-01').single.detail, contains('10 days after 27447'));
      expect(_rule(_check(['I10'], lines: [_line('99214', modifiers: ['24'])], history: [surgery], visit: later), 'NCCI-GLOBAL-01'), isEmpty);
      final muchLater = _visit(number: 2, dos: '2027-02-01');
      expect(_rule(_check(['I10'], history: [surgery], visit: muchLater), 'NCCI-GLOBAL-01'), isEmpty);
      final minor = _visit(number: 1, dos: '2026-10-01', claim: _claim(['L82.1'], [_line('17000')]));
      expect(_rule(_check(['I10'], history: [minor], visit: later), 'NCCI-GLOBAL-01'), isEmpty, reason: '14 days is past a 10 day global');
    });

    test('NCCI-MOD-02: 59 and X modifiers', () {
      expect(_rule(_check(['I10'], lines: [_line('99214', modifiers: ['59'])]), 'NCCI-MOD-02').single.severity, IssueSeverity.error);
      expect(_rule(_check(['M17.11'], lines: [_line('20610', modifiers: ['59'])]), 'NCCI-MOD-02').single.severity, IssueSeverity.warning);
      expect(_rule(_check(['M17.11'], lines: [_line('20610', modifiers: ['XS'])]), 'NCCI-MOD-02'), isEmpty);
    });

    test('NCCI-MUE-03: modifier 50 and units follow the bilateral indicator', () {
      expect(_rule(_check(['H61.23'], lines: [_line('69210', modifiers: ['50'])]), 'NCCI-MUE-03').single.title, 'Modifier 50 not allowed: 69210');
      expect(_rule(_check(['M54.16'], lines: [_line('64483', modifiers: ['50'], units: 2)]), 'NCCI-MUE-03').single.title,
          'Bilateral procedure with more than one unit: 64483');
      expect(
          _rule(_check(['M54.16'], lines: [_line('64483', modifiers: ['RT']), _line('64483', modifiers: ['LT'])]), 'NCCI-MUE-03').single.title,
          'Bilateral procedure on two lines: 64483');
      expect(_rule(_check(['M54.16'], lines: [_line('64483', modifiers: ['50'])]), 'NCCI-MUE-03'), isEmpty);
    });

    test('NCCI-LAB-01: a repeated lab test needs 91', () {
      expect(_rule(_check(['E11.9'], lines: [_line('80053'), _line('80053')]), 'NCCI-LAB-01'), hasLength(1));
      expect(_rule(_check(['E11.9'], lines: [_line('80053'), _line('80053', modifiers: ['91'])]), 'NCCI-LAB-01'), isEmpty);
    });

    test('OP-DIAGSERVICES-01: a diagnostic test with a symptom first is a reminder', () {
      expect(_rule(_check(['R07.9'], lines: [_line('99214', modifiers: ['25']), _line('93000')]), 'OP-DIAGSERVICES-01').single.severity,
          IssueSeverity.info);
    });

    test('MCE-UNACC-01 is an error on hospital inpatient visits', () {
      ReferenceData.inject(mceLists: Mce.parse('unacceptable_principal\t\t\tZ87.891\n'));
      final issues = _check(['Z87.891', 'I10'], lines: [_line('99223')], visit: _visit(pos: '21'));
      expect(_rule(issues, 'MCE-UNACC-01').single.severity, IssueSeverity.error);
    });
  });

  group('Explainability', () {
    test('every issue carries a rule id and the citation from the knowledge base', () {
      final issues = [
        ..._check(['I50.9', 'I11.0', 'N39.0', 'M25.569', 'R07.9'], lines: [_line('99214', modifiers: ['59']), _line('96372')]),
        ...ClaimScrubber.check(
          claim: _claim([], []),
          account: PatientAccount(accountNumber: 'x', firstName: 'A', lastName: 'B', createdAtUtc: DateTime(2026)),
          visit: _visit(),
          provider: _provider,
          noteSigned: false,
        ),
      ];
      expect(issues, isNotEmpty);
      for (final i in issues) {
        expect(i.ruleId, isNotNull, reason: i.title);
        expect(i.citation, ruleCitations[i.ruleId], reason: i.title);
        expect(i.citation, isNotEmpty, reason: i.title);
      }
    });

    test('generated citations cover every rule of knowledge/rules/rule_catalog.json', () {
      final catalog = jsonDecode(File('knowledge/rules/rule_catalog.json').readAsStringSync()) as Map<String, dynamic>;
      for (final r in catalog['rules'] as List) {
        expect(ruleCitations.containsKey(r['id']), isTrue, reason: r['id'] as String);
      }
    });

    test('the bundled rule catalog, guideline text and notes load and explain IV.H', () async {
      CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes'));
      addTearDown(() => CodeSetLoader.useSource(const AssetCodeSetSource()));
      final kb = (await KnowledgeBase.load())!;
      expect(kb.ruleCount, greaterThanOrEqualTo(63));
      expect(kb.rule('OP-UNCERTAIN-01')!.guidelineRefs, contains('IV.H'));
      expect(kb.excerpt('IV.H').first.text, contains('probable'));
      expect(kb.excerpt('I.C.4.a.3').single.text, contains('Z79.4'));
      final notes = (await IcdNotes.load())!;
      expect(notes.of('E11.9', NoteKind.useAdditional).any((n) => n.names('Z79.4')), isTrue);
      expect(notes.of('I50.9', NoteKind.codeFirst).any((n) => n.names('I11.0')), isTrue);
      final mce = (await Mce.load())!;
      expect(mce.unspecifiedLateralityCount, greaterThan(3000));
      final fees = (await FeeSchedule.load());
      expect(fees.lookup('27447')!.bilateral, '1');
      expect(fees.lookup('99214')!.workRvu, greaterThan(1));
    });
  });
}
