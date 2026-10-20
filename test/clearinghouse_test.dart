import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/billing/clearinghouse.dart';
import 'package:solis_mobile/services/billing/integration_settings.dart';
import 'package:solis_mobile/services/billing/stedi_client.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';

// Not a real key: a placeholder so header tests can check it is passed through.
const _fakeKey = 'fake-test-key-0000';

// Shapes follow the examples on
// https://www.stedi.com/docs/api-reference/healthcare/post-healthcare-claims-raw-x12
const _acceptedClaim = '''
{
  "claimReference": {
    "correlationId": "01J1M588QT2TAV2N093GNJ998T",
    "formatVersion": "5010",
    "patientControlNumber": "SOL-1000017-V2",
    "payerId": "60054",
    "timeOfResponse": "2024-07-10T22:05:32.203Z"
  },
  "controlNumber": "000000001",
  "editResponses": [],
  "errors": [],
  "httpStatusCode": "200 OK",
  "meta": {"applicationMode": "test", "traceId": "b727b8e7-1f00-4011-bc6e-e41444d406d8"},
  "payer": {"payerId": "60054", "payerName": "Cigna"},
  "status": "SUCCESS",
  "tradingPartnerServiceId": "60054"
}
''';

const _rejectedClaim = '''
{
  "controlNumber": "000000002",
  "errors": [
    {
      "code": "33",
      "description": "Input Errors",
      "followupAction": "Please Correct and Resubmit",
      "location": "Loop 2010AA NM109"
    }
  ],
  "httpStatusCode": "400 BAD_REQUEST",
  "status": "ERROR"
}
''';

// Shape follows the example on
// https://www.stedi.com/docs/api-reference/healthcare/post-healthcare-eligibility
const _eligibility = '''
{
  "controlNumber": "345459952",
  "tradingPartnerServiceId": "87726",
  "meta": {"applicationMode": "test", "senderId": "STEDI"},
  "subscriber": {"memberId": "UHC202649", "firstName": "JOHN", "lastName": "DOE", "groupNumber": "0705214"},
  "planStatus": [
    {"statusCode": "1", "status": "Active Coverage", "planDetails": "CHOICE PLUS", "serviceTypeCodes": ["30"]}
  ],
  "benefitsInformation": [
    {"code": "1", "name": "Active Coverage", "serviceTypeCodes": ["30"], "planCoverage": "CHOICE PLUS"},
    {"code": "B", "name": "Co-Payment", "serviceTypeCodes": ["98"], "coverageLevelCode": "IND",
     "timeQualifierCode": "27", "timeQualifier": "Visit", "benefitAmount": "40", "inPlanNetworkIndicatorCode": "N"},
    {"code": "B", "name": "Co-Payment", "serviceTypeCodes": ["98"], "coverageLevelCode": "IND",
     "timeQualifierCode": "27", "timeQualifier": "Visit", "benefitAmount": "25", "inPlanNetworkIndicatorCode": "Y"},
    {"code": "C", "name": "Deductible", "serviceTypeCodes": ["30"], "coverageLevelCode": "FAM",
     "timeQualifierCode": "29", "timeQualifier": "Remaining", "benefitAmount": "3000", "inPlanNetworkIndicatorCode": "Y"},
    {"code": "C", "name": "Deductible", "serviceTypeCodes": ["30"], "coverageLevelCode": "IND",
     "timeQualifierCode": "23", "timeQualifier": "Calendar Year", "benefitAmount": "2000", "inPlanNetworkIndicatorCode": "Y"},
    {"code": "C", "name": "Deductible", "serviceTypeCodes": ["30"], "coverageLevelCode": "IND",
     "timeQualifierCode": "29", "timeQualifier": "Remaining", "benefitAmount": "1450.5", "inPlanNetworkIndicatorCode": "Y"},
    {"code": "A", "name": "Co-Insurance", "serviceTypeCodes": ["30"], "coverageLevelCode": "IND",
     "benefitPercent": "0.2", "inPlanNetworkIndicatorCode": "Y"},
    {"code": "G", "name": "Out of Pocket (Stop Loss)", "serviceTypeCodes": ["30"], "coverageLevelCode": "IND",
     "timeQualifierCode": "29", "benefitAmount": "5200", "inPlanNetworkIndicatorCode": "Y"}
  ],
  "errors": [],
  "x12": "ISA*00*..."
}
''';

const _eligibilityError = '''
{
  "controlNumber": "000647813",
  "errors": [
    {"code": "44", "description": "Invalid/Missing Provider Name", "followupAction": "Please Correct and Resubmit",
     "field": "AAA", "location": "Loop 2100B", "possibleResolutions": "Provider name is required."}
  ],
  "meta": {"applicationMode": "test"}
}
''';

// Shape follows https://www.stedi.com/docs/api-reference/healthcare/post-healthcare-claim-status
const _claimStatus = '''
{
  "claims": [
    {
      "claimStatus": {
        "amountPaid": "108.77",
        "claimServiceDate": "20250701",
        "effectiveDate": "2025-07-17",
        "patientAccountNumber": "12345678",
        "statusCategoryCode": "F1",
        "statusCategoryCodeValue": "Finalized/Payment - The claim/line has been paid.",
        "statusCode": "65",
        "statusCodeValue": "Claim/line has been paid.",
        "submittedAmount": "267.54",
        "tradingPartnerClaimNumber": "0123456789"
      },
      "serviceDetails": []
    }
  ],
  "controlNumber": "123456789"
}
''';

PatientAccount _account() => PatientAccount(
      accountNumber: 'SOL-1000017',
      firstName: 'John',
      lastName: 'Doe',
      dateOfBirth: DateTime(1971, 1, 1),
      sex: PatientSex.male,
      createdAtUtc: DateTime.utc(2026, 10, 1),
      insurance: const InsuranceCoverage(payerName: 'UnitedHealthcare', payerId: '87726', memberId: 'UHC202649'),
    );

void main() {
  group('StediClient claim submission', () {
    test('posts raw X12 to the professional claims endpoint with the API key', () async {
      late http.Request captured;
      final client = StediClient(
        apiKey: _fakeKey,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(_acceptedClaim, 200, headers: {'content-type': 'application/json'});
        }),
      );
      final r = await client.submitClaim('ISA*00~\nGS*HC~\n', idempotencyKey: 'SOL-1000017-V2');

      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'https://healthcare.us.stedi.com/2024-04-01/change/medicalnetwork/professionalclaims/v3/raw-x12-submission');
      expect(captured.headers['Authorization'], _fakeKey);
      expect(captured.headers['Content-Type'], startsWith('application/json'));
      expect(captured.headers['Idempotency-Key'], 'SOL-1000017-V2');
      expect(jsonDecode(captured.body), {'x12': 'ISA*00~GS*HC~'});

      expect(r.outcome, SubmissionOutcome.accepted);
      expect(r.accepted, isTrue);
      expect(r.correlationId, '01J1M588QT2TAV2N093GNJ998T');
      expect(r.patientControlNumber, 'SOL-1000017-V2');
      expect(r.controlNumber, '000000001');
      expect(r.payerName, 'Cigna');
      expect(r.payerId, '60054');
      expect(r.testMode, isTrue);
      expect(r.errors, isEmpty);
      expect(r.rawResponse, _acceptedClaim);
    });

    test('rejected claim returns reasons', () async {
      final client = StediClient(apiKey: _fakeKey, httpClient: MockClient((_) async => http.Response(_rejectedClaim, 400)));
      final r = await client.submitClaim('ISA~');
      expect(r.outcome, SubmissionOutcome.rejected);
      expect(r.errors.single.code, '33');
      expect(r.errors.single.location, 'Loop 2010AA NM109');
      expect(r.errors.single.toString(), contains('Please Correct and Resubmit'));
    });

    test('auth failure and network errors are failures, not rejections', () async {
      final denied = StediClient(
        apiKey: _fakeKey,
        httpClient: MockClient((_) async => http.Response('{"message":"Forbidden","code":"AccessDeniedException"}', 403)),
      );
      final r = await denied.submitClaim('ISA~');
      expect(r.outcome, SubmissionOutcome.failed);
      expect(r.errors.single.description, 'Forbidden');

      final offline = StediClient(apiKey: _fakeKey, httpClient: MockClient((_) async => throw http.ClientException('offline')));
      final o = await offline.submitClaim('ISA~');
      expect(o.outcome, SubmissionOutcome.failed);
      expect(o.httpStatus, 0);

      final garbage = StediClient.parseSubmission(502, '<html>bad gateway</html>');
      expect(garbage.outcome, SubmissionOutcome.failed);
      expect(garbage.errors, isNotEmpty);
    });

    test('no key means no request', () async {
      var called = false;
      final client = StediClient(apiKey: '  ', httpClient: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }));
      final r = await client.submitClaim('ISA~');
      expect(called, isFalse);
      expect(r.outcome, SubmissionOutcome.failed);
      expect(client.toString(), isNot(contains(_fakeKey)));
    });
  });

  group('StediClient eligibility', () {
    test('builds the 270 body from account and provider', () async {
      late http.Request captured;
      final client = StediClient(
        apiKey: _fakeKey,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(_eligibility, 200);
        }),
      );
      final r = await client.checkEligibility(EligibilityRequest(
        account: _account(),
        provider: ProviderProfile.demo(),
        payerId: '87726',
        dateOfService: '2026-10-15',
      ));

      expect(captured.url.path, '/2024-04-01/change/medicalnetwork/eligibility/v3');
      expect(captured.headers['Authorization'], _fakeKey);
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['tradingPartnerServiceId'], '87726');
      expect(body['provider'], {'organizationName': 'Bayview Family Medicine', 'npi': '1982736450'});
      expect(body['subscriber'], {'memberId': 'UHC202649', 'firstName': 'John', 'lastName': 'Doe', 'dateOfBirth': '19710101'});
      expect(body['encounter'], {'serviceTypeCodes': ['30'], 'dateOfService': '20261015'});

      expect(r.success, isTrue);
      expect(r.activeCoverage, isTrue);
      expect(r.planName, 'CHOICE PLUS');
      expect(r.groupNumber, '0705214');
      expect(r.copay, '25'); // in-network beats out-of-network
      expect(r.deductibleRemaining, '1450.5'); // individual remaining, not family or calendar year
      expect(r.outOfPocketRemaining, '5200');
      expect(r.coinsurancePercent, '20');
      expect(r.testMode, isTrue);
    });

    test('AAA errors are returned', () {
      final r = StediClient.parseEligibility(400, _eligibilityError);
      expect(r.success, isFalse);
      expect(r.activeCoverage, isNull);
      expect(r.errors.single.code, '44');
      expect(r.errors.single.description, 'Invalid/Missing Provider Name');
      expect(r.errors.single.location, 'Loop 2100B');
    });

    test('inactive coverage', () {
      final r = StediClient.parseEligibility(200, '{"planStatus":[{"statusCode":"6","status":"Inactive"}],"errors":[]}');
      expect(r.activeCoverage, isFalse);
    });
  });

  group('StediClient claim status', () {
    test('builds the 276 body and parses the 277', () async {
      late http.Request captured;
      final client = StediClient(
        apiKey: _fakeKey,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(_claimStatus, 200);
        }),
      );
      final r = await client.claimStatus(ClaimStatusRequest(
        account: _account(),
        provider: ProviderProfile.demo(),
        payerId: '87726',
        dateOfServiceFrom: '2025-07-01',
      ));
      expect(captured.url.path, '/2024-04-01/change/medicalnetwork/claimstatus/v2');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['providers'], [
        {'organizationName': 'Bayview Family Medicine', 'npi': '1982736450', 'providerType': 'BillingProvider'},
      ]);
      expect(body['encounter'], {'beginningDateOfService': '20250701', 'endDateOfService': '20250701'});
      expect(body['subscriber']['memberId'], 'UHC202649');

      expect(r.success, isTrue);
      final c = r.claims.single;
      expect(c.paid, isTrue);
      expect(c.finalized, isTrue);
      expect(c.rejected, isFalse);
      expect(c.paidAmount, '108.77');
      expect(c.submittedAmount, '267.54');
      expect(c.payerClaimNumber, '0123456789');
      expect(c.statusDescription, 'Claim/line has been paid.');
    });

    test('errorResponse is surfaced', () {
      final r = StediClient.parseClaimStatus(200,
          '{"errorResponse":{"code":"400","description":"Bad","errors":[{"code":"72","description":"Invalid member ID","followupAction":"Correct and resubmit"}]}}');
      expect(r.success, isFalse);
      expect(r.errors.single.code, '72');
    });
  });

  group('IntegrationSettings', () {
    test('stores keys and submitter config, reports configured flags', () async {
      final store = MemorySecretStore();
      final s = IntegrationSettings(store: store);
      var notified = 0;
      s.addListener(() => notified++);
      await s.load();
      expect(s.isClaimsConfigured, isFalse);
      expect(s.isEligibilityConfigured, isFalse);

      await s.setStediApiKey('  $_fakeKey  ');
      await s.setDeepgramApiKey('dg-fake');
      await s.setSubmitterConfig(const SubmitterConfig(
        submitterName: 'Bayview', submitterId: '123', isaSenderId: 'SENDER', isaReceiverId: 'STEDITEST'));
      expect(s.isEligibilityConfigured, isTrue);
      expect(s.isClaimsConfigured, isTrue);
      expect(s.isTranscriptionConfigured, isTrue);
      expect(s.stediKeyHint, '....0000');
      expect(s.toString(), isNot(contains(_fakeKey)));
      expect(await store.read(IntegrationSettings.stediApiKeyKey), _fakeKey);
      expect(notified, 4);

      final reloaded = IntegrationSettings(store: store);
      await reloaded.load();
      expect(reloaded.stediApiKey, _fakeKey);
      expect(reloaded.submitterConfig!.isaReceiverId, 'STEDITEST');

      final c1 = await reloaded.submitterConfigForNextClaim();
      final c2 = await reloaded.submitterConfigForNextClaim();
      expect(c1!.interchangeControlNumber, 1);
      expect(c2!.interchangeControlNumber, 2);
      expect(c2.groupControlNumber, 2);

      await reloaded.setStediApiKey('');
      expect(reloaded.hasStediApiKey, isFalse);
      expect(await store.read(IntegrationSettings.stediApiKeyKey), isNull);
    });
  });
}
