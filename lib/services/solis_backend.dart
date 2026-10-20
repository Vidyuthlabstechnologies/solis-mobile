import 'dart:convert';

import 'package:http/http.dart' as http;

import 'net/pinned_http.dart';

/// Client for the SOLIS Worker (`/api/v2`). Vendor keys (Anthropic, Stedi,
/// Deepgram) live only as Worker secrets; the app holds just the app token,
/// passed at build time:
///
///     flutter build apk --dart-define=SOLIS_APP_TOKEN=...
///
/// See docs/KEYS.md for the contract.
class SolisBackend {
  static const _defaultUrl = String.fromEnvironment(
    'SOLIS_BACKEND_URL',
    defaultValue: 'https://cloudflare-healthcare-rcm-agentic-cloud.cbvarshini1.workers.dev',
  );
  static const _defaultToken = String.fromEnvironment('SOLIS_APP_TOKEN');

  static SolisBackend instance = SolisBackend();

  /// Header that carries the signed-in clinician's session (the app token
  /// stays in `Authorization`).
  static const sessionHeader = 'X-Solis-Session';

  /// Where cloud calls get the user session from. Set at app start to the
  /// AuthService; null (tests, demo) sends the app token only.
  static SessionTokens? defaultSessions;

  static const offlineMessage = 'Cloud features need a connection to the SOLIS server. On-device mode still works offline.';
  static const pinFailureMessage = 'The connection to the SOLIS server could not be verified. This network may be inspecting secure traffic; try another network.';
  static const signInAgainMessage = 'Your sign-in has expired. Sign out and sign in again to use cloud features.';

  final Uri baseUrl;
  final String _token;
  final http.Client _http;
  final SessionTokens? _sessions;

  SolisBackend({Uri? baseUrl, String? appToken, http.Client? httpClient, SessionTokens? sessions})
      : baseUrl = baseUrl ?? Uri.parse(_defaultUrl),
        _token = (appToken ?? _defaultToken).trim(),
        _http = httpClient ?? PinnedHttp.client(),
        _sessions = sessions; // ignore: prefer_initializing_formals

  /// False in builds made without an app token; callers then stay on device.
  bool get isConfigured => _token.isNotEmpty;

  String get appToken => _token;

  SessionTokens? get sessions => _sessions ?? defaultSessions;

  Uri uri(String path) => baseUrl.replace(path: '${baseUrl.path}/api/v2$path');

  /// The session header for the signed-in clinician, or nothing in demo mode.
  Future<Map<String, String>> sessionHeaders() async {
    final s = sessions;
    if (s == null) return const {};
    final t = await s.accessToken();
    return t == null || t.isEmpty ? const {} : {sessionHeader: t};
  }

  Future<Map<String, String>> _headers() async => {
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...await sessionHeaders(),
      };

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, Duration timeout, {bool retried = false}) async {
    if (!isConfigured) throw const BackendException('This build has no backend token', 0);
    final http.Response res;
    try {
      res = await _http.post(uri(path), headers: await _headers(), body: jsonEncode(body)).timeout(timeout);
    } catch (e) {
      if (PinnedHttp.isPinFailure(e)) throw const BackendException(pinFailureMessage, 0);
      throw const BackendException(offlineMessage, 0);
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      json = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      json = {};
    }
    if (res.statusCode == 401 && json['code'] == 'session_invalid') {
      // The session expired or was revoked: refresh once, then retry.
      final s = sessions;
      if (!retried && s != null && await s.refreshAfterRejection()) {
        return _post(path, body, timeout, retried: true);
      }
      throw const BackendException(signInAgainMessage, 401);
    }
    if (res.statusCode != 200) {
      throw BackendException(_reason(res.statusCode, json['error']?.toString()), res.statusCode);
    }
    return json;
  }

  static String _reason(int status, String? error) => switch (status) {
        401 => 'The app is not authorized on the server',
        413 => 'The conversation is too long for one note',
        422 => 'The AI declined to write this note',
        429 => 'Too many requests, try again shortly',
        503 => error ?? 'The server is not set up for this yet',
        _ => error ?? 'Server error ($status)',
      };

  /// Claude writes the note from the conversation. Throws [BackendException].
  Future<CloudNote> writeNote({
    required String transcript,
    int? age,
    String? sex,
    String? placeOfService,
    String? visitType,
  }) async {
    final json = await _post(
      '/note',
      {
        'transcript': transcript,
        'patient': {'age': age, 'sex': sex},
        'placeOfService': placeOfService,
        'visitType': visitType,
      },
      const Duration(seconds: 90),
    );
    return CloudNote.fromJson(json);
  }

  /// A short-lived Deepgram token, so the Deepgram key never reaches the phone.
  Future<String> deepgramToken({int ttlSeconds = 300}) async {
    final json = await _post('/deepgram/token', {'ttlSeconds': ttlSeconds}, const Duration(seconds: 15));
    final token = json['accessToken'];
    if (token is! String || token.isEmpty) throw const BackendException('No speech token returned', 502);
    return token;
  }
}

/// Supplies the signed-in clinician's session to cloud calls.
abstract class SessionTokens {
  /// The current access token (refreshed first when it has expired), or null
  /// when nobody is signed in with a SOLIS account (signed out or demo).
  Future<String?> accessToken();

  /// Called after the server rejected the session. Returns true when a new
  /// session was obtained and the call can be retried.
  Future<bool> refreshAfterRejection();
}

class BackendException implements Exception {
  final String message;
  final int status;
  const BackendException(this.message, this.status);

  @override
  String toString() => 'BackendException($status): $message';
}

class CloudDiagnosis {
  final String description;
  final String? icd10Candidate;
  final bool confirmed;
  final String? evidence;

  const CloudDiagnosis({required this.description, this.icd10Candidate, required this.confirmed, this.evidence});
}

class CloudVital {
  final String name;
  final String value;
  final String? unit;
  const CloudVital(this.name, this.value, this.unit);

  String get display => unit == null || unit!.isEmpty ? value : '$value $unit';
}

/// The note as the Worker returns it. Missing sections become empty lists.
class CloudNote {
  final String provider;
  final String? model;
  final List<String> subjective, objective, assessment, plan;
  final List<CloudVital> vitals;
  final List<CloudDiagnosis> diagnoses;
  final List<String> warnings;

  const CloudNote({
    required this.provider,
    this.model,
    required this.subjective,
    required this.objective,
    required this.assessment,
    required this.plan,
    required this.vitals,
    required this.diagnoses,
    required this.warnings,
  });

  factory CloudNote.fromJson(Map<String, dynamic> json) {
    final note = json['note'] is Map ? json['note'] as Map : const {};
    final soap = note['soap'] is Map ? note['soap'] as Map : const {};
    List<String> lines(Object? v) => [
          if (v is List)
            for (final s in v)
              if (s is String && s.trim().isNotEmpty) s.trim(),
        ];
    return CloudNote(
      provider: json['provider']?.toString() ?? 'cloud',
      model: json['model']?.toString(),
      subjective: lines(soap['subjective']),
      objective: lines(soap['objective']),
      assessment: lines(soap['assessment']),
      plan: lines(soap['plan']),
      vitals: [
        if (note['vitals'] is List)
          for (final v in note['vitals'] as List)
            if (v is Map && v['name'] is String && v['value'] != null)
              CloudVital(v['name'] as String, v['value'].toString(), v['unit']?.toString()),
      ],
      diagnoses: [
        if (note['diagnoses'] is List)
          for (final d in note['diagnoses'] as List)
            if (d is Map && d['description'] is String)
              CloudDiagnosis(
                description: d['description'] as String,
                icd10Candidate: (d['icd10Candidate'] as String?)?.trim().toUpperCase(),
                confirmed: d['certainty'] == 'confirmed',
                evidence: d['evidence'] is List && (d['evidence'] as List).isNotEmpty && (d['evidence'] as List).first is Map
                    ? ((d['evidence'] as List).first as Map)['quote']?.toString()
                    : null,
              ),
      ],
      warnings: lines(json['warnings']),
    );
  }

  bool get isEmpty => subjective.isEmpty && objective.isEmpty && assessment.isEmpty && plan.isEmpty;
}
