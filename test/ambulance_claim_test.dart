import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/ambulance_transport.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';

import 'support/test_provider.dart';

const _config = SubmitterConfig(submitterName: 'Bay EMS', submitterId: '555', isaSenderId: 'BAYEMS', isaReceiverId: 'STEDITEST');

const _complete = AmbulanceTransport(
  pickup: TransportAddress(line1: '12 Oak St', city: 'Oakland', state: 'CA', zip: '94607'),
  dropoff: TransportAddress(name: 'Highland Hospital', line1: '1411 E 31st St', city: 'Oakland', state: 'CA', zip: '94602'),
  loadedMiles: 7.25,
  milesSource: 'gps',
  reasonCode: 'A',
  patientWeightLbs: 180,
  originCode: 'R',
  destinationCode: 'H',
  conditionCodes: ['01', '06'],
);

PatientAccount _patient() => PatientAccount(
      accountNumber: 'SOL-1000017',
      firstName: 'Jane',
      lastName: 'Doe',
      dateOfBirth: DateTime(1958, 3, 4),
      sex: PatientSex.female,
      addressLine1: '12 Oak St',
      city: 'Oakland',
      state: 'CA',
      zip: '94607',
      createdAtUtc: DateTime.utc(2026),
      insurance: const InsuranceCoverage(payerName: 'Medicare Part B', payerId: '01112', planType: 'Medicare', memberId: '1EG4TE5MK73'),
    );

ClaimDraft _claim({List<String> mods = const ['RH']}) => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 15),
      diagnoses: const [ClaimDiagnosis(code: 'I21.19', description: 'STEMI', source: DxSource.physicianConfirmed)],
      lines: [
        ServiceLine(code: 'A0427', description: 'ALS1 emergency', charge: 650, modifiers: mods, diagnosisCodes: const ['I21.19']),
        ServiceLine(code: 'A0425', description: 'Ground mileage', charge: 12, modifiers: mods, diagnosisCodes: const ['I21.19']),
      ],
    );

Visit _visit(AmbulanceTransport? t) => Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '41', createdAtUtc: DateTime.utc(2026), transport: t);

X12BuildResult _build({AmbulanceTransport? t = _complete, ClaimDraft? claim}) => Claim837PGenerator.build(
      claim: claim ?? _claim(),
      account: _patient(),
      visit: _visit(t),
      provider: testProvider(),
      config: _config,
      now: DateTime(2026, 10, 16, 9, 5),
    );

void main() {
  group('837P ambulance (005010X222A1)', () {
    test('carries CR1, CRC, the pick-up and drop-off loops and miles in tenths', () {
      final r = _build();
      expect(r.errors, isEmpty);
      final s = X12Formatter.segments(r.x12!);
      // CR1: weight in pounds, reason A, DH miles rounded up to a tenth.
      expect(s, contains('CR1*LB*180**A*DH*7.3'));
      expect(s, contains('CRC*07*Y*01*06'));
      expect(s, contains('NM1*PW*2'));
      expect(s, contains('N3*12 OAK ST'));
      expect(s, contains('NM1*45*2*HIGHLAND HOSPITAL'));
      expect(s, contains('N3*1411 E 31ST ST'));
      expect(s, contains('N4*OAKLAND*CA*94602'));
      // CR1 and CRC sit in 2300 after CLM and before HI; 2310E/F before the lines.
      int at(String p) => s.indexWhere((x) => x.startsWith(p));
      expect(at('CLM*'), lessThan(at('CR1*')));
      expect(at('CR1*'), lessThan(at('CRC*')));
      expect(at('CRC*'), lessThan(at('HI*')));
      expect(at('HI*'), lessThan(at('NM1*PW*')));
      expect(at('NM1*PW*'), lessThan(at('NM1*45*')));
      expect(at('NM1*45*'), lessThan(at('LX*')));
      // Mileage line bills 7.3 loaded miles; the total matches the lines.
      final sv1 = s.where((x) => x.startsWith('SV1*')).map((x) => x.split('*')).toList();
      expect(sv1[0][1], 'HC:A0427:RH');
      expect(sv1[1][1], 'HC:A0425:RH');
      expect(sv1[1][4], '7.3');
      expect(sv1[1][2], '87.6');
      expect(s.firstWhere((x) => x.startsWith('CLM*')).split('*')[2], '737.6');
      // SE01 still counts every segment.
      final st = s.indexWhere((x) => x.startsWith('ST*'));
      final se = s.indexWhere((x) => x.startsWith('SE*'));
      expect(int.parse(s[se].split('*')[1]), se - st + 1);
    });

    test('weight and certification are left out when not recorded', () {
      final r = _build(t: const AmbulanceTransport(
        pickup: TransportAddress(line1: '12 Oak St', city: 'Oakland', state: 'CA', zip: '94607'),
        dropoff: TransportAddress(line1: '1411 E 31st St', city: 'Oakland', state: 'CA', zip: '94602'),
        loadedMiles: 3,
        reasonCode: 'D',
        originCode: 'R',
        destinationCode: 'H',
      ));
      expect(r.errors, isEmpty);
      final s = X12Formatter.segments(r.x12!);
      expect(s, contains('CR1****D*DH*3'));
      expect(s.any((x) => x.startsWith('CRC*')), isFalse);
      expect(s, contains('NM1*45*2'));
    });

    test('missing miles, addresses, reason or modifiers stop the file; miles never default to 1', () {
      final none = _build(t: null);
      expect(none.ok, isFalse);
      expect(none.errors.join(' '), contains('transport details'));
      expect(none.errors.join(' '), contains('A0425 needs the loaded miles'));

      final partial = _build(t: const AmbulanceTransport(pickup: TransportAddress(line1: '12 Oak St', city: 'Oakland', state: 'CA', zip: '94607')));
      expect(partial.errors.join(' '), allOf(contains('drop-off'), contains('Loaded miles'), contains('CR104')));

      final noMods = _build(claim: _claim(mods: const []));
      expect(noMods.errors.where((e) => e.contains('origin and destination modifier')), hasLength(2));
    });

    test('office claims are unchanged: no CR1 and no ambulance loops', () {
      final r = Claim837PGenerator.build(
        claim: ClaimDraft(
          generatedAtUtc: DateTime.utc(2026),
          diagnoses: const [ClaimDiagnosis(code: 'J06.9', description: 'URI', source: DxSource.physicianConfirmed)],
          lines: const [ServiceLine(code: '99213', description: 'Visit', charge: 140, diagnosisCodes: ['J06.9'])],
        ),
        account: _patient(),
        visit: Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '11', createdAtUtc: DateTime.utc(2026)),
        provider: testProvider(),
        config: _config,
      );
      expect(r.errors, isEmpty);
      expect(r.x12, isNot(contains('CR1*')));
      expect(r.x12, isNot(contains('NM1*PW')));
    });
  });

  group('Ambulance claim checks', () {
    List<String> rules(Visit v, ClaimDraft c) =>
        ClaimScrubber.check(claim: c, account: _patient(), visit: v, provider: testProvider(), noteSigned: true).map((i) => '${i.ruleId} ${i.title}').toList();

    test('missing transport, miles and modifiers are errors with a transport fix', () {
      final issues = ClaimScrubber.check(claim: _claim(mods: const []), account: _patient(), visit: _visit(null), provider: testProvider(), noteSigned: true);
      final errs = issues.where((i) => i.severity == IssueSeverity.error).map((i) => i.ruleId).toSet();
      expect(errs, containsAll(['CLAIM-AMBULANCE-01', 'CLAIM-AMBULANCE-02', 'CLAIM-AMBULANCE-03']));
      expect(issues.where((i) => i.ruleId?.startsWith('CLAIM-AMBULANCE') ?? false).every((i) => i.fix?.kind == FixKind.editTransport), isTrue);
    });

    test('a complete transport passes', () {
      expect(rules(_visit(_complete), _claim()).where((r) => r.startsWith('CLAIM-AMBULANCE')), isEmpty);
    });
  });

  group('Transport helpers', () {
    test('miles round up to the next tenth', () {
      expect(roundUpTenth(7.21), 7.3);
      expect(roundUpTenth(7.3), 7.3);
      expect(roundUpTenth(0.01), 0.1);
    });

    test('a GPS track sums into miles and skips imprecise fixes', () {
      Map<String, dynamic> fix(double lat, double lng, {double acc = 10}) => {'available': true, 'latitude': lat, 'longitude': lng, 'accuracy': acc};
      // About 0.69 miles per 0.01 degree of latitude.
      final miles = trackMiles([fix(37.80, -122.27), fix(37.81, -122.27), fix(37.50, -122.27, acc: 900), fix(37.82, -122.27)]);
      expect(miles, closeTo(1.38, 0.02));
      expect(trackMiles([fix(37.8, -122.27)]), 0);
    });

    test('an address from the phone geocoder fills only what it knows', () {
      final a = TransportAddress.fromGps({
        'available': true,
        'address': '450 Mission Bay Blvd, San Francisco, CA 94158, USA',
        'street': '450 Mission Bay Blvd',
        'locality': 'San Francisco',
        'adminArea': 'California',
        'postalCode': '94158',
      })!;
      expect(a.line1, '450 Mission Bay Blvd');
      expect(a.state, 'CA');
      expect(a.isComplete, isTrue);
      expect(TransportAddress.fromGps({'available': false}), isNull);
      expect(usStateCode('New York'), 'NY');
      expect(usStateCode('Ontario'), isNull);
    });

    test('origin and destination codes form the modifier', () {
      expect(_complete.modifier, 'RH');
      expect(isOriginDestinationModifier('RH'), isTrue);
      expect(isOriginDestinationModifier('XH'), isFalse, reason: 'X is a destination-only code');
      expect(isOriginDestinationModifier('25'), isFalse);
      expect(const AmbulanceTransport().missing, ['pick-up address', 'drop-off address', 'loaded miles', 'transport reason']);
    });
  });
}
