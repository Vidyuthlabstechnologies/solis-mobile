import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// The light/dark choice. A new install follows the phone's setting; once
/// the clinician picks light or dark, that choice is kept across restarts.
class ThemePreference {
  ThemePreference._(this._file, this.mode);

  /// In memory only, for tests and previews.
  ThemePreference.memory([this.mode = ThemeMode.system]) : _file = null;

  final File? _file;
  ThemeMode mode;

  static const fileName = 'solis_theme.txt';

  static ThemeMode parse(String? s) => switch (s?.trim()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// Reads the saved choice from [directory] (the app support directory by
  /// default). Any failure means "follow the system".
  static Future<ThemePreference> load({Directory? directory}) async {
    try {
      final dir = directory ?? await getApplicationSupportDirectory();
      final f = File('${dir.path}/$fileName');
      final saved = await f.exists() ? await f.readAsString() : null;
      return ThemePreference._(f, parse(saved));
    } catch (_) {
      return ThemePreference.memory();
    }
  }

  /// Whether the app draws dark, given the phone's current [platform] brightness.
  bool isDark(Brightness platform) => switch (mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system => platform == Brightness.dark,
      };

  Future<void> set(ThemeMode m) async {
    mode = m;
    final f = _file;
    if (f == null) return;
    try {
      await f.writeAsString(m.name, flush: true);
    } catch (e) {
      debugPrint('Theme choice not saved: $e');
    }
  }
}
