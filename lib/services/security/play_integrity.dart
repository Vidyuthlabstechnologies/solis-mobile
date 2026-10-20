import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Play Integrity attestation for sign-in and sign-up.
///
/// Each call gets a fresh random nonce. The token is bound to
/// `SHA-256("nonce|request path")` through the Standard API request hash,
/// so it cannot be replayed on another route, and the server accepts each
/// nonce once. No email, password or patient data goes into the hash.
///
/// Off unless the build sets the Google Cloud project number:
/// `--dart-define=SOLIS_GCP_PROJECT_NUMBER=...`. On iOS, without Google Play,
/// or on any error the request simply goes without a token; the server
/// decides what that means (by default it only counts it).
class PlayIntegrity {
  PlayIntegrity._();

  static const tokenHeader = 'X-Solis-Integrity';
  static const nonceHeader = 'X-Solis-Integrity-Nonce';
  static const projectNumber = String.fromEnvironment('SOLIS_GCP_PROJECT_NUMBER');
  static const _channel = MethodChannel('com.solis.clinical/integrity');

  static bool get configured => projectNumber.isNotEmpty && !kIsWeb && Platform.isAndroid;

  /// The request hash for [nonce] on [path], as the server recomputes it.
  static String requestHash(String nonce, String path) => sha256.convert(utf8.encode('$nonce|$path')).toString();

  static String newNonce() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  /// Headers for a request to [path] (for example `/api/v2/auth/login`), or
  /// none when attestation is off or fails.
  static Future<Map<String, String>> headersFor(String path) async {
    if (!configured) return const {};
    final nonce = newNonce();
    try {
      final token = await _channel
          .invokeMethod<String>('requestToken', {'cloudProjectNumber': projectNumber, 'requestHash': requestHash(nonce, path)})
          .timeout(const Duration(seconds: 10));
      if (token == null || token.isEmpty) return const {};
      return {tokenHeader: token, nonceHeader: nonce};
    } catch (e) {
      debugPrint('Play Integrity unavailable: ${e is PlatformException ? e.code : e.runtimeType}');
      return const {};
    }
  }
}
