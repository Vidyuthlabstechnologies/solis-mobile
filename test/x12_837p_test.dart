import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';

const _config = SubmitterConfig(
  submitterName: 'Bayview Family Medicine',
  submitterId: '123435',
  submitterContactName: 'Billing Office',
  isaSenderId: '574183004559',
  isaReceiverId: 'STEDITEST',
  usageIndicator: 'T',
  interchangeControlNumber: 39,
  groupControlNumber: 39,
  transactionControlNumber: 1,
);

InsuranceCoverage _aetna({String relationship = 'self', String? subscriberName}) => InsuranceCoverage(
      payerName: 'Aetna',
      payerId: '60054',
      planName: 'Open Access Aetna Select',
      planType: 'PPO',
      memberId: 'W281947365',
      groupNumber: '285214-010',
      relationship: relationship,
      subscriberName: subscriberName,
    );

ClaimDraft _claim() => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 15),
      primaryCode: 'E11.9',
      diagnoses: const [
        ClaimDiagnosis(code: 'I10', description: 'Essential hypertension', source: DxSource.physicianConfirmed),
        ClaimDiagnosis(code: 'E11.9', description: 'Type 2 diabetes', source: DxSource.physicianConfirmed),
        ClaimDiagnosis(code: 'R07.9', description: 'Chest pain', source: DxSource.patientReported, status: DxStatus.uncertain),
        ClaimDiagnosis(code: 'J06.9', description: 'URI', source: DxSource.physicianConfirmed),
      ],
      lines: const [
        ServiceLine(code: '99214', description: 'Office visit', modifiers: ['25'], charge: 210, diagnosisCodes: ['E11.9', 'I10']),
        ServiceLine(code: '93000', description: 'ECG', charge: 45, diagnosisCodes: ['I10']),
        ServiceLine(code: '36415', description: 'Venipuncture', units: 2, charge: 12.5, diagnosisCodes: ['J06.9', 'E11.9']),
      ],
    );

PatientAccount _account({InsuranceCoverage? insurance}) => PatientAccount(
      accountNumber: 'SOL-1000017',
      firstName: 'Jane',
      middleName: 'Q',
      lastName: 'Doe',
      dateOfBirth: DateTime(1958, 3, 4),
      sex: PatientSex.female,
      addressLine1: '12 Oak St',
      city: 'Oakland',
      state: 'CA',
      zip: '94607',
      createdAtUtc: DateTime.utc(2026, 10, 1),
      insurance: insurance ?? _aetna(),
    );

final _visit = Visit(number: 2, dateOfService: '2026-10-15', placeOfService: '11', createdAtUtc: DateTime.utc(2026, 10, 15));

X12BuildResult _build({PatientAccount? account, ProviderProfile? provider, bool pretty = false}) => Claim837PGenerator.build(
      claim: _claim(),
      account: account ?? _account(),
      visit: _visit,
      provider: provider ?? ProviderProfile.demo(),
      config: _config,
      now: DateTime(2026, 10, 16, 9, 5),
      pretty: pretty,
    );

List<String> _els(List<String> segs, String id) => segs.firstWhere((s) => s.startsWith('$id*')).split('*');

void main() {
  group('837P generator', () {
    final result = _build();
    final x12 = result.x12!;
    final segs = X12Formatter.segments(x12);

    test('builds without errors', () {
      expect(result.errors, isEmpty);
      expect(result.ok, isTrue);
      expect(x12, isNot(contains('\n')));
    });

    test('ISA is exactly 106 characters through the segment terminator', () {
      final isa = x12.substring(0, x12.indexOf('~') + 1);
      expect(isa.length, 106);
      expect(isa, startsWith('ISA*00*          *00*          *ZZ*574183004559   *ZZ*STEDITEST      *261016*0905*^*00501*000000039*0*T*:~'));
    });

    test('control numbers match across envelopes', () {
      final isa = segs.first.split('*');
      final iea = _els(segs, 'IEA');
      final gs = _els(segs, 'GS');
      final ge = _els(segs, 'GE');
      final st = _els(segs, 'ST');
      final se = _els(segs, 'SE');
      expect(isa[13], iea[2]);
      expect(gs[6], ge[2]);
      expect(st[2], se[2]);
      expect(st[2], '0001');
      expect(st[3], '005010X222A1');
      expect(gs[8], '005010X222A1');
      expect(ge[1], '1');
      expect(iea[1], '1');
    });

    test('SE01 counts segments from ST to SE inclusive', () {
      final st = segs.indexWhere((s) => s.startsWith('ST*'));
      final se = segs.indexWhere((s) => s.startsWith('SE*'));
      expect(int.parse(_els(segs, 'SE')[1]), se - st + 1);
      expect(result.transactionSegmentCount, se - st + 1);
    });

    test('HI carries ABK principal first, then ABF, without dots, billable only', () {
      final hi = _els(segs, 'HI');
      expect(hi.sublist(1), ['ABK:E119', 'ABF:I10', 'ABF:J069']);
      expect(x12, isNot(contains('R079')));
    });

    test('SV1 pointers follow the diagnosis order in HI', () {
      final sv1 = segs.where((s) => s.startsWith('SV1*')).map((s) => s.split('*')).toList();
      expect(sv1.length, 3);
      expect(sv1[0][1], 'HC:99214:25');
      expect(sv1[0][2], '210');
      expect(sv1[0][3], 'UN');
      expect(sv1[0][4], '1');
      expect(sv1[0][7], '1:2');
      expect(sv1[1][7], '2');
      expect(sv1[2][2], '25');
      expect(sv1[2][4], '2');
      expect(sv1[2][7], '3:1');
      final clm = _els(segs, 'CLM');
      expect(clm[1], 'SOL-1000017-V2');
      expect(clm[2], '280');
      expect(clm[5], '11:B:1');
      expect(clm.sublist(6), ['Y', 'A', 'Y', 'Y']);
      expect(segs.where((s) => s == 'DTP*472*D8*20261015').length, 3);
      expect(segs.where((s) => s.startsWith('LX*')).toList(), ['LX*1', 'LX*2', 'LX*3']);
    });

    test('billing provider, subscriber and payer loops', () {
      expect(segs, contains('HL*1**20*1'));
      expect(segs, contains('PRV*BI*PXC*207Q00000X'));
      expect(segs, contains('NM1*85*1*LIN*SARAH****XX*1982736450'));
      expect(segs, contains('REF*EI*841234567'));
      expect(segs, contains('HL*2*1*22*0'));
      expect(segs, contains('SBR*P*18*285214-010******CI'));
      expect(segs, contains('NM1*IL*1*DOE*JANE*Q***MI*W281947365'));
      expect(segs, contains('DMG*D8*19580304*F'));
      expect(segs, contains('NM1*PR*2*AETNA*****PI*60054'));
      expect(segs, contains('NM1*40*2*AETNA*****46*60054'));
      expect(segs, contains('NM1*41*2*BAYVIEW FAMILY MEDICINE*****46*123435'));
      expect(segs.any((s) => s.startsWith('NM1*82*')), isFalse);
      expect(segs.any((s) => s.startsWith('HL*3*')), isFalse);
    });

    test('pretty output puts one segment per line', () {
      final p = _build(pretty: true).x12!;
      final lines = p.split('\n');
      expect(lines.length, segs.length);
      expect(lines.every((l) => l.endsWith('~')), isTrue);
      expect(lines.first.length, 106);
      expect(result.pretty, p);
    });

    test('Medicare claims get filing indicator MB, Medicaid MC', () {
      final medicare = _build(
        account: _account(
          insurance: const InsuranceCoverage(payerName: 'Medicare Part B', payerId: '01112', planType: 'Medicare', memberId: '1EG4TE5MK73'),
        ),
      );
      expect(medicare.errors, isEmpty);
      expect(_els(X12Formatter.segments(medicare.x12!), 'SBR').last, 'MB');
      expect(claimFilingIndicatorFor(const InsuranceCoverage(payerName: 'Medi-Cal', memberId: 'X')), 'MC');
      expect(claimFilingIndicatorFor(const InsuranceCoverage(payerName: 'Cigna', memberId: 'X')), 'CI');
    });

    test('missing NPI returns an error and no file', () {
      final r = _build(provider: ProviderProfile.demo().copyWith(npi: ''));
      expect(r.ok, isFalse);
      expect(r.x12, isNull);
      expect(r.errors.join(' '), contains('NPI'));
    });

    test('missing payer ID and member ID are reported', () {
      final r = _build(account: _account(insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: '')));
      expect(r.x12, isNull);
      expect(r.errors.any((e) => e.contains('Payer ID')), isTrue);
      expect(r.errors.any((e) => e.contains('Member ID')), isTrue);
    });

    test('group NPI bills as organization with a 2310B rendering provider', () {
      final r = _build(provider: ProviderProfile.demo().copyWith(groupNpi: '1999999984'));
      expect(r.errors, isEmpty);
      final s = X12Formatter.segments(r.x12!);
      expect(s, contains('NM1*85*2*BAYVIEW FAMILY MEDICINE*****XX*1999999984'));
      expect(s, contains('NM1*82*1*LIN*SARAH****XX*1982736450'));
      expect(s, contains('PRV*PE*PXC*207Q00000X'));
      expect(s.indexWhere((x) => x.startsWith('NM1*82*')), greaterThan(s.indexWhere((x) => x.startsWith('HI*'))));
      expect(s.indexWhere((x) => x.startsWith('NM1*82*')), lessThan(s.indexWhere((x) => x.startsWith('LX*'))));
    });

    test('dependent patient gets a 2000C patient loop', () {
      final r = _build(account: _account(insurance: _aetna(relationship: 'child', subscriberName: 'John Doe')));
      expect(r.errors, isEmpty);
      final s = X12Formatter.segments(r.x12!);
      expect(s, contains('HL*2*1*22*1'));
      expect(s, contains('SBR*P**285214-010******CI'));
      expect(s, contains('NM1*IL*1*DOE*JOHN****MI*W281947365'));
      expect(s, contains('HL*3*2*23*0'));
      expect(s, contains('PAT*19'));
      expect(s, contains('NM1*QC*1*DOE*JANE*Q'));
      final st = s.indexWhere((x) => x.startsWith('ST*'));
      final se = s.indexWhere((x) => x.startsWith('SE*'));
      expect(int.parse(s[se].split('*')[1]), se - st + 1);
    });

    test('delimiters in data are stripped', () {
      final r = _build(provider: ProviderProfile.demo().copyWith(addressLine1: '450 Mission*Bay~Blvd:^'));
      expect(r.x12, contains('N3*450 MISSION BAY BLVD~'));
    });
  });
}
