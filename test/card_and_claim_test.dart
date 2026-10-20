import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/card_parser.dart';
import 'package:solis_mobile/services/coding/claim_builder.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'support/test_provider.dart';

void main() {
  group('Insurance card', () {
    test('reads payer, member ID, group, Rx and copays from OCR text', () {
      const ocr = 'aetna\nOpen Access Aetna Select PPO\nMember\nJANE Q DOE\nMember ID W281947365\nGroup # 285214-010\n'
          'RxBIN 610502\nRxPCN MEDDAET\nRxGRP RX8826\nPCP \$25 Specialist \$50 ER \$250\nPayer ID 60054';
      final id = CardParser.parseInsuranceCard(ocr);
      expect(id.payerName, 'Aetna');
      expect(id.memberId, 'W281947365');
      expect(id.groupNumber, '285214-010');
      expect(id.rxBin, '610502');
      expect(id.rxPcn, 'MEDDAET');
      expect(id.payerId, '60054');
      expect(id.copays['PCP'], '\$25');
      expect(id.copays['ER'], '\$250');
      expect(id.firstName, 'Jane');
      expect(id.lastName, 'Doe');
      expect(id.planType, 'PPO');
    });

    test('recognizes a Medicare Beneficiary Identifier', () {
      const ocr = 'MEDICARE HEALTH INSURANCE\nName/Nombre\nROBERT HAYES\nMedicare Number/Numero de Medicare\n1EG4-TE5-MK73\nPART B MEDICAL';
      final id = CardParser.parseInsuranceCard(ocr);
      expect(id.payerName, 'Medicare');
      expect(id.memberId, '1EG4TE5MK73');
    });
  });

  group("Driver's license", () {
    test('parses the AAMVA PDF417 barcode', () {
      const raw = '@\n\x1e\rANSI 636014090002DL00410278ZC03190024DLDAQD1234562\nDCSHAYES\nDACROBERT\nDADJAMES\nDBD01152020\n'
          'DBB01301968\nDBA01302028\nDBC1\nDAU072 IN\nDAG123 MAIN ST\nDAISAN FRANCISCO\nDAJCA\nDAK941580000  \nDCF00/00/0000NNNAN/ANFD/YY\n';
      final id = CardParser.parseAamva(raw)!;
      expect(id.firstName, 'Robert');
      expect(id.lastName, 'Hayes');
      expect(id.middleName, 'James');
      expect(id.dateOfBirth, DateTime(1968, 1, 30));
      expect(id.sex, PatientSex.male);
      expect(id.licenseNumber, 'D1234562');
      expect(id.state, 'CA');
      expect(id.zip, '94158');
      expect(id.addressLine1, '123 Main St');
    });
  });

  group('Social Security card', () {
    test('keeps only the last four digits', () {
      final id = CardParser.parseSsnCard('SOCIAL SECURITY\nTHIS NUMBER HAS BEEN ESTABLISHED FOR\n123-45-6789\nMARGARET A VANCE\nSIGNATURE');
      expect(id.ssnLast4, '6789');
      expect(id.firstName, 'Margaret');
      expect(id.lastName, 'Vance');
    });
  });

  group('Accounts and visits', () {
    test('account numbers carry a check digit and visits are numbered per account', () async {
      final repo = AccountRepository.memory();
      final a = await repo.createAccount(firstName: 'Jane', lastName: 'Doe', dateOfBirth: DateTime(1980, 1, 1));
      expect(AccountRepository.isValidAccountNumber(a.accountNumber), isTrue);
      expect(AccountRepository.isValidAccountNumber(a.accountNumber.replaceFirst(RegExp(r'\d$'), 'X')), isFalse);

      final v1 = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: '11');
      final v2 = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 11, 2), placeOfService: '11');
      expect(v1.number, 1);
      expect(v2.number, 2);
      expect(repo.byNumber(a.accountNumber)!.visits.map((v) => v.dateOfService), ['2026-10-15', '2026-11-02']);
    });

    test('finds an existing patient by member ID or name and date of birth', () async {
      final repo = AccountRepository.memory();
      await repo.createAccount(
        firstName: 'Jane',
        lastName: 'Doe',
        dateOfBirth: DateTime(1980, 1, 1),
        insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: 'W1234567'),
      );
      expect(repo.findMatches(memberId: 'w1234567'), hasLength(1));
      expect(repo.findMatches(firstName: 'jane', lastName: 'DOE', dateOfBirth: DateTime(1980, 1, 1)), hasLength(1));
      expect(repo.findMatches(firstName: 'Jane', lastName: 'Doe', dateOfBirth: DateTime(1990, 1, 1)), isEmpty);
    });
  });

  group('Claim scrubber', () {
    final provider = testProvider();
    final visit = Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '11', createdAtUtc: DateTime(2026));
    PatientAccount patient(PatientSex sex, {int birthYear = 1980}) => PatientAccount(
          accountNumber: 'SOL-10000017',
          firstName: 'Pat',
          lastName: 'Lee',
          sex: sex,
          dateOfBirth: DateTime(birthYear, 5, 1),
          createdAtUtc: DateTime(2026),
          insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: 'W1'),
          visits: [visit],
        );
    ClaimDraft claim(List<String> dx, List<String> cpt) {
      final diagnoses = [for (final d in dx) ClaimDiagnosis(code: d, description: d, source: DxSource.manual)];
      return ClaimDraft(
        diagnoses: diagnoses,
        lines: ClinicalCoder.assignPointers([for (final c in cpt) ServiceLine(code: c, description: c, charge: 100)], diagnoses),
        generatedAtUtc: DateTime(2026),
      );
    }

    List<String> errors(ClaimDraft c, PatientAccount a, {Visit? v}) => ClaimScrubber.check(
          claim: c,
          account: a,
          visit: v ?? visit,
          provider: provider,
          noteSigned: true,
        ).where((i) => i.severity == IssueSeverity.error).map((i) => i.title).toList();

    test('a clean office claim passes', () {
      expect(errors(claim(['G43.109'], ['99214']), patient(PatientSex.male)), isEmpty);
    });

    test('headache with a stomach procedure is a coding conflict', () {
      expect(errors(claim(['R51.9'], ['99214', '43235']), patient(PatientSex.male)), contains('No supporting diagnosis: 43235'));
    });

    test('prostate procedure on a female patient is a sex conflict', () {
      expect(errors(claim(['R39.9'], ['55700']), patient(PatientSex.female)), contains('Sex conflict: 55700'));
      expect(errors(claim(['O80'], ['99214']), patient(PatientSex.male)), contains('Sex conflict: O80'));
    });

    test('preventive code outside its age band is an age conflict', () {
      expect(errors(claim(['Z00.00'], ['99385']), patient(PatientSex.male, birthYear: 1970)), contains('Age conflict: 99385'));
    });

    test('an emergency department code at an office is a place-of-service conflict', () {
      expect(errors(claim(['R07.9'], ['99285']), patient(PatientSex.male)), contains('Place of service conflict: 99285'));
      final nursing = Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '32', createdAtUtc: DateTime(2026));
      expect(errors(claim(['R07.9'], ['99214']), patient(PatientSex.male), v: nursing), contains('Place of service conflict: 99214'));
    });

    test('export carries CMS-1500 boxes and 837P loops with diagnosis pointers', () {
      final a = patient(PatientSex.male);
      final c = claim(['I21.19', 'R00.0'], ['99285', '93010']);
      final json = ClaimBuilder.build(account: a, visit: visit, provider: provider, claim: c);
      expect(json['claimId'], 'SOL-10000017-V1');
      expect((json['diagnoses'] as Map)['codes'][0]['code'], 'I21.19');
      expect((json['serviceLines'] as List).first['box24E_diagnosisPointer'], 'AB');
      expect(((json['x12_837P'] as Map)['loop2300_claim'] as Map)['HI'][0], 'ABK:I2119');
      expect((json['provider'] as Map)['box25_federalTaxId'], provider.taxId);
    });
  });
}
