// Medicare front-end edits from CMS CR 14429 (transmittal R13967OTN, HIPAA
// EDI Front End Updates for October 2026) that SOLIS's 837P and 276 could
// violate. See docs/CMS_EDI_OCT2026.md.

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/billing/clearinghouse.dart';
import 'package:solis_mobile/services/billing/cms_edi_edits.dart';
import 'package:solis_mobile/services/billing/stedi_client.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';
import 'package:solis_mobile/services/codesets/hcpcs_catalog.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/rule_citations.g.dart';

import 'support/test_provider.dart';

const _cite = 'CMS CR 14429 (R13977OTN)';

const _hcpcs = 'J3490\tUnclassified drugs\tUnclassified drugs\n'
    'J1885\tKetorolac tromethamine inj\tInjection, ketorolac tromethamine, per 15 mg\n'
    'A9999\tDme supply or accessory, nos\tMiscellaneous DME supply or accessory, not otherwise specified\n';

const _directConfig = SubmitterConfig(
  submitterName: 'Bayview Family Medicine',
  submitterId: '123435',
  isaSenderId: '574183004559',
  isaReceiverId: 'STEDITEST',
  usageIndicator: 'T',
);

InsuranceCoverage _medicare({String memberId = '1EG4-TE5-MK73'}) =>
    InsuranceCoverage(payerName: 'Medicare Part B', payerId: '01112', planType: 'Medicare', memberId: memberId);

InsuranceCoverage _aetna() => const InsuranceCoverage(payerName: 'Aetna', payerId: '60054', memberId: 'W281947365');

PatientAccount _account(InsuranceCoverage ins, {PatientSex sex = PatientSex.female, DateTime? dob}) => PatientAccount(
      accountNumber: 'SOL-1000017',
      firstName: 'Jane',
      lastName: 'Doe',
      dateOfBirth: dob ?? DateTime(1950, 3, 4),
      sex: sex,
      addressLine1: '12 Oak St',
      city: 'Oakland',
      state: 'CA',
      zip: '94607',
      createdAtUtc: DateTime.utc(2026, 10, 1),
      insurance: ins,
    );

ClaimDraft _claim(List<ServiceLine> lines) => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 15),
      diagnoses: const [ClaimDiagnosis(code: 'J06.9', description: 'Acute upper respiratory infection', source: DxSource.physicianConfirmed)],
      lines: lines,
    );

ServiceLine _line(String code, String description) =>
    ServiceLine(code: code, description: description, charge: 40, diagnosisCodes: const ['J06.9']);

final _visit = Visit(number: 2, dateOfService: '2026-09-30', placeOfService: '11', createdAtUtc: DateTime.utc(2026, 10, 15));

X12BuildResult _build(ClaimDraft claim, PatientAccount account, {SubmitterConfig config = _directConfig}) => Claim837PGenerator.build(
      claim: claim,
      account: account,
      visit: _visit,
      provider: testProvider(),
      config: config,
      now: DateTime(2026, 10, 18, 9, 5),
    );

void main() {
  setUp(() => ReferenceData.inject(hcpcsCatalog: HcpcsCatalog.parse(_hcpcs)));
  tearDown(ReferenceData.clear);

  group('which codes need a service description (SV101-7)', () {
    test('unlisted CPT codes and NOC HCPCS codes', () {
      for (final c in ['99499', '64999', '17999', '99429', 'J3490', 'A9999']) {
        expect(CmsEdiEdits.requiresServiceDescription(c), isTrue, reason: c);
      }
      for (final c in ['99213', '93000', 'J1885', '36415']) {
        expect(CmsEdiEdits.requiresServiceDescription(c), isFalse, reason: c);
      }
    });

    test('the narrative is X12-safe and at most 80 characters', () {
      final long = _line('J3490', 'Ceftriaxone* 1 g IM: ${'x' * 120}');
      final s = CmsEdiEdits.serviceDescriptionFor(long)!;
      expect(s.length, lessThanOrEqualTo(80));
      expect(s, isNot(contains('*')));
      expect(s, isNot(contains(':')));
      expect(CmsEdiEdits.serviceDescriptionFor(_line('J1885', 'Ketorolac')), isNull);
    });
  });

  group('claim checks (Medicare Part B only)', () {
    test('a NOC line with no description is an error with the CMS rule id, citation and a fix', () {
      final issues = CmsEdiEdits.claimIssues(claim: _claim([_line('J3490', '')]), account: _account(_medicare()));
      final i = issues.single;
      expect(i.ruleId, 'CMS-EDI-X222.351.2400.SV101-7.020');
      expect(i.citation, _cite);
      expect(i.severity, IssueSeverity.error);
      expect(i.code, 'J3490');
      expect(ruleCitations[i.ruleId], _cite, reason: 'the Why sheet explains it');
    });

    test('a description that only repeats the code wording is a warning; a real one passes', () {
      final generic = CmsEdiEdits.claimIssues(claim: _claim([_line('J3490', 'Unclassified drugs')]), account: _account(_medicare()));
      expect(generic.single.severity, IssueSeverity.warning);
      expect(CmsEdiEdits.claimIssues(claim: _claim([_line('J3490', 'Ceftriaxone 1 g IM')]), account: _account(_medicare())), isEmpty);
    });

    test('other payers and Medicare Advantage are not checked by the MAC edits', () {
      expect(CmsEdiEdits.claimIssues(claim: _claim([_line('J3490', '')]), account: _account(_aetna())), isEmpty);
      final advantage = InsuranceCoverage(payerName: 'Humana Medicare Advantage', payerId: '61101', memberId: 'H1');
      expect(CmsEdiEdits.claimIssues(claim: _claim([_line('J3490', '')]), account: _account(advantage)), isEmpty);
    });

    test('a Medicare member ID that is not an MBI is an error', () {
      expect(CmsEdiEdits.isValidMbi('1EG4-TE5-MK73'), isTrue);
      expect(CmsEdiEdits.isValidMbi('1EG4TE5MK73'), isTrue);
      expect(CmsEdiEdits.isValidMbi('123456789A'), isFalse, reason: 'an old HICN');
      expect(CmsEdiEdits.isValidMbi('1SG4TE5MK73'), isFalse, reason: 'S is never used');
      final i = CmsEdiEdits.claimIssues(claim: _claim([_line('99213', 'Office visit')]), account: _account(_medicare(memberId: '123456789A'))).single;
      expect(i.ruleId, 'CMS-EDI-X222.121.2010BA.NM109.020');
      expect(i.citation, _cite);
    });

    test('ClaimScrubber runs them and offers the line editor', () {
      final provider = testProvider();
      final issues = ClaimScrubber.check(
        claim: _claim([_line('99213', 'Office visit'), _line('J3490', '')]),
        account: _account(_medicare()),
        visit: _visit,
        provider: provider,
        noteSigned: true,
      );
      final i = issues.firstWhere((x) => x.ruleId == CmsEdiEdits.serviceDescription);
      expect(i.fix?.kind, FixKind.editLine);
      expect(i.fix?.code, 'J3490');
    });
  });

  group('837P generator', () {
    test('sends SV101-7 for an unlisted or NOC code', () {
      final r = _build(_claim([_line('99213', 'Office visit'), _line('J3490', 'Ceftriaxone 1 g IM')]), _account(_medicare()));
      expect(r.errors, isEmpty);
      final segs = X12Formatter.segments(r.x12!);
      final sv1 = segs.where((s) => s.startsWith('SV1*')).toList();
      expect(sv1[0].split('*')[1], 'HC:99213', reason: 'no description for a specific code');
      expect(sv1[1].split('*')[1], 'HC:J3490:::::CEFTRIAXONE 1 G IM');
    });

    test('a Medicare claim with a NOC line and no description is not built; other payers get a warning', () {
      final medicare = _build(_claim([_line('J3490', '')]), _account(_medicare()));
      expect(medicare.ok, isFalse);
      expect(medicare.errors.single, contains('CMS-EDI-X222.351.2400.SV101-7.020'));
      final aetna = _build(_claim([_line('J3490', '')]), _account(_aetna()));
      expect(aetna.ok, isTrue);
      expect(aetna.warnings.join(' '), contains('SV101-7'));
    });

    test('1000B NM109 must equal GS03 when a Medicare file goes straight to the MAC', () {
      final claim = _claim([_line('99213', 'Office visit')]);
      // Through a clearinghouse (no receiver ID) 1000B carries the payer ID.
      expect(_build(claim, _account(_medicare())).ok, isTrue);
      // Direct to the MAC with a mismatched receiver: rejected at the translator.
      final mismatch = _build(claim, _account(_medicare()), config: _directConfig.copyWith(receiverName: 'NORIDIAN', receiverId: '01112'));
      expect(mismatch.ok, isFalse);
      expect(mismatch.errors.single, contains('CMS-EDI-X222.079.1000B.NM109.060'));
      final matched = _build(claim, _account(_medicare()),
          config: _directConfig.copyWith(receiverName: 'NORIDIAN', receiverId: '01112', applicationReceiverCode: '01112'));
      expect(matched.ok, isTrue);
      final segs = X12Formatter.segments(matched.x12!);
      final gs03 = segs.firstWhere((s) => s.startsWith('GS*')).split('*')[3];
      final nm109 = segs.firstWhere((s) => s.startsWith('NM1*40*')).split('*')[9];
      expect(nm109, gs03);
      // Other payers are not held to the Medicare rule.
      expect(_build(claim, _account(_aetna()), config: _directConfig.copyWith(receiverId: '60054')).ok, isTrue);
    });

    test('never sends the loops whose edits changed this quarter but SOLIS does not use', () {
      final r = _build(_claim([_line('99213', 'Office visit'), _line('J3490', 'Ceftriaxone 1 g IM')]), _account(_medicare()));
      final segs = X12Formatter.segments(r.x12!);
      final ids = segs.map((s) => s.split('*').first).toSet();
      // 2320 CAS, 2430 SVD, 2440 LQ/FRM, 2400 PS1 (purchased service).
      for (final id in ['CAS', 'SVD', 'LQ', 'FRM', 'PS1', 'OI', 'MOA']) {
        expect(ids.contains(id), isFalse, reason: id);
      }
      // One SBR only (no 2320 other subscriber), no 2310C (NM1*77), no 2420x loops.
      expect(segs.where((s) => s.startsWith('SBR*')).length, 1);
      for (final q in ['77', 'DN', 'DK', 'DQ', 'QB', 'PW', '45']) {
        expect(segs.any((s) => s.startsWith('NM1*$q*')), isFalse, reason: 'NM1*$q');
      }
      // CLM11 (related causes) is never sent: CLM ends at CLM09.
      expect(segs.firstWhere((s) => s.startsWith('CLM*')).split('*').length, lessThanOrEqualTo(10));
    });

    test('the service date on the claim is the visit date, not the day it is built', () {
      final r = _build(_claim([_line('99213', 'Office visit')]), _account(_medicare()));
      expect(X12Formatter.segments(r.x12!).where((s) => s.startsWith('DTP*472*')), ['DTP*472*D8*20260930']);
    });
  });

  group('276 claim status request', () {
    ClaimStatusRequest req({PatientAccount? account, ProviderProfile? provider, String from = '2026-09-30', String? to}) =>
        ClaimStatusRequest(
          account: account ?? _account(_medicare()),
          provider: provider ?? testProvider(),
          payerId: '01112',
          dateOfServiceFrom: from,
          dateOfServiceTo: to,
        );

    test('a complete Medicare request passes the 276 edits', () {
      expect(CmsEdiEdits.claimStatusProblems(req(), today: DateTime(2026, 10, 18)), isEmpty);
    });

    test('the body carries the MBI without dashes, the birth date and the sex (2000D DMG)', () {
      final body = StediClient.claimStatusBody(req());
      expect(body['subscriber'], {
        'memberId': '1EG4TE5MK73',
        'firstName': 'Jane',
        'lastName': 'Doe',
        'dateOfBirth': '19500304',
        'gender': 'F',
      });
      expect(body['encounter'], {'beginningDateOfService': '20260930', 'endDateOfService': '20260930'});
    });

    test('without a practice name the provider is named by the clinician (2100C NM103)', () {
      final body = StediClient.claimStatusBody(req(provider: testProvider().copyWith(practiceName: '')));
      final p = (body['providers'] as List).single as Map;
      expect(p.containsKey('organizationName'), isFalse);
      expect(p['lastName'], 'Lin');
      expect(p['firstName'], 'Sarah');
    });

    test('each problem names its CMS 276 edit', () {
      List<String?> codes(ClaimStatusRequest r) => CmsEdiEdits.claimStatusProblems(r, today: DateTime(2026, 10, 18)).map((e) => e.code).toList();
      expect(codes(req(account: _account(_medicare(memberId: '123456789A')))), ['CMS-EDI-X212.56/135.2100D.NM109.020']);
      expect(codes(req(account: _account(_medicare(), sex: PatientSex.unknown))), ['CMS-EDI-X212.54/NA.2000D.DMG03.010']);
      expect(codes(req(account: _account(_medicare(), dob: DateTime(2027, 1, 1)))), ['CMS-EDI-X212.54/NA.2000D.DMG02.030']);
      expect(codes(req(from: '2026-02-30')), ['CMS-EDI-X212.67/155.2200D.DTP03.020']);
      expect(codes(req(from: '2026-10-02', to: '2026-10-01')), ['CMS-EDI-X212.67/155.2200D.DTP03.040']);
      expect(codes(req(provider: testProvider().copyWith(npi: '1234567890'))), ['CMS-EDI-X212.49/126.2100C.NM109.020']);
      final e = CmsEdiEdits.claimStatusProblems(req(account: _account(_medicare(), sex: PatientSex.unknown))).single;
      expect(e.description, contains(_cite));
    });

    test('non-Medicare payers are not held to the Medicare-only member ID, birth date and sex edits', () {
      expect(CmsEdiEdits.claimStatusProblems(req(account: _account(_aetna(), sex: PatientSex.unknown)), today: DateTime(2026, 10, 18)), isEmpty);
    });

    test('the Stedi client returns the problems without calling Stedi', () async {
      final client = StediClient(apiKey: 'fake-test-key-0000');
      final r = await client.claimStatus(req(account: _account(_medicare(memberId: 'BAD'))));
      expect(r.success, isFalse);
      expect(r.httpStatus, 0);
      expect(r.errors.single.code, 'CMS-EDI-X212.56/135.2100D.NM109.020');
    });
  });
}
