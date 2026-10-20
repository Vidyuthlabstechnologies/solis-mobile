import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android microphone foreground service for a visit recording
/// (RecordingService.kt). While it runs, Android keeps the microphone open
/// with the screen off or another app in front, an ongoing notification says
/// "SOLIS is recording this visit", and the service holds the wake lock.
///
/// Every call is a no-op on iOS and other platforms, and never throws: if the
/// service cannot start (for example notifications denied on Android 13+ do
/// not stop it, but a missing microphone grant does), recording still works
/// while SOLIS is in the foreground.
class RecordingForegroundService {
  RecordingForegroundService._();

  static const MethodChannel channel = MethodChannel('com.solis.clinical/recording');

  static final StreamController<void> _stopRequests = StreamController<void>.broadcast();
  static bool _handlerSet = false;

  /// Fires when Stop is pressed in the recording notification.
  static Stream<void> get stopRequests {
    _ensureHandler();
    return _stopRequests.stream;
  }

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void _ensureHandler() {
    if (_handlerSet || !_supported) return;
    _handlerSet = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') _stopRequests.add(null);
      return null;
    });
  }

  /// On Android 13+ asks for the notification permission once (before the
  /// first recording). True when notifications can be shown. A denial is
  /// fine: the service still runs, Android just hides its notification
  /// from the shade (it stays in the task manager).
  static Future<bool> ensureNotificationPermission() async {
    if (!_supported) return true;
    try {
      return await channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
    } catch (e) {
      debugPrint('Notification permission request failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Starts the service. True when it was started, false otherwise (the
  /// caller then keeps the wake lock itself).
  static Future<bool> start() async {
    if (!_supported) return false;
    _ensureHandler();
    try {
      return await channel.invokeMethod<bool>('start') ?? false;
    } catch (e) {
      debugPrint('Recording service start failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Stops the service (and its notification and wake lock). Safe to call
  /// when it is not running.
  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await channel.invokeMethod<bool>('stop');
    } catch (e) {
      debugPrint('Recording service stop failed: ${e.runtimeType}');
    }
  }

  /// Lets tests start again from a clean state.
  @visibleForTesting
  static void resetForTest() {
    _handlerSet = false;
  }
}
