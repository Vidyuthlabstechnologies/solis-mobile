import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where front desk mode keeps its state between app starts.
abstract class FrontDeskStore {
  Future<String?> read();
  Future<void> write(String? value);
}

class SecureFrontDeskStore implements FrontDeskStore {
  static const _key = 'solis_front_desk_v1';
  final FlutterSecureStorage _storage;
  const SecureFrontDeskStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String? value) async {
    try {
      value == null ? await _storage.delete(key: _key) : await _storage.write(key: _key, value: value);
    } catch (_) {}
  }
}

class MemoryFrontDeskStore implements FrontDeskStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? v) async => value = v;
}

/// Front desk mode: the clinician hands the phone to staff, who can scan
/// cards and add or correct patient details, but cannot open notes, see
/// billing, or sign or send anything. It is free (no Pro needed) and stays
/// on after the app restarts until the clinician's PIN turns it off.
class FrontDesk extends ChangeNotifier {
  static FrontDesk? _instance;
  static FrontDesk get instance => _instance ??= FrontDesk(SecureFrontDeskStore());
  @visibleForTesting
  static set instance(FrontDesk f) => _instance = f;

  static const minPinLength = 4;
  static const maxTries = 5;
  static const lockout = Duration(seconds: 30);

  final FrontDeskStore _store;
  final DateTime Function() _now;
  FrontDesk(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  bool _on = false;
  String? _salt;
  String? _hash;
  int _wrong = 0;
  DateTime? _lockedUntil;

  bool get isOn => _on;

  /// When too many wrong PINs were entered, how long until the next try.
  Duration? get lockedFor {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(_now());
    return left.isNegative ? null : left;
  }

  Future<void> restore() async {
    final raw = await _store.read();
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _salt = m['salt'] as String?;
      _hash = m['hash'] as String?;
      _on = m['on'] == true && _salt != null && _hash != null;
    } catch (_) {
      _on = false;
    }
    notifyListeners();
  }

  static bool validPin(String pin) => RegExp('^\\d{$minPinLength,8}\$').hasMatch(pin);

  String _digest(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Turns front desk mode on with a new PIN that the clinician chooses.
  Future<void> turnOn(String pin) async {
    if (!validPin(pin)) throw ArgumentError('PIN must be $minPinLength to 8 digits');
    final r = Random.secure();
    _salt = base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
    _hash = _digest(_salt!, pin);
    _on = true;
    _wrong = 0;
    _lockedUntil = null;
    await _store.write(jsonEncode({'on': true, 'salt': _salt, 'hash': _hash}));
    notifyListeners();
  }

  /// Clears front desk mode without the PIN. Only used together with
  /// signing out, so getting back in needs the clinician's password.
  Future<void> resetForSignOut() async {
    _on = false;
    _salt = null;
    _hash = null;
    _wrong = 0;
    _lockedUntil = null;
    await _store.write(null);
    notifyListeners();
  }

  /// Turns front desk mode off when [pin] matches. Returns false on a wrong
  /// PIN or while locked out after [maxTries] wrong PINs.
  Future<bool> turnOff(String pin) async {
    if (!_on) return true;
    if (lockedFor != null) return false;
    if (_salt == null || _hash == null || _digest(_salt!, pin) != _hash) {
      _wrong++;
      if (_wrong >= maxTries) {
        _wrong = 0;
        _lockedUntil = _now().add(lockout);
      }
      notifyListeners();
      return false;
    }
    _on = false;
    _salt = null;
    _hash = null;
    _wrong = 0;
    _lockedUntil = null;
    await _store.write(null);
    notifyListeners();
    return true;
  }
}
