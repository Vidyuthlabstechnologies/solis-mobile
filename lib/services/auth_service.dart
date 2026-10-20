import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'net/pinned_http.dart';
import 'security/play_integrity.dart';
import 'solis_backend.dart';

/// The signed-in clinician, as the SOLIS server knows them.
class AuthUser {
  final String id;
  final String email;
  final String fullName;
  final String? npi;

  const AuthUser({required this.id, required this.email, required this.fullName, this.npi});

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: j['id']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        fullName: j['fullName']?.toString() ?? '',
        npi: (j['npi'] as String?)?.isEmpty ?? true ? null : j['npi'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'fullName': fullName, 'npi': npi};
}

/// A server session: a 12 hour access token and a 30 day refresh token.
class AuthSession {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final DateTime refreshExpiresAt;
  final AuthUser user;

  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.refreshExpiresAt,
    required this.user,
  });

  /// Expired, or about to (one minute of slack for clock drift).
  bool get accessExpired => DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));
  bool get refreshExpired => DateTime.now().isAfter(refreshExpiresAt);

  /// Parses the server's `{ user, session }` answer.
  factory AuthSession.fromServer(Map<String, dynamic> j) {
    final s = (j['session'] as Map).cast<String, dynamic>();
    return AuthSession(
      accessToken: s['accessToken'] as String,
      refreshToken: s['refreshToken'] as String,
      expiresAt: DateTime.parse(s['expiresAt'] as String),
      refreshExpiresAt: DateTime.parse(s['refreshExpiresAt'] as String),
      user: AuthUser.fromJson((j['user'] as Map).cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user.toJson(),
        'session': {
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'expiresAt': expiresAt.toUtc().toIso8601String(),
          'refreshExpiresAt': refreshExpiresAt.toUtc().toIso8601String(),
        },
      };
}

/// Where the session is kept between launches.
abstract class SessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

/// Android Keystore / iOS Keychain backed storage.
class SecureSessionStore implements SessionStore {
  static const _key = 'solis_auth_session_v1';
  final FlutterSecureStorage _storage;
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (e) {
      debugPrint('Session could not be read: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

class MemorySessionStore implements SessionStore {
  String? value;
  MemorySessionStore([this.value]);

  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> clear() async => value = null;
}

class AuthException implements Exception {
  final String message;
  final String? code;

  /// HTTP status; 0 when the server could not be reached.
  final int status;
  const AuthException(this.message, {this.code, this.status = 0});

  bool get isOffline => status == 0 && code == 'offline';

  @override
  String toString() => 'AuthException($status, $code): $message';
}

enum AuthMode { signedOut, demo, account }

/// Clinician sign-in against the SOLIS server (`/api/v2/auth/*`).
///
/// The session is kept in secure storage, so a clinician who signed in before
/// can open the app without a connection; cloud features then explain that
/// they need one. The demo account is local only and never touches the server.
class AuthService extends ChangeNotifier implements SessionTokens {
  static AuthService? _instance;
  static AuthService get instance => _instance ??= AuthService();

  @visibleForTesting
  static set instance(AuthService s) => _instance = s;

  static const minPasswordLength = 12;
  static const demoEmail = 'dr.chen@mercygeneral.org';

  final SolisBackend _backend;
  final http.Client _http;
  final SessionStore _store;
  final Future<Map<String, String>> Function(String path) _integrityHeaders;

  AuthService({
    SolisBackend? backend,
    http.Client? httpClient,
    SessionStore? store,
    Future<Map<String, String>> Function(String path)? integrityHeaders,
  })  : _backend = backend ?? SolisBackend(sessions: _NoSessions()),
        _http = httpClient ?? PinnedHttp.client(),
        _store = store ?? const SecureSessionStore(),
        _integrityHeaders = integrityHeaders ?? PlayIntegrity.headersFor;

  AuthMode _mode = AuthMode.signedOut;
  AuthSession? _session;
  Future<bool>? _refreshing;

  AuthMode get mode => _mode;
  AuthSession? get session => _session;
  AuthUser? get user => _session?.user;
  bool get isDemo => _mode == AuthMode.demo;
  bool get isSignedIn => _mode != AuthMode.signedOut;
  bool get hasAccount => _mode == AuthMode.account && _session != null;

  /// Loads the saved session. Never touches the network, so it works offline.
  Future<AuthMode> restore() async {
    final raw = await _store.read();
    _mode = AuthMode.signedOut;
    _session = null;
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
        if (j['mode'] == 'demo') {
          _mode = AuthMode.demo;
        } else if (j['mode'] == 'account') {
          final s = AuthSession.fromServer((j['data'] as Map).cast<String, dynamic>());
          if (!s.refreshExpired) {
            _session = s;
            _mode = AuthMode.account;
          }
        }
      } catch (_) {
        await _store.clear();
      }
    }
    notifyListeners();
    return _mode;
  }

  Future<AuthUser> login({required String email, required String password}) async {
    final j = await _send('/auth/login', {'email': email.trim(), 'password': password}, attest: true);
    await _adopt(AuthSession.fromServer(j));
    return _session!.user;
  }

  Future<AuthUser> register({required String fullName, required String email, required String password, String? npi}) async {
    final j = await _send('/auth/register', {
      'fullName': fullName.trim(),
      'email': email.trim(),
      'password': password,
      if (npi != null && npi.trim().isNotEmpty) 'npi': npi.trim(),
    }, attest: true);
    await _adopt(AuthSession.fromServer(j));
    return _session!.user;
  }

  /// Local demo mode for store reviewers and trials: no server account.
  Future<void> startDemo() async {
    _session = null;
    _mode = AuthMode.demo;
    await _store.write(jsonEncode({'mode': 'demo'}));
    notifyListeners();
  }

  /// Signs out on this phone and, when reachable, revokes the session on the
  /// server. Works offline.
  Future<void> signOut() async {
    final s = _session;
    await _clearLocal();
    if (s != null) {
      try {
        await _send('/auth/logout', {'refreshToken': s.refreshToken}, session: s.accessToken, timeout: const Duration(seconds: 8));
      } catch (_) {
        // Already signed out locally; the server session expires on its own.
      }
    }
  }

  /// Permanently deletes the account on the server. Requires a connection and
  /// the current password. Signs out on success.
  Future<void> deleteAccount(String password) async {
    if (!hasAccount) throw const AuthException('Only a SOLIS account can be deleted. Demo mode has no account.', code: 'no_account');
    Future<void> attempt() async {
      final token = await accessToken();
      await _send('/auth/delete-account', {'password': password}, session: token);
    }

    try {
      await attempt();
    } on AuthException catch (e) {
      if (e.status == 401 && e.code == 'session_invalid' && await refreshAfterRejection()) {
        await attempt();
      } else {
        rethrow;
      }
    }
    await _clearLocal();
  }

  // ---- SessionTokens (used by SolisBackend for cloud calls) ----

  @override
  Future<String?> accessToken() async {
    final s = _session;
    if (_mode != AuthMode.account || s == null) return null;
    if (s.accessExpired && !s.refreshExpired) {
      try {
        await _refresh();
      } catch (_) {
        // Offline: send what we have; the server answers and the call explains.
      }
    }
    return _session?.accessToken;
  }

  @override
  Future<bool> refreshAfterRejection() async {
    if (_mode != AuthMode.account || _session == null) return false;
    try {
      return await _refresh();
    } catch (_) {
      return false;
    }
  }

  /// One refresh at a time. Returns true on a new session; false (and signs
  /// out locally) when the server no longer accepts the refresh token; throws
  /// [AuthException] when offline.
  Future<bool> _refresh() {
    final pending = _refreshing;
    if (pending != null) return pending;
    final f = _doRefresh();
    _refreshing = f;
    f.whenComplete(() {
      if (identical(_refreshing, f)) _refreshing = null;
    }).ignore();
    return f;
  }

  Future<bool> _doRefresh() async {
    final s = _session;
    if (s == null) return false;
    try {
      final j = await _send('/auth/refresh', {'refreshToken': s.refreshToken});
      await _adopt(AuthSession.fromServer(j));
      return true;
    } on AuthException catch (e) {
      if (e.status == 401) {
        await _clearLocal();
        return false;
      }
      rethrow;
    }
  }

  Future<void> _adopt(AuthSession s) async {
    _session = s;
    _mode = AuthMode.account;
    await _store.write(jsonEncode({'mode': 'account', 'data': s.toJson()}));
    notifyListeners();
  }

  Future<void> _clearLocal() async {
    _session = null;
    _mode = AuthMode.signedOut;
    await _store.clear();
    notifyListeners();
  }

  Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> body,
      {String? session, bool attest = false, Duration timeout = const Duration(seconds: 30)}) async {
    if (!_backend.isConfigured) {
      throw const AuthException('This build is not connected to the SOLIS server. Use the demo account.', code: 'not_configured');
    }
    final uri = _backend.uri(path);
    // Sign-in and sign-up carry a Play Integrity token when the build has one.
    final integrity = attest ? await _integrityHeaders(uri.path) : const <String, String>{};
    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${_backend.appToken}',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (session != null && session.isNotEmpty) SolisBackend.sessionHeader: session,
              ...integrity,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (e) {
      if (PinnedHttp.isPinFailure(e)) {
        throw const AuthException(SolisBackend.pinFailureMessage, code: 'tls_untrusted');
      }
      throw const AuthException('Cannot reach SOLIS. Check your connection and try again.', code: 'offline');
    }
    Map<String, dynamic> j = const {};
    try {
      final d = jsonDecode(res.body);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return j;
    final code = j['code']?.toString();
    final server = j['error']?.toString();
    final message = switch (res.statusCode) {
      401 when code == null => 'This version of the app is not authorized on the server. Update SOLIS.',
      429 => server ?? 'Too many attempts. Wait a few minutes and try again.',
      503 => 'Sign-in is not available right now. Try again later.',
      >= 500 => 'The SOLIS server had a problem. Try again.',
      _ => server ?? 'Request failed (${res.statusCode}).',
    };
    throw AuthException(message, code: code, status: res.statusCode);
  }
}

/// The auth client's own backend handle must not ask AuthService for a
/// session (it sends sessions explicitly).
class _NoSessions implements SessionTokens {
  @override
  Future<String?> accessToken() async => null;
  @override
  Future<bool> refreshAfterRejection() async => false;
}
