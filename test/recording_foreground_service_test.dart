import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/services/recording_foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = RecordingForegroundService.channel;
  final calls = <String>[];

  void mock(Object? Function(MethodCall call) answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return answer(call);
    });
  }

  setUp(calls.clear);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('start and stop go to the Android service', () async {
    mock((_) => true);
    expect(await RecordingForegroundService.start(), isTrue);
    await RecordingForegroundService.stop();
    expect(calls, ['start', 'stop']);
  });

  test('a service that cannot start reports false so the caller keeps the wake lock', () async {
    mock((c) => c.method == 'start' ? false : true);
    expect(await RecordingForegroundService.start(), isFalse);
  });

  test('platform errors never escape', () async {
    mock((_) => throw PlatformException(code: 'boom'));
    expect(await RecordingForegroundService.start(), isFalse);
    await RecordingForegroundService.stop();
    expect(await RecordingForegroundService.ensureNotificationPermission(), isFalse);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await RecordingForegroundService.start(), isFalse, reason: 'no plugin registered');
  });

  test('notification permission: granted, denied', () async {
    mock((_) => true);
    expect(await RecordingForegroundService.ensureNotificationPermission(), isTrue);
    mock((_) => false);
    expect(await RecordingForegroundService.ensureNotificationPermission(), isFalse);
    expect(calls, ['requestNotificationPermission', 'requestNotificationPermission']);
  });

  test('Stop in the notification reaches Flutter', () async {
    mock((_) => true);
    var stops = 0;
    final sub = RecordingForegroundService.stopRequests.listen((_) => stops++);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('stopRequested')),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(stops, 1);
    await sub.cancel();
  });

  test('no-op on iOS: nothing is sent to the platform', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    mock((_) => true);
    expect(await RecordingForegroundService.start(), isFalse);
    await RecordingForegroundService.stop();
    expect(await RecordingForegroundService.ensureNotificationPermission(), isTrue);
    expect(calls, isEmpty);
  });
}
