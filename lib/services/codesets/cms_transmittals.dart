// Recent CMS transmittals that change what a clean claim is (HIPAA EDI
// front-end edits, HCPCS, fee schedule, NCCI, MUE, ICD-10, claim status,
// place of service, modifiers, telehealth, ambulance).
//
// solis-codesets-worker polls the CMS transmittal listing and RSS feed daily,
// tags each transmittal by keyword and serves them at GET /v1/transmittals
// (C:\Users\varsh\solis-codesets-worker\src\transmittals.ts). The list is
// public CMS information; no patient or practice data is sent.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The code-set monitor Worker (also in docs/CODESET_UPDATES.md).
const String codesetWorkerUrl = 'https://solis-codesets-worker.cbvarshini1.workers.dev';

class CmsTransmittal {
  const CmsTransmittal({
    required this.id,
    required this.title,
    required this.url,
    this.cr,
    this.issueDate,
    this.implementationDate,
    this.tags = const [],
  });

  /// Transmittal number, e.g. R13977OTN.
  final String id;
  final String title;

  /// The CMS page (https://www.cms.gov/...).
  final String url;

  /// Change request number, e.g. 14429.
  final String? cr;
  final DateTime? issueDate;
  final DateTime? implementationDate;
  final List<String> tags;

  static CmsTransmittal? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], title = j['title'], url = j['url'];
    if (id is! String || title is! String || url is! String) return null;
    // Only official CMS pages are ever opened.
    if (!url.startsWith('https://www.cms.gov/')) return null;
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return CmsTransmittal(
      id: id,
      title: title.trim(),
      url: url,
      cr: j['cr'] is String ? j['cr'] as String : null,
      issueDate: date(j['issue_date']),
      implementationDate: date(j['implementation_date']),
      tags: [for (final t in (j['tags'] is List ? j['tags'] as List : const [])) if (t is String) t],
    );
  }
}

/// Reads the relevant, current (not replaced) transmittals from the Worker.
class CmsTransmittalsClient {
  CmsTransmittalsClient({http.Client? httpClient, this.baseUrl = codesetWorkerUrl, this.timeout = const Duration(seconds: 10)})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String baseUrl;
  final Duration timeout;

  static CmsTransmittalsClient instance = CmsTransmittalsClient();

  List<CmsTransmittal>? _cached;
  DateTime? _cachedAt;

  /// The newest [limit] relevant transmittals, newest first. Throws on a
  /// network or format error. Cached for an hour unless [refresh].
  Future<List<CmsTransmittal>> recent({int limit = 5, bool refresh = false}) async {
    final c = _cached, at = _cachedAt;
    if (!refresh && c != null && at != null && DateTime.now().difference(at) < const Duration(hours: 1) && c.length >= limit) {
      return c.take(limit).toList();
    }
    final uri = Uri.parse('$baseUrl/v1/transmittals?relevant=1&current=1&limit=$limit');
    final res = await _http.get(uri, headers: {'accept': 'application/json'}).timeout(timeout);
    if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}', uri);
    final list = parse(res.body);
    _cached = list;
    _cachedAt = DateTime.now();
    return list.take(limit).toList();
  }

  /// Parses a GET /v1/transmittals body. Public for tests.
  static List<CmsTransmittal> parse(String body) {
    final j = jsonDecode(body);
    final items = j is Map ? j['transmittals'] : null;
    if (items is! List) throw const FormatException('no transmittals list');
    return [for (final t in items) ?CmsTransmittal.fromJson(t)];
  }
}
