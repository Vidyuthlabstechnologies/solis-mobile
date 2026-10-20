import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/services/transcription/engine_selector.dart';
import 'package:solis_mobile/services/transcription/model_manager.dart';
import 'package:solis_mobile/services/transcription/native_speech_provider.dart';
import 'package:solis_mobile/services/transcription/transcription_provider.dart';

// -----------------------------------------------------------------------------
// Fakes
// -----------------------------------------------------------------------------

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

class FakePlatform implements ModelPlatform {
  final Directory dir;

  /// What each archive (by its file name) "contains": entry path to bytes.
  final Map<String, Map<String, List<int>>> archives;
  int extractCalls = 0;
  int? free;

  FakePlatform(this.dir, {this.archives = const {}, this.free});

  @override
  Future<String> modelRoot() async => dir.path;

  @override
  Future<String?> sha256(String path) => dartSha256(path);

  @override
  Future<Map<String, FileDigest>> extract(String archive, String destDir, Map<String, String> entries) async {
    extractCalls++;
    final name = archive.split(Platform.pathSeparator).last;
    final contents = archives.entries.firstWhere((e) => name.startsWith(e.key)).value;
    final out = <String, FileDigest>{};
    for (final e in entries.entries) {
      final bytes = contents[e.key];
      if (bytes == null) throw Exception('missing ${e.key}');
      final f = File('$destDir${Platform.pathSeparator}${e.value}');
      await f.writeAsBytes(bytes);
      out[e.value] = FileDigest(path: f.path, size: bytes.length, sha256: _sha(bytes));
    }
    return out;
  }

  @override
  Future<int?> freeBytes() async => free;

  @override
  Stream<(int, int)> get extractProgress => const Stream.empty();
}

/// Serves bytes from memory. [responses] are consumed in order per URL; when
/// exhausted the last one repeats.
class FakeDownloader implements ModelDownloader {
  final Map<Uri, List<List<int>>> responses;
  final List<(Uri, int)> calls = [];
  bool supportRange;

  /// Cut the body after this many bytes on the first request (simulates a drop).
  int? dropAfter;

  FakeDownloader(this.responses, {this.supportRange = true, this.dropAfter});

  @override
  Future<ModelDownloadResponse> open(Uri url, {int fromByte = 0}) async {
    calls.add((url, fromByte));
    final list = responses[url]!;
    final body = list.length > 1 ? list.removeAt(0) : list.first;
    if (fromByte > 0 && supportRange) {
      return ModelDownloadResponse(statusCode: 206, body: Stream.value(body.sublist(fromByte)));
    }
    final drop = dropAfter;
    if (drop != null) {
      dropAfter = null;
      final ctrl = StreamController<List<int>>();
      ctrl.add(body.sublist(0, drop));
      ctrl.addError(const SocketException('connection reset'));
      unawaited(ctrl.close());
      return ModelDownloadResponse(statusCode: 200, body: ctrl.stream);
    }
    return ModelDownloadResponse(statusCode: 200, body: Stream.value(body));
  }
}

SpeechModelSource _direct(String id, List<int> bytes, {String? sha}) => SpeechModelSource(
      id: id,
      url: Uri.parse('https://example.test/$id.onnx'),
      size: bytes.length,
      sha256: sha ?? _sha(bytes),
      license: 'test',
      file: SpeechModelFile('$id.onnx', bytes.length, sha ?? _sha(bytes)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Segment mapping
  // ---------------------------------------------------------------------------

  group('segment mapping', () {
    test('native map becomes DiarizedSegment', () {
      final s = diarizedSegmentFromNative({'id': 3, 'speakerIndex': 1, 'text': '  I have chest pain. ', 'start': 1.5, 'end': 3, 'isFinal': true});
      expect(s.speakerIndex, 1);
      expect(s.text, 'I have chest pain.');
      expect(s.start, 1.5);
      expect(s.end, 3.0);
      expect(s.isFinal, isTrue);
    });

    test('missing fields fall back safely', () {
      final s = diarizedSegmentFromNative({'text': 'Hello'});
      expect(s.speakerIndex, 0);
      expect(s.start, 0);
      expect(s.isFinal, isTrue);
    });

    test('consecutive same-voice segments merge into one turn', () {
      final merged = mergeTurns(const [
        DiarizedSegment(speakerIndex: 0, text: 'How are you?', start: 0, end: 1, isFinal: true),
        DiarizedSegment(speakerIndex: 0, text: 'Any fever?', start: 1.2, end: 2, isFinal: true),
        DiarizedSegment(speakerIndex: 1, text: 'No.', start: 2.5, end: 3, isFinal: true),
        DiarizedSegment(speakerIndex: 1, text: '', start: 3, end: 3.1, isFinal: true),
      ]);
      expect(merged.length, 2);
      expect(merged.first.text, 'How are you? Any fever?');
      expect(merged.first.end, 2);
    });

    test('register leaves the on-device engine off where it cannot run', () async {
      SpeechEngines.onDeviceFactory = ({bool noiseSuppression = true}) => null;
      final a = await NativeSpeechProvider.register();
      // The test host is not Android.
      expect(a.supported, isFalse);
      expect(a.canStart, isFalse);
      expect(SpeechEngines.onDeviceFactory, isNull);
    });

    test('native status strings map to TranscriptionStatus', () {
      expect(nativeStatusToTranscription('loading'), TranscriptionStatus.connecting);
      expect(nativeStatusToTranscription('listening'), TranscriptionStatus.listening);
      expect(nativeStatusToTranscription('behind'), TranscriptionStatus.listening);
      expect(nativeStatusToTranscription('paused'), TranscriptionStatus.paused);
      expect(nativeStatusToTranscription('finalizing'), TranscriptionStatus.closing);
      expect(nativeStatusToTranscription('stopped'), TranscriptionStatus.stopped);
      expect(nativeStatusToTranscription('failed'), TranscriptionStatus.failed);
      expect(nativeStatusToTranscription('nonsense'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Provider with fake channels
  // ---------------------------------------------------------------------------

  group('NativeSpeechProvider', () {
    late Directory tmp;
    late StreamController<dynamic> events;
    late List<MethodCall> calls;
    late ModelManager models;
    const channel = MethodChannel('test/native_speech');
    Map<String, dynamic>? stopPayload;

    Future<void> installModels() async {
      // A one-file bundle so isReady() is true without the real catalog.
      final bytes = utf8.encode('model');
      final src = _direct('m', bytes);
      final bundle = SpeechModelBundle(SpeechModelSet.compact, [src], {
        'vad': 'm.onnx',
        'encoder': 'm.onnx',
        'decoder': 'm.onnx',
        'tokens': 'm.onnx',
        'segmentation': 'm.onnx',
        'embedding': 'm.onnx',
      });
      models = ModelManager(
        bundle: bundle,
        platform: FakePlatform(tmp),
        downloader: FakeDownloader({src.url: [bytes]}),
        retryDelay: Duration.zero,
      );
      final last = await models.prepare().last;
      expect(last.stage, ModelPrepareStage.ready);
    }

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('native_speech_test');
      events = StreamController<dynamic>.broadcast();
      calls = [];
      stopPayload = null;
      await installModels();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'start':
            // The engine emits a status before start() returns its id.
            events.add({'type': 'status', 'sessionId': 7, 'status': 'loading'});
            await Future<void>.delayed(Duration.zero);
            return {'sessionId': 7};
          case 'pause':
          case 'resume':
            return true;
          case 'stop':
            return stopPayload ?? {'segments': [], 'method': 'none', 'numSpeakers': 0, 'durationSec': 0.0};
          case 'cancel':
            return null;
        }
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await events.close();
      await _deleteQuietly(tmp);
    });

    Map<String, dynamic> seg(int id, int speaker, String text, double start, double end) =>
        {'id': id, 'speakerIndex': speaker, 'text': text, 'start': start, 'end': end, 'isFinal': true};

    test('passes model paths and options to start', () async {
      final p = NativeSpeechProvider(
        models: models,
        options: const NativeSpeechOptions(numSpeakers: 2),
        methodChannel: channel,
        eventStream: events.stream,
      );
      final updates = <TranscriptUpdate>[];
      p.start().listen(updates.add);
      await untilStarted(p);
      final start = calls.firstWhere((c) => c.method == 'start');
      final args = Map<String, dynamic>.from(start.arguments as Map);
      expect(args['numSpeakers'], 2);
      final paths = Map<String, dynamic>.from(args['models'] as Map);
      expect(paths.keys, containsAll(['vad', 'encoder', 'decoder', 'tokens', 'segmentation', 'embedding']));
      expect(paths['vad'], endsWith('m.onnx'));
      // The early "loading" status was replayed once the id was known.
      expect(updates.map((u) => u.status), contains(TranscriptionStatus.connecting));
      await p.stop();
    });

    test('live segments get Doctor and Patient labels; partial shows as interim', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      final updates = <TranscriptUpdate>[];
      p.start().listen(updates.add);
      await untilStarted(p);
      events
        ..add({'type': 'status', 'sessionId': 7, 'status': 'listening'})
        ..add({'type': 'segment', 'sessionId': 7, 'segment': seg(0, 0, 'What brings you in today? Any chest pain?', 0.2, 2.5)})
        ..add({'type': 'segment', 'sessionId': 7, 'segment': seg(1, 1, 'I have had chest pain since yesterday.', 3.0, 5.0)})
        ..add({'type': 'partial', 'sessionId': 7, 'text': 'It hurts when I', 'start': 5.5, 'end': 6.5, 'speakerIndex': 1});
      await pumpEventQueue();

      final u = updates.last;
      expect(u.status, TranscriptionStatus.listening);
      expect(u.transcript, 'Doctor: What brings you in today? Any chest pain?\nPatient: I have had chest pain since yesterday.');
      expect(u.interim, 'It hurts when I');
      expect(u.roles, {0: 'Doctor', 1: 'Patient'});
      expect(u.finalSegments.length, 2);
      expect(u.interimSegments.single.speakerIndex, 1);
      await p.stop();
    });

    test('events from another session are ignored', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      p.start().listen((_) {});
      await untilStarted(p);
      events.add({'type': 'segment', 'sessionId': 6, 'segment': seg(0, 0, 'Old session text.', 0, 1)});
      await pumpEventQueue();
      expect(p.rawSegments, isEmpty);
      await p.stop();
    });

    test('stop applies the final diarization pass and returns the labeled transcript', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      final updates = <TranscriptUpdate>[];
      final done = Completer<void>();
      p.start().listen(updates.add, onDone: done.complete);
      await untilStarted(p);
      // Live: one utterance held both voices.
      events.add({'type': 'segment', 'sessionId': 7, 'segment': seg(0, 0, 'Any allergies? No, none that I know of.', 0, 4)});
      await pumpEventQueue();
      // Final pass split it.
      stopPayload = {
        'segments': [seg(0, 0, 'Any allergies?', 0, 1.4), seg(1, 1, 'No, none that I know of.', 1.6, 4)],
        'method': 'pyannote',
        'numSpeakers': 2,
        'durationSec': 4.2,
      };
      events.add({'type': 'status', 'sessionId': 7, 'status': 'finalizing', 'progress': 0.5});
      await pumpEventQueue();
      expect(p.finalizingProgress, 0.5);
      expect(updates.last.status, TranscriptionStatus.closing);

      final text = await p.stop();
      await done.future;
      expect(text, 'Doctor: Any allergies?\nPatient: No, none that I know of.');
      expect(p.diarizationMethod, 'pyannote');
      expect(updates.last.status, TranscriptionStatus.stopped);
      expect(updates.last.interim, isEmpty);
    });

    test('empty final list keeps the live segments', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      p.start().listen((_) {});
      await untilStarted(p);
      events.add({'type': 'segment', 'sessionId': 7, 'segment': seg(0, 0, 'Please take a deep breath.', 0, 2)});
      await pumpEventQueue();
      final text = await p.stop();
      expect(text, 'Doctor: Please take a deep breath.');
    });

    test('fatal engine error sets failed status and keeps the stream open until stop', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      final updates = <TranscriptUpdate>[];
      var closed = false;
      p.start().listen(updates.add, onDone: () => closed = true);
      await untilStarted(p);
      events.add({'type': 'error', 'sessionId': 7, 'code': 'mic_busy', 'message': 'Another app is using the microphone.', 'fatal': true});
      await pumpEventQueue();
      expect(updates.last.status, TranscriptionStatus.failed);
      expect(updates.last.error, 'Another app is using the microphone.');
      // Later status events do not hide the failure.
      events.add({'type': 'status', 'sessionId': 7, 'status': 'listening'});
      await pumpEventQueue();
      expect(updates.last.status, TranscriptionStatus.failed);
      expect(closed, isFalse);
      await p.stop();
      expect(closed, isTrue);
    });

    test('non-fatal error is reported without changing status', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      final updates = <TranscriptUpdate>[];
      p.start().listen(updates.add);
      await untilStarted(p);
      events
        ..add({'type': 'status', 'sessionId': 7, 'status': 'listening'})
        ..add({'type': 'error', 'sessionId': 7, 'code': 'diarization_failed', 'message': 'Full speaker pass failed', 'fatal': false});
      await pumpEventQueue();
      expect(updates.last.status, TranscriptionStatus.listening);
      expect(updates.last.error, 'Full speaker pass failed');
      await p.stop();
    });

    test('engine start failure is reported as failed', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') throw PlatformException(code: 'unsupported', message: 'Not available on x86_64');
        return null;
      });
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      final updates = <TranscriptUpdate>[];
      p.start().listen(updates.add);
      await untilStarted(p);
      expect(updates.last.status, TranscriptionStatus.failed);
      expect(updates.last.error, 'Not available on x86_64');
      expect(await p.stop(), isEmpty);
    });

    test('pause and resume reach the engine; paused status maps', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      final updates = <TranscriptUpdate>[];
      p.start().listen(updates.add);
      await untilStarted(p);
      await p.pause();
      events.add({'type': 'status', 'sessionId': 7, 'status': 'paused'});
      await pumpEventQueue();
      expect(updates.last.status, TranscriptionStatus.paused);
      await p.resume();
      expect(calls.map((c) => c.method), containsAllInOrder(['start', 'pause', 'resume']));
      await p.stop();
    });

    test('role override swaps labels', () async {
      final p = NativeSpeechProvider(models: models, methodChannel: channel, eventStream: events.stream);
      p.start().listen((_) {});
      await untilStarted(p);
      events
        ..add({'type': 'segment', 'sessionId': 7, 'segment': seg(0, 0, 'Do you smoke?', 0, 1)})
        ..add({'type': 'segment', 'sessionId': 7, 'segment': seg(1, 1, 'I quit last year.', 1.5, 3)});
      await pumpEventQueue();
      p.setRole(0, 'Patient');
      p.setRole(1, 'Doctor');
      expect(p.transcript, 'Patient: Do you smoke?\nDoctor: I quit last year.');
      await p.stop();
    });
  });

  // ---------------------------------------------------------------------------
  // Model manager
  // ---------------------------------------------------------------------------

  group('ModelManager', () {
    late Directory tmp;

    setUp(() async => tmp = await Directory.systemTemp.createTemp('model_manager_test'));
    tearDown(() async => _deleteQuietly(tmp));

    SpeechModelBundle bundleOf(List<SpeechModelSource> sources) => SpeechModelBundle(SpeechModelSet.compact, sources, {
          for (final r in ['vad', 'encoder', 'decoder', 'tokens', 'segmentation', 'embedding']) r: sources.first.outputs.first.fileName,
        });

    test('downloads, verifies and records a direct file', () async {
      final bytes = List<int>.generate(5000, (i) => i % 251);
      final src = _direct('vad', bytes);
      final dl = FakeDownloader({src.url: [bytes]});
      final m = ModelManager(bundle: bundleOf([src]), platform: FakePlatform(tmp), downloader: dl, retryDelay: Duration.zero);
      expect(await m.isReady(), isFalse);
      expect(await m.remainingDownloadBytes(), 5000);
      final progress = await m.prepare().toList();
      expect(progress.last.stage, ModelPrepareStage.ready);
      expect(progress.last.fraction, 1.0);
      expect(progress.any((p) => p.stage == ModelPrepareStage.verifying), isTrue);
      expect(await m.isReady(), isTrue);
      expect(await File('${tmp.path}${Platform.pathSeparator}vad.onnx').readAsBytes(), bytes);
      final manifest = jsonDecode(await File('${tmp.path}${Platform.pathSeparator}verified.json').readAsString());
      expect(manifest['vad.onnx'], _sha(bytes));
      // Second run downloads nothing.
      await m.prepare().last;
      expect(dl.calls.length, 1);
    });

    test('checksum mismatch is retried, then succeeds', () async {
      final good = utf8.encode('the real model bytes');
      final bad = utf8.encode('the fake model bytes'); // same length, wrong content
      final src = _direct('emb', good);
      final dl = FakeDownloader({src.url: [bad, good]});
      final m = ModelManager(bundle: bundleOf([src]), platform: FakePlatform(tmp), downloader: dl, retryDelay: Duration.zero);
      final progress = await m.prepare().toList();
      expect(progress.last.stage, ModelPrepareStage.ready);
      expect(progress.any((p) => p.attempt == 2 && p.error != null && p.error!.contains('Checksum mismatch')), isTrue);
      expect(dl.calls.length, 2);
      expect(await m.isReady(), isTrue);
    });

    test('persistent checksum mismatch fails without installing the file', () async {
      final good = utf8.encode('expected');
      final src = _direct('asr', good);
      final dl = FakeDownloader({src.url: [utf8.encode('tampered')]});
      final m = ModelManager(bundle: bundleOf([src]), platform: FakePlatform(tmp), downloader: dl, maxAttempts: 3, retryDelay: Duration.zero);
      final progress = await m.prepare().toList();
      expect(progress.last.stage, ModelPrepareStage.failed);
      expect(progress.last.error, contains('after 3 attempts'));
      expect(dl.calls.length, 3);
      expect(await m.isReady(), isFalse);
      expect(await File('${tmp.path}${Platform.pathSeparator}asr.onnx').exists(), isFalse);
    });

    test('a dropped connection resumes with a Range request', () async {
      final bytes = List<int>.generate(10000, (i) => (i * 7) % 256);
      final src = _direct('big', bytes);
      final dl = FakeDownloader({src.url: [bytes]}, dropAfter: 4000);
      final m = ModelManager(bundle: bundleOf([src]), platform: FakePlatform(tmp), downloader: dl, retryDelay: Duration.zero);
      final last = await m.prepare().last;
      expect(last.stage, ModelPrepareStage.ready);
      expect(dl.calls.map((c) => c.$2).toList(), [0, 4000]);
      expect(await File('${tmp.path}${Platform.pathSeparator}big.onnx').readAsBytes(), bytes);
    });

    test('server that ignores Range restarts from zero', () async {
      final bytes = List<int>.generate(3000, (i) => i % 200);
      final src = _direct('norange', bytes);
      // Leave a partial download behind.
      await File('${tmp.path}${Platform.pathSeparator}norange.download').writeAsBytes(bytes.sublist(0, 1000));
      final dl = FakeDownloader({src.url: [bytes]}, supportRange: false);
      final m = ModelManager(bundle: bundleOf([src]), platform: FakePlatform(tmp), downloader: dl, retryDelay: Duration.zero);
      expect((await m.prepare().last).stage, ModelPrepareStage.ready);
      expect(dl.calls.single.$2, 1000);
      expect(await File('${tmp.path}${Platform.pathSeparator}norange.onnx').readAsBytes(), bytes);
    });

    test('archives are verified, unpacked and checked per file', () async {
      final archiveBytes = utf8.encode('pretend this is a tar.bz2');
      final encoder = utf8.encode('encoder weights');
      final tokens = utf8.encode('tokens');
      final src = SpeechModelSource(
        id: 'asr-archive',
        url: Uri.parse('https://example.test/asr.tar.bz2'),
        size: archiveBytes.length,
        sha256: _sha(archiveBytes),
        license: 'test',
        archiveEntries: {
          'pkg/encoder.ort': SpeechModelFile('enc.ort', encoder.length, _sha(encoder)),
          'pkg/tokens.txt': SpeechModelFile('tok.txt', tokens.length, _sha(tokens)),
        },
      );
      final platform = FakePlatform(tmp, archives: {
        'asr-archive': {'pkg/encoder.ort': encoder, 'pkg/tokens.txt': tokens},
      });
      final m = ModelManager(
        bundle: bundleOf([src]),
        platform: platform,
        downloader: FakeDownloader({src.url: [archiveBytes]}),
        retryDelay: Duration.zero,
      );
      final progress = await m.prepare().toList();
      expect(progress.last.stage, ModelPrepareStage.ready, reason: progress.last.error);
      expect(progress.any((p) => p.stage == ModelPrepareStage.extracting), isTrue);
      expect(platform.extractCalls, 1);
      expect(await m.isReady(), isTrue);
      // The archive itself is removed after unpacking.
      expect(await File('${tmp.path}${Platform.pathSeparator}asr-archive.download').exists(), isFalse);
    });

    test('unpacked file with the wrong checksum fails', () async {
      final archiveBytes = utf8.encode('archive');
      final src = SpeechModelSource(
        id: 'bad-archive',
        url: Uri.parse('https://example.test/bad.tar.bz2'),
        size: archiveBytes.length,
        sha256: _sha(archiveBytes),
        license: 'test',
        archiveEntries: {'pkg/model.ort': SpeechModelFile('model.ort', 5, _sha(utf8.encode('right')))},
      );
      final platform = FakePlatform(tmp, archives: {
        'bad-archive': {'pkg/model.ort': utf8.encode('wrong')},
      });
      final m = ModelManager(
        bundle: bundleOf([src]),
        platform: platform,
        downloader: FakeDownloader({src.url: [archiveBytes]}),
        maxAttempts: 2,
        retryDelay: Duration.zero,
      );
      final last = await m.prepare().last;
      expect(last.stage, ModelPrepareStage.failed);
      expect(last.error, contains('does not match'));
      expect(await File('${tmp.path}${Platform.pathSeparator}model.ort').exists(), isFalse);
    });

    test('a file corrupted after install is no longer ready', () async {
      final bytes = utf8.encode('stable model');
      final src = _direct('vad', bytes);
      final m = ModelManager(
          bundle: bundleOf([src]), platform: FakePlatform(tmp), downloader: FakeDownloader({src.url: [bytes]}), retryDelay: Duration.zero);
      await m.prepare().last;
      expect(await m.isReady(), isTrue);
      await File('${tmp.path}${Platform.pathSeparator}vad.onnx').writeAsBytes(utf8.encode('truncated'));
      expect(await m.isReady(), isFalse);
      await m.delete();
      expect(await File('${tmp.path}${Platform.pathSeparator}vad.onnx').exists(), isFalse);
    });

    test('refuses to start without enough free space', () async {
      final bytes = utf8.encode('x' * 100);
      final src = _direct('vad', bytes);
      final m = ModelManager(
        bundle: bundleOf([src]),
        platform: FakePlatform(tmp, free: 1000),
        downloader: FakeDownloader({src.url: [bytes]}),
        retryDelay: Duration.zero,
      );
      final last = await m.prepare().last;
      expect(last.stage, ModelPrepareStage.failed);
      expect(last.error, contains('Not enough storage'));
    });

    test('real catalog is pinned, HTTPS, and within the size budget', () {
      final hex = RegExp(r'^[0-9a-f]{64}$');
      for (final set in SpeechModelSet.values) {
        final b = SpeechModelCatalog.bundle(set);
        expect(b.downloadBytes, lessThan(150 * 1000 * 1000), reason: '$set download');
        for (final s in b.sources) {
          expect(s.url.scheme, 'https');
          expect(s.url.host, 'github.com');
          expect(hex.hasMatch(s.sha256), isTrue, reason: s.id);
          for (final f in s.outputs) {
            expect(hex.hasMatch(f.sha256), isTrue, reason: f.fileName);
            expect(f.size, greaterThan(0));
          }
        }
        final files = b.files.map((f) => f.fileName).toSet();
        for (final role in ['vad', 'encoder', 'decoder', 'tokens', 'segmentation', 'embedding']) {
          expect(files, contains(b.roleFiles[role]), reason: '$set $role');
        }
      }
      expect(SpeechModelCatalog.bundle(SpeechModelSet.compact).downloadBytes, 67057835);
      expect(SpeechModelCatalog.bundle(SpeechModelSet.standard).downloadBytes, 148465501);
    });

    test('HTTP downloader refuses plain HTTP', () async {
      expect(() => HttpModelDownloader().open(Uri.parse('http://example.test/x')), throwsArgumentError);
    });
  });
}

/// Windows can still hold a file in the temp folder for a moment after a
/// test; a leftover temp folder is not a test failure.
Future<void> _deleteQuietly(Directory dir) async {
  for (var i = 0; i < 5; i++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

/// start() reads the model files from disk before asking the engine for a
/// session, and real I/O is not driven by pumpEventQueue. Wait until the
/// session id is known so later events are applied in order.
Future<void> untilStarted(NativeSpeechProvider p) async {
  for (var i = 0; i < 200 && p.sessionIdForTest == null && p.status != TranscriptionStatus.failed; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await pumpEventQueue();
}
