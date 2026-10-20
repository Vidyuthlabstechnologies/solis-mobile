import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solis_mobile/services/npi_registry.dart';

void main() {
  const sample = {
    'result_count': 1,
    'results': [
      {
        'number': 1003000126,
        'enumeration_type': 'NPI-1',
        'basic': {'first_name': 'JANE', 'last_name': 'DOE', 'credential': 'M.D.', 'status': 'A'},
        'addresses': [
          {'address_purpose': 'MAILING', 'address_1': 'PO BOX 1', 'city': 'NOWHERE', 'state': 'VA', 'postal_code': '201900000'},
          {
            'address_purpose': 'LOCATION',
            'address_1': '450 MISSION BAY BLVD',
            'city': 'SAN FRANCISCO',
            'state': 'CA',
            'postal_code': '941581234',
            'telephone_number': '415-555-0142',
          },
        ],
        'taxonomies': [
          {'code': '207RC0000X', 'desc': 'Internal Medicine, Cardiovascular Disease', 'primary': false},
          {'code': '207R00000X', 'desc': 'Internal Medicine', 'primary': true},
        ],
      },
    ],
  };

  test('parses the practice location and primary taxonomy', () {
    final r = NpiRegistry.parse(sample)!;
    expect(r.displayName, 'Jane Doe');
    expect(r.credential, 'MD');
    expect(r.addressLine1, '450 Mission Bay Blvd');
    expect(r.city, 'San Francisco');
    expect(r.zip, '941581234');
    expect(r.phone, '(415) 555-0142');
    expect(r.taxonomyCode, '207R00000X');
    expect(r.isOrganization, isFalse);
  });

  test('returns null when the registry has no match', () {
    expect(NpiRegistry.parse({'result_count': 0, 'results': []}), isNull);
  });

  test('queries the NPPES API by number', () async {
    late Uri called;
    final registry = NpiRegistry(
      client: MockClient((req) async {
        called = req.url;
        return http.Response(jsonEncode(sample), 200);
      }),
    );
    final r = await registry.lookup('1003000126');
    expect(called.host, 'npiregistry.cms.hhs.gov');
    expect(called.queryParameters['number'], '1003000126');
    expect(called.queryParameters['version'], '2.1');
    expect(r!.npi, '1003000126');
  });
}
