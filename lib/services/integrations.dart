import 'package:flutter/foundation.dart';

import 'billing/clearinghouse.dart';
import 'billing/integration_settings.dart';
import 'billing/stedi_client.dart';
import 'solis_backend.dart';

/// App-wide access to configured integrations. Keys live in the Android
/// Keystore-backed secure storage (never in the APK or in plain files).
class Integrations {
  Integrations._();

  static IntegrationSettings? _settings;

  /// Loaded once at startup; tests may replace it.
  static IntegrationSettings get settings => _settings ??= IntegrationSettings.inMemory();

  @visibleForTesting
  static set settings(IntegrationSettings s) => _settings = s;

  /// Test hook: a client to use instead of building one from the key.
  @visibleForTesting
  static ClearinghouseClient? clearinghouseOverride;

  static Future<void> init() async {
    final s = IntegrationSettings();
    try {
      await s.load();
    } catch (e) {
      debugPrint('Integration settings could not be loaded: $e');
    }
    _settings = s;
  }

  /// The clearinghouse client, otherwise null. A Stedi key entered on this
  /// phone (for testing) wins; otherwise claims go through the SOLIS server,
  /// which holds the key.
  static ClearinghouseClient? clearinghouse() {
    if (clearinghouseOverride != null) return clearinghouseOverride;
    final key = settings.stediApiKey;
    if (key != null && key.isNotEmpty) return StediClient(apiKey: key);
    final backend = SolisBackend.instance;
    if (backend.isConfigured) return StediClient.viaBackend(backend);
    return null;
  }
}
