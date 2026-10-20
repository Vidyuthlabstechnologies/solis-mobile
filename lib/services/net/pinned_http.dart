import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'pinned_roots.dart';

/// TLS pinning for the SOLIS server (the Cloudflare Worker).
///
/// What is pinned: the set of public ROOT CAs that Cloudflare issues edge
/// certificates from (Google Trust Services, Let's Encrypt, SSL.com, Sectigo;
/// see tool/make_tls_pins.ps1). Connections to the SOLIS host trust only those
/// roots instead of every root on the phone, so a certificate from any other
/// CA (a rogue or compromised CA, or a user-installed proxy root used to read
/// traffic) is refused.
///
/// What is not pinned, on purpose: the leaf certificate and the intermediates.
/// Cloudflare rotates both every few months, and a pin on them would cut every
/// installed copy off the server at the next rotation. Root pins survive that,
/// and every pinned root is valid until 2028 or later (most into the 2040s).
///
/// Safety valves: the pins stop being enforced after [enforcedUntil], so an
/// old install that was never updated falls back to the phone's normal trust
/// instead of being bricked; a build can be made without pinning with
/// `--dart-define=SOLIS_TLS_PINNING=off` (for a debugging proxy, never for a
/// release). Other hosts (Deepgram, NPPES, model downloads) use normal trust.
class PinnedHttp {
  PinnedHttp._();

  /// Pins are enforced until this date. Move it forward in each release (and
  /// re-run tool/make_tls_pins.ps1) so it is always a year or more ahead.
  static final DateTime enforcedUntil = DateTime.utc(2028, 6, 1);

  static const _switch = String.fromEnvironment('SOLIS_TLS_PINNING', defaultValue: 'on');

  static bool get enabled => _switch.toLowerCase() != 'off' && DateTime.now().toUtc().isBefore(enforcedUntil);

  static SecurityContext? _context;

  /// A security context that trusts only the pinned roots.
  @visibleForTesting
  static SecurityContext pinnedContext() {
    final c = SecurityContext(withTrustedRoots: false);
    c.setTrustedCertificatesBytes(utf8.encode(pinnedRootsPem));
    return c;
  }

  /// An HTTP client for the SOLIS server: root-pinned when [enabled], else the
  /// platform default. Never accepts a certificate that fails verification.
  static http.Client client() {
    if (!enabled || kIsWeb) return http.Client();
    try {
      final io = HttpClient(context: _context ??= pinnedContext())
        ..connectionTimeout = const Duration(seconds: 20)
        ..badCertificateCallback = (cert, host, port) => false;
      return IOClient(io);
    } catch (e) {
      // Only if the bundled roots could not be parsed, which a test guards.
      debugPrint('TLS pin set unusable (${e.runtimeType}); using platform trust');
      return http.Client();
    }
  }

  /// True for the error a pinned connection raises when the server's chain
  /// does not lead to a pinned root.
  static bool isPinFailure(Object e) => e is HandshakeException || e is TlsException;
}
