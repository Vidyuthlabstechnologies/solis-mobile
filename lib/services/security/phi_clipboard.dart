import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copies text that may hold patient data and clears the clipboard after
/// [clearAfter], unless something else was copied in the meantime. Other
/// apps (keyboards, clipboard managers) can read the clipboard, so patient
/// data should not stay there after it was pasted.
class PhiClipboard {
  PhiClipboard._();

  static const clearAfter = Duration(seconds: 60);

  static Timer? _timer;

  /// Test hook: the delay before clearing.
  @visibleForTesting
  static Duration? clearAfterOverride;

  static Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _timer?.cancel();
    _timer = Timer(clearAfterOverride ?? clearAfter, () => clearIfStill(text));
  }

  /// Clears the clipboard if it still holds [text].
  static Future<void> clearIfStill(String text) async {
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (e) {
      debugPrint('Clipboard not cleared: $e');
    }
  }
}
