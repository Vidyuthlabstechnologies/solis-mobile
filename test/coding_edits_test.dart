// Claim edits driven by the FY2027 coding knowledge base: MCE v44 age and
// sequencing lists, Excludes1, 7th characters, NCCI add-on codes, modifier 25
// with minor procedures, date-of-service MUEs and the hypertension
// combination codes. Uses small injected fixtures; the last group loads the
// real bundled assets.

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/coding/code_rules.dart';
import 'support/test_provider.dart';

final _provider = testProvider();

Visit _visit({String pos = '11'}) => Visit(number: 1, dateOfService: '2026-10-15', placeOfService: pos, createdAtUtc: DateTime(2026));

PatientAccount _patient({int age = 46, PatientSex sex = PatientSex.male}) => PatientAccount(
      accountNumber: 'SOL-10000017',
      firstName: 'Pat',
      lastName: 'Lee',
      sex: sex,
      dateOfBirth: DateTime(2026 - age, 5, 1),
      createdAtUtc: DateTime(2026),
      insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: 'W1'),
      visits: [_visit()],
    );

ClaimDraft _claim(List<String> dx, List<ServiceLine> lines, {Map<String, String> notes = const {}}) {
  final diagnoses = [for (final d in dx) ClaimDiagnosis(code: d, description: d, source: DxSource.manual, note: notes[d])];
  return ClaimDraft(
    diagnoses: diagnoses,
    lines: [for (final l in lines) l.copyWith(diagnosisCodes: dx.take(4).toList())],
    generatedAtUtc: DateTime(2026),
  );
}

ServiceLine _line(String code, {List<String> modifiers = const [], int units = 1}) =>
    ServiceLine(code: code, description: code, modifiers: modifiers, units: units, charge: 100);

List<ClaimIssue> _check(List<String> dx, {List<ServiceLine>? lines, int age = 46, String pos = '11', Map<String, String> notes = const {}}) =>
    ClaimScrubber.check(
      claim: _claim(dx, lines ?? [_line(pos == '21' ? '99223' : '99214')], notes: notes),
      account: _patient(age: age),
      visit: _visit(pos: pos),
      provider: _provider,
      noteSigned: true,
    );

List<String> _titles(List<ClaimIssue> issues, IssueSeverity severity) => issues.where((i) => i.severity == severity).map((i) => i.title).toList();

const _mceFixture = 'age_newborn\t0\t0\tZ38.00,Z00.110\n'
    'age_pediatric\t0\t17\tZ00.121\n'
    'age_maternity\t9\t64\tO80,Z34.00\n'
    'age_adult\t15\t124\tZ00.00,Z00.01\n'
    'manifestation_not_principal\t\t\tG63\n'
    'unacceptable_principal\t\t\tZ87.891,Z51.89,Z00.00\n'
    'unacceptable_principal_requires_secondary\t\t\tZ51.89\n';

CodingResult _code(String text) => ClinicalCoder.code(
      turns: ClinicalCoder.diarize(text),
      vitals: const [],
      context: const CodingContext(age: 70, sex: PatientSex.male),
    );

void main() {
  tearDown(ReferenceData.clear);

  group('Age edits (MCE v44)', () {
    test('perinatal P codes are not limited to age 0 (guideline I.C.16.a.4)', () {
      expect(icdAgeRange('P07.30'), isNull);
      expect(isPerinatalCode('P27.1'), isTrue);
      final issues = _check(['P27.1']);
      expect(_titles(issues, IssueSeverity.error), isNot(contains('Age conflict: P27.1')));
      expect(_titles(issues, IssueSeverity.warning), contains('Perinatal code after the newborn period: P27.1'));
    });

    test('adult exam Z00.0- starts at age 15, without and with the MCE lists', () {
      expect(icdAgeRange('Z00.00')!.contains(15), isTrue);
      expect(icdAgeRange('Z00.00')!.contains(14), isFalse);
      ReferenceData.inject(mceLists: Mce.parse(_mceFixture));
      expect(icdAgeRange('Z00.00')!.contains(15), isTrue);
      expect(icdAgeRange('Z00.00')!.label, 'adult (age 15 to 124)');
      expect(_titles(_check(['Z00.00'], age: 16), IssueSeverity.error), isNot(contains('Age conflict: Z00.00')));
    });

    test('MCE lists drive newborn, pediatric and maternity ranges', () {
      ReferenceData.inject(mceLists: Mce.parse(_mceFixture));
      expect(icdAgeRange('Z38.00')!.contains(0), isTrue);
      expect(icdAgeRange('Z00.121')!.contains(18), isFalse);
      expect(icdAgeRange('Z34.00')!.contains(70), isFalse, reason: 'non-O maternity codes are on the MCE list too');
      expect(icdAgeRange('P07.30'), isNull);
      expect(_titles(_check(['Z38.00'], age: 5), IssueSeverity.error), contains('Age conflict: Z38.00'));
    });
  });

  group('MUE date-of-service totals (NCCI-MUE-02)', () {
    setUp(() => ReferenceData.inject(mueTable: Mue.parse('97110\t4\t3\n20610\t2\t1\n')));

    test('MAI 3 sums units across lines of the same code', () {
      final issues = _check(['M54.50'], lines: [_line('97110', units: 3), _line('97110', units: 2)]);
      final mue = issues.where((i) => i.title == 'Too many units: 97110').toList();
      expect(mue, hasLength(1));
      expect(mue.single.detail, contains('5 across 2 lines'));
    });

    test('MAI 1 stays a per-line edit', () {
      final issues = _check(['M17.11'], lines: [_line('20610'), _line('20610', modifiers: ['59'])]);
      expect(_titles(issues, IssueSeverity.error), isNot(contains('Too many units: 20610')));
      expect(_titles(_check(['M17.11'], lines: [_line('20610', units: 3)]), IssueSeverity.error), contains('Too many units: 20610'));
    });
  });

  group('Hypertension combination codes (CH9-HTN-01/02/03)', () {
    test('hypertension with heart failure is I11.0 plus I50.9, not I10', () {
      final r = _code('Doctor: You have hypertension. You also have heart failure. We will continue the lisinopril.');
      final codes = r.billable.map((d) => d.code).toList();
      expect(codes, containsAll(['I11.0', 'I50.9']));
      expect(codes, isNot(contains('I10')));
      expect(codes.indexOf('I11.0'), lessThan(codes.indexOf('I50.9')));
    });

    test('with CKD stage 4 it is I13.0; with ESRD and no heart failure it is I12.0', () {
      final both = _code('Doctor: You have hypertension. You have heart failure. You have chronic kidney disease stage 4.').billable.map((d) => d.code);
      expect(both, containsAll(['I13.0', 'I50.9', 'N18.4']));
      expect(both, isNot(contains('N18.9')));
      final kidney = _code('Doctor: You have hypertension and end stage renal disease.').billable.map((d) => d.code);
      expect(kidney, containsAll(['I12.0', 'N18.6']));
      expect(kidney, isNot(contains('I10')));
    });

    test('the scrubber flags hand-entered I10 with heart failure or CKD, and CKD stages with ESRD (CH14-CKD-01)', () {
      final hf = _check(['I10', 'I50.9']).where((i) => i.title == 'Hypertension needs its combination code: I10').toList();
      expect(hf, hasLength(1));
      expect(hf.single.detail, contains('I11.0'));
      expect(_check(['I10', 'N18.4']).firstWhere((i) => i.code == 'I10').detail, contains('I12.9'));
      expect(_check(['I10', 'I50.9', 'N18.6']).firstWhere((i) => i.code == 'I10').detail, contains('I13.2'));
      expect(_titles(_check(['I12.9', 'N18.4', 'N18.6']), IssueSeverity.warning), contains('ESRD replaces the CKD stage: N18.4'));
      expect(_check(['I11.0', 'I50.9']).where((i) => i.title.contains('combination')), isEmpty);
      expect(ClinicalCoder.code(
        turns: ClinicalCoder.diarize('Doctor: You have chronic kidney disease stage 4 and now end stage renal disease.'),
        vitals: const [],
        context: const CodingContext(),
      ).billable.map((d) => d.code), ['N18.6']);
    });

    test('documentation that the conditions are unrelated keeps I10', () {
      final r = _code('Doctor: You have hypertension. You also have heart failure. The heart failure is not related to your hypertension.');
      final codes = r.billable.map((d) => d.code);
      expect(codes, containsAll(['I10', 'I50.9']));
      expect(codes, isNot(contains('I11.0')));
    });
  });

  group('First-listed diagnosis rules', () {
    test('external cause codes are never first (ICD-EXTCAUSE-01)', () {
      expect(_titles(_check(['W19.XXXA', 'S72.001A']), IssueSeverity.error), contains('External cause listed first: W19.XXXA'));
      expect(_titles(_check(['S72.001A', 'W19.XXXA']), IssueSeverity.error), isNot(contains('External cause listed first: W19.XXXA')));
    });

    test('secondary-only codes are never first (ICD-SECONDARY-ONLY-01)', () {
      for (final code in ['Z68.41', 'R40.2412', 'R29.715', 'Z59.00', 'Z28.310']) {
        expect(_titles(_check([code, 'E66.01']), IssueSeverity.error), contains('Secondary-only code listed first: $code'), reason: code);
      }
    });

    test('severe sepsis R65.2- is never first and follows its infection (CH1-SEPSIS-01)', () {
      expect(_titles(_check(['R65.20', 'A41.9']), IssueSeverity.error), contains('Severe sepsis listed first: R65.20'));
      expect(_check(['A41.9', 'R65.20']).where((i) => i.title.contains('sepsis')), isEmpty);
      expect(_titles(_check(['J18.9', 'R65.20']), IssueSeverity.warning), contains('Severe sepsis without its infection first: R65.20'));
    });

    test('manifestation codes are never first, only when the MCE list is loaded (ICD-MANIF-01)', () {
      expect(_titles(_check(['G63', 'E11.40']), IssueSeverity.error), isNot(contains('Manifestation code listed first: G63')));
      ReferenceData.inject(mceLists: Mce.parse(_mceFixture));
      expect(_titles(_check(['G63', 'E11.40']), IssueSeverity.error), contains('Manifestation code listed first: G63'));
      expect(_titles(_check(['E11.40', 'G63']), IssueSeverity.error), isNot(contains('Manifestation code listed first: G63')));
    });

    test('first-listed-only Z codes must be first (CH21-Z-01)', () {
      expect(_titles(_check(['I10', 'Z00.00']), IssueSeverity.error), contains('Must be listed first: Z00.00'));
      expect(_titles(_check(['Z00.01', 'I10']), IssueSeverity.error), isNot(contains('Must be listed first: Z00.01')));
      expect(isFirstListedOnly('Z00.6'), isFalse, reason: 'Z00.6 is the official exception');
      expect(isFirstListedOnly('Z51.11'), isTrue);
      expect(isFirstListedOnly('Z52.9'), isFalse);
    });

    test('the coder ranks first-listed-only Z codes first and secondary-only codes last', () {
      final ordered = ClinicalCoder.finalizeDiagnoses([
        const ClaimDiagnosis(code: 'Z68.41', description: 'BMI', source: DxSource.manual),
        const ClaimDiagnosis(code: 'E66.01', description: 'Obesity', source: DxSource.manual),
        const ClaimDiagnosis(code: 'Z00.01', description: 'Exam', source: DxSource.manual),
      ]).map((d) => d.code);
      expect(ordered, ['Z00.01', 'E66.01', 'Z68.41']);
    });

    test('MCE unacceptable principal applies to inpatient visits only (MCE-UNACC-01)', () {
      ReferenceData.inject(mceLists: Mce.parse(_mceFixture));
      expect(_titles(_check(['Z87.891', 'I10'], pos: '21'), IssueSeverity.error), contains('Not accepted as principal diagnosis: Z87.891'));
      expect(_titles(_check(['Z87.891', 'I10']), IssueSeverity.error), isNot(contains('Not accepted as principal diagnosis: Z87.891')));
      expect(_titles(_check(['Z51.89', 'I10'], pos: '21'), IssueSeverity.error), isNot(contains('Not accepted as principal diagnosis: Z51.89')),
          reason: 'acceptable when a secondary diagnosis is present');
      expect(_titles(_check(['Z00.00'], pos: '21'), IssueSeverity.error), isNot(contains('Not accepted as principal diagnosis: Z00.00')),
          reason: 'guideline I.C.21.c.15 lets Z00 be first-listed');
    });
  });

  group('Excludes1 (ICD-EXCL1-01)', () {
    setUp(() => ReferenceData.inject(excludes1Notes: Excludes1.parse('E11\tE10.-\nI10-I1A\tI27.0\nA04.0-A04.4\tA05.-\nG43\tG44.00\n')));

    test('a note at the category applies to every code below it', () {
      expect(_titles(_check(['E11.9', 'E10.9']), IssueSeverity.error), ['Excludes1 conflict: E11.9 and E10.9']);
    });

    test('block ranges and excluded ranges match', () {
      expect(_titles(_check(['I10', 'I27.0']), IssueSeverity.error), contains('Excludes1 conflict: I10 and I27.0'));
      expect(_titles(_check(['A05.1', 'A04.2']), IssueSeverity.error), contains('Excludes1 conflict: A04.2 and A05.1'));
      expect(_titles(_check(['A04.7', 'A05.1']), IssueSeverity.error).where((t) => t.startsWith('Excludes1')), isEmpty);
    });

    test('unrelated codes pass; a pair documented as unrelated is a warning', () {
      expect(_titles(_check(['E11.9', 'I10']), IssueSeverity.error).where((t) => t.startsWith('Excludes1')), isEmpty);
      final issues = _check(['G43.909', 'G44.00'], notes: {'G44.00': 'Unrelated to the migraine'});
      expect(_titles(issues, IssueSeverity.error).where((t) => t.startsWith('Excludes1')), isEmpty);
      expect(_titles(issues, IssueSeverity.warning), contains('Excludes1 pair documented as unrelated: G43.909 and G44.00'));
    });

    test('no notes loaded means no check', () {
      ReferenceData.clear();
      expect(ClaimScrubber.excludes1Issues([
        const ClaimDiagnosis(code: 'E11.9', description: '', source: DxSource.manual),
        const ClaimDiagnosis(code: 'E10.9', description: '', source: DxSource.manual),
      ]), isEmpty);
    });
  });

  group('7th character and placeholder X (ICD-7TH-01, ICD-PLACEHOLDER-01)', () {
    setUp(() => ReferenceData.inject(
          icd: {
            2027: IcdCatalog.parse(
              'S83.241\t0\tOther tear of medial meniscus, current injury, right knee\n'
              'S83.241A\t1\tOther tear of medial meniscus, current injury, right knee, initial encounter\n'
              'S83.241D\t1\tOther tear of medial meniscus, current injury, right knee, subsequent encounter\n'
              'S83.241S\t1\tOther tear of medial meniscus, current injury, right knee, sequela\n'
              'T74.4\t0\tShaken infant syndrome\n'
              'T74.4XXA\t1\tShaken infant syndrome, initial encounter\n'
              'T74.4XXD\t1\tShaken infant syndrome, subsequent encounter\n',
              fiscalYear: 2027,
            ),
          },
          seventhCharacters: SeventhCharacters.parse('S83\tA=initial encounter|D=subsequent encounter|S=sequela\n'
              'T74\tA=initial encounter|D=subsequent encounter|S=sequela\n'),
        ));

    ClaimIssue issueFor(String code) => _check([code]).firstWhere((i) => i.code == code && i.severity == IssueSeverity.error);

    test('missing 7th character lists the allowed values and an example', () {
      final i = issueFor('S83.241');
      expect(i.title, 'Missing 7th character: S83.241');
      expect(i.detail, contains('A initial encounter, D subsequent encounter, S sequela'));
      expect(i.detail, contains('S83.241A'));
    });

    test('short codes are padded with placeholder X', () {
      final i = issueFor('T74.4');
      expect(i.title, 'Missing 7th character: T74.4');
      expect(i.detail, contains('T74.4XXA'));
      expect(withSeventhCharacter('T74.4', 'a'), 'T74.4XXA');
    });

    test('a 7th character without the placeholder suggests the padded code', () {
      final i = issueFor('T74.4A');
      expect(i.title, 'Missing placeholder X: T74.4A');
      expect(i.detail, contains('T74.4XXA'));
    });

    test('a 7th character that is not defined is an error', () {
      expect(issueFor('S83.241Z').title, 'Invalid 7th character: S83.241Z');
    });

    test('without the 7th character table the generic message stays', () {
      ReferenceData.seventh = null;
      expect(issueFor('S83.241').title, 'Code needs more characters: S83.241');
    });
  });

  group('Add-on codes (NCCI-ADDON-01)', () {
    setUp(() => ReferenceData.inject(addOnCodes: AddOnCodes.parse('99417\t1\t99205,99215\n0054T\t2\t\n11045\t3\t11042\n')));

    test('type 1 add-on without its primary is an error', () {
      expect(_titles(_check(['I10'], lines: [_line('99214'), _line('99417')]), IssueSeverity.error), contains('Add-on code without its primary: 99417'));
      expect(_titles(_check(['I10'], lines: [_line('99215'), _line('99417')]), IssueSeverity.error), isNot(contains('Add-on code without its primary: 99417')));
    });

    test('type 3 is a warning and type 2 (contractor-defined) is not checked', () {
      final issues = _check(['L97.912'], lines: [_line('11045'), _line('0054T')]);
      expect(_titles(issues, IssueSeverity.warning), contains('Add-on code without its primary: 11045'));
      expect(issues.where((i) => i.title.contains('0054T')), isEmpty);
    });
  });

  group('E/M with a minor procedure (NCCI-EM-01)', () {
    setUp(() => ReferenceData.inject(feeSchedule: FeeSchedule.parse('20610\tA\t2.1\t1.5\t000\n99214\tA\t3.8\t2.8\tXXX\n27447\tA\t30\t30\t090\n')));

    test('E/M on the day of a 000/010 procedure needs modifier 25', () {
      expect(_titles(_check(['M17.11'], lines: [_line('99214'), _line('20610')]), IssueSeverity.error), contains('E/M needs modifier 25: 99214'));
      expect(_titles(_check(['M17.11'], lines: [_line('99214', modifiers: ['25']), _line('20610')]), IssueSeverity.error),
          isNot(contains('E/M needs modifier 25: 99214')));
    });

    test('E/M alone or with a major procedure is not flagged by this edit', () {
      expect(_titles(_check(['M17.11'], lines: [_line('99214')]), IssueSeverity.error), isNot(contains('E/M needs modifier 25: 99214')));
      expect(_titles(_check(['M17.11'], lines: [_line('99214'), _line('27447')]), IssueSeverity.error), isNot(contains('E/M needs modifier 25: 99214')));
    });
  });

  group('Real bundled coding-edit assets', () {
    setUpAll(() => CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes')));

    test('MCE v44, Excludes1, 7th characters and add-on codes load', () async {
      final mce = (await Mce.load())!;
      expect(mce.ageCodeCount, 3612);
      expect(mce.ageFor('Z00.00')!.min, 15);
      expect(mce.ageFor('P07.30'), isNull);
      expect(mce.isManifestation('G63'), isTrue);
      expect(mce.isUnacceptablePrincipal('R65.20'), isTrue);

      final ex = (await Excludes1.load())!;
      expect(ex.length, greaterThan(5000));
      expect(ex.conflicts(['E11.9', 'E10.9']), isNotEmpty);
      expect(ex.conflicts(['E11.9', 'I10']), isEmpty);

      final seventh = (await SeventhCharacters.load())!;
      expect(seventh.ruleFor('S83.241')!.allows('A'), isTrue);
      expect(seventh.ruleFor('I10'), isNull);

      final aoc = (await AddOnCodes.load())!;
      expect(aoc.lookup('99417')!.type, 1);
      expect(aoc.lookup('99417')!.primaries, contains('99215'));
      expect(aoc.lookup('0054T')!.type, 2);
      expect(aoc.lookup('99214'), isNull);
    });
  });
}
