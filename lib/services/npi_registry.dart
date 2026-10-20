import 'dart:convert';

import 'package:http/http.dart' as http;

/// A provider record from the CMS NPPES NPI Registry.
class NpiRecord {
  final String npi;
  final bool isOrganization;
  final String? firstName;
  final String? lastName;
  final String? credential;
  final String? organizationName;
  final String? taxonomyCode;
  final String? taxonomyDescription;
  final String? addressLine1;
  final String? city;
  final String? state;
  final String? zip;
  final String? phone;
  final bool active;

  const NpiRecord({
    required this.npi,
    required this.isOrganization,
    this.firstName,
    this.lastName,
    this.credential,
    this.organizationName,
    this.taxonomyCode,
    this.taxonomyDescription,
    this.addressLine1,
    this.city,
    this.state,
    this.zip,
    this.phone,
    this.active = true,
  });

  String get displayName => isOrganization
      ? (organizationName ?? npi)
      : [firstName, lastName].whereType<String>().where((s) => s.isNotEmpty).join(' ');
}

/// Looks up providers in the public NPPES NPI Registry API (no key needed).
/// https://npiregistry.cms.hhs.gov/api-page
class NpiRegistry {
  static const _base = 'https://npiregistry.cms.hhs.gov/api/';
  final http.Client _client;

  NpiRegistry({http.Client? client}) : _client = client ?? http.Client();

  /// Returns the record for [npi], or null when the registry has none.
  /// Throws on network errors so the caller can say so.
  Future<NpiRecord?> lookup(String npi) async {
    final uri = Uri.parse('$_base?version=2.1&number=${Uri.encodeQueryComponent(npi.trim())}');
    final res = await _client.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw NpiRegistryException('Registry returned ${res.statusCode}');
    return parse(jsonDecode(res.body));
  }

  static NpiRecord? parse(dynamic body) {
    if (body is! Map || (body['result_count'] ?? 0) == 0) return null;
    final results = body['results'];
    if (results is! List || results.isEmpty) return null;
    final r = results.first as Map;
    final basic = (r['basic'] as Map?) ?? const {};
    final isOrg = r['enumeration_type'] == 'NPI-2';

    Map? location;
    for (final a in (r['addresses'] as List? ?? const [])) {
      if (a is Map && a['address_purpose'] == 'LOCATION') location = a;
    }
    location ??= (r['addresses'] is List && (r['addresses'] as List).isNotEmpty) ? (r['addresses'] as List).first as Map : null;

    Map? taxonomy;
    for (final t in (r['taxonomies'] as List? ?? const [])) {
      if (t is Map && t['primary'] == true) taxonomy = t;
    }
    taxonomy ??= (r['taxonomies'] is List && (r['taxonomies'] as List).isNotEmpty) ? (r['taxonomies'] as List).first as Map : null;

    String? title(dynamic v) {
      if (v is! String || v.trim().isEmpty) return null;
      return v.trim().split(RegExp(r'\s+')).map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}').join(' ');
    }

    final zip = (location?['postal_code'] as String?)?.replaceAll(RegExp(r'[^0-9]'), '');
    final phone = (location?['telephone_number'] as String?)?.replaceAll(RegExp(r'[^0-9]'), '');

    return NpiRecord(
      npi: '${r['number']}',
      isOrganization: isOrg,
      firstName: title(basic['first_name']),
      lastName: title(basic['last_name']),
      credential: (basic['credential'] as String?)?.replaceAll('.', '').trim(),
      organizationName: title(basic['organization_name']),
      taxonomyCode: taxonomy?['code'] as String?,
      taxonomyDescription: taxonomy?['desc'] as String?,
      addressLine1: title(location?['address_1']),
      city: title(location?['city']),
      state: (location?['state'] as String?)?.toUpperCase(),
      // ZIP+4 when NPPES has it: the 837P billing provider address asks for 9 digits.
      zip: zip == null || zip.length < 5 ? zip : (zip.length >= 9 ? zip.substring(0, 9) : zip.substring(0, 5)),
      phone: (phone == null || phone.length != 10) ? (location?['telephone_number'] as String?) : '(${phone.substring(0, 3)}) ${phone.substring(3, 6)}-${phone.substring(6)}',
      active: (basic['status'] ?? 'A') == 'A',
    );
  }
}

class NpiRegistryException implements Exception {
  final String message;
  NpiRegistryException(this.message);
  @override
  String toString() => message;
}
