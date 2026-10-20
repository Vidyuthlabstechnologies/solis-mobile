import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'x12_837p.dart';

/// Key-value store for secrets. Values never leave this interface in logs.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore / iOS Keychain backed store.
class SecureSecretStore implements SecretStore {
  final FlutterSecureStorage _storage;

  SecureSecretStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store for tests and previews.
class MemorySecretStore implements SecretStore {
  final Map<String, String> _values;

  MemorySecretStore([Map<String, String>? initial]) : _values = {...?initial};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  String toString() => 'MemorySecretStore(${_values.length} entries)';
}

/// API keys and claim submitter settings. Listen to it from settings and
/// billing screens; call [load] once at startup.
class IntegrationSettings extends ChangeNotifier {
  static const stediApiKeyKey = 'stedi_api_key';
  static const deepgramApiKeyKey = 'deepgram_api_key';
  static const submitterConfigKey = 'submitter_config';
  static const controlNumberKey = 'x12_control_number';

  final SecretStore _store;
  String? _stediKey;
  String? _deepgramKey;
  SubmitterConfig? _submitter;
  bool _loaded = false;

  IntegrationSettings({SecretStore? store}) : _store = store ?? SecureSecretStore();

  /// Settings backed by memory only.
  factory IntegrationSettings.inMemory([Map<String, String>? initial]) =>
      IntegrationSettings(store: MemorySecretStore(initial));

  bool get isLoaded => _loaded;

  bool get hasStediApiKey => (_stediKey ?? '').isNotEmpty;
  bool get hasDeepgramApiKey => (_deepgramKey ?? '').isNotEmpty;
  bool get hasSubmitterConfig => _submitter?.isComplete ?? false;

  /// Ready to send claims: a Stedi key and a complete envelope.
  bool get isClaimsConfigured => hasStediApiKey && hasSubmitterConfig;

  /// Ready for eligibility and claim status checks.
  bool get isEligibilityConfigured => hasStediApiKey;

  bool get isTranscriptionConfigured => hasDeepgramApiKey;

  String? get stediApiKey => _stediKey;
  String? get deepgramApiKey => _deepgramKey;
  SubmitterConfig? get submitterConfig => _submitter;

  /// Last four characters only, for display.
  String get stediKeyHint => maskSecret(_stediKey);
  String get deepgramKeyHint => maskSecret(_deepgramKey);

  static String maskSecret(String? s) {
    if (s == null || s.isEmpty) return 'Not set';
    if (s.length <= 4) return '....';
    return '....${s.substring(s.length - 4)}';
  }

  Future<void> load() async {
    _stediKey = _blankToNull(await _safeRead(stediApiKeyKey));
    _deepgramKey = _blankToNull(await _safeRead(deepgramApiKeyKey));
    final raw = await _safeRead(submitterConfigKey);
    _submitter = null;
    if (raw != null && raw.isNotEmpty) {
      try {
        _submitter = SubmitterConfig.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
      } catch (_) {
        _submitter = null;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setStediApiKey(String? key) async {
    _stediKey = await _writeSecret(stediApiKeyKey, key);
    notifyListeners();
  }

  Future<void> setDeepgramApiKey(String? key) async {
    _deepgramKey = await _writeSecret(deepgramApiKeyKey, key);
    notifyListeners();
  }

  Future<void> setSubmitterConfig(SubmitterConfig? config) async {
    if (config == null) {
      await _store.delete(submitterConfigKey);
    } else {
      await _store.write(submitterConfigKey, jsonEncode(config.toJson()));
    }
    _submitter = config;
    notifyListeners();
  }

  /// Returns the next unique interchange control number (1..999999999) and
  /// persists it, so every file sent carries a new ISA13.
  Future<int> nextControlNumber() async {
    final current = int.tryParse(await _safeRead(controlNumberKey) ?? '') ?? 0;
    final next = current >= 999999999 ? 1 : current + 1;
    await _store.write(controlNumberKey, '$next');
    return next;
  }

  /// Submitter config with fresh control numbers, or null when not configured.
  Future<SubmitterConfig?> submitterConfigForNextClaim() async {
    final c = _submitter;
    if (c == null || !c.isComplete) return null;
    return c.withControlNumber(await nextControlNumber());
  }

  Future<void> clearAll() async {
    for (final k in [stediApiKeyKey, deepgramApiKeyKey, submitterConfigKey]) {
      await _store.delete(k);
    }
    _stediKey = null;
    _deepgramKey = null;
    _submitter = null;
    notifyListeners();
  }

  Future<String?> _writeSecret(String key, String? value) async {
    final v = _blankToNull(value?.trim());
    if (v == null) {
      await _store.delete(key);
    } else {
      await _store.write(key, v);
    }
    return v;
  }

  Future<String?> _safeRead(String key) async {
    try {
      return await _store.read(key);
    } catch (_) {
      // Keystore can fail after a backup restore; treat as not set.
      return null;
    }
  }

  static String? _blankToNull(String? s) => (s == null || s.isEmpty) ? null : s;

  @override
  String toString() => 'IntegrationSettings(stedi: ${hasStediApiKey ? 'set' : 'missing'}, '
      'deepgram: ${hasDeepgramApiKey ? 'set' : 'missing'}, submitter: ${hasSubmitterConfig ? 'set' : 'missing'})';
}
