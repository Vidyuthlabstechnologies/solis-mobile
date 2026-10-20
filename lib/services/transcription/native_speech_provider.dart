/// On-device transcription with speaker separation (Android, sherpa-onnx).
///
/// Audio is captured, recognized and attributed to voices on the phone; no
/// audio or text leaves the device. Implements the same
/// [TranscriptionProvider] interface as the Deepgram provider, so the
/// encounter screen can switch between them. See docs/NATIVE_SPEECH.md.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'engine_selector.dart';
import 'model_manager.dart';
import 'speaker_roles.dart';
import 'transcription_provider.dart';

export 'model_manager.dart' show ModelManager, SpeechModelSet, ModelPrepareProgress, ModelPrepareStage;

/// Tunables passed to the native engine on start.
class NativeSpeechOptions {
  /// Expected number of voices. 2 (clinician and patient) gives the most
  /// reliable split when you know it; 0 detects the count (up to [maxSpeakers]).
  final int numSpeakers;
  final int maxSpeakers;

  /// Recordings up to this length (seconds) get the full pyannote
  /// diarization pass on stop; longer ones are re-clustered from the live
  /// voice embeddings, which is instant but cannot split mid-utterance turns.
  /// The full pass takes roughly 5 to 15 percent of the recording length on a
  /// mid-range phone.
  final int finalPassMaxSeconds;

  final bool noiseSuppression;
  final bool autoGain;
  final int asrThreads;
  final bool emitPartials;

  /// How long stop() waits for the final pass before falling back to the
  /// live segments.
  final Duration stopTimeout;

  const NativeSpeechOptions({
    this.numSpeakers = 0,
    this.maxSpeakers = 4,
    this.finalPassMaxSeconds = 600,
    this.noiseSuppression = true,
    this.autoGain = true,
    this.asrThreads = 2,
    this.emitPartials = true,
    this.stopTimeout = const Duration(minutes: 3),
  });

  NativeSpeechOptions copyWith({bool? noiseSuppression}) => NativeSpeechOptions(
        numSpeakers: numSpeakers,
        maxSpeakers: maxSpeakers,
        finalPassMaxSeconds: finalPassMaxSeconds,
        noiseSuppression: noiseSuppression ?? this.noiseSuppression,
        autoGain: autoGain,
        asrThreads: asrThreads,
        emitPartials: emitPartials,
        stopTimeout: stopTimeout,
      );

  Map<String, dynamic> toArgs() => {
        'numSpeakers': numSpeakers,
        'maxSpeakers': maxSpeakers,
        'finalPassMaxSeconds': finalPassMaxSeconds,
        'noiseSuppression': noiseSuppression,
        'autoGain': autoGain,
        'asrThreads': asrThreads,
        'emitPartials': emitPartials,
      };
}

/// Whether the engine can run here, and why not.
class NativeSpeechAvailability {
  /// Native library present for this CPU (ARM Android).
  final bool supported;

  /// Models downloaded and verified.
  final bool modelsReady;

  /// Bytes still to download before [modelsReady].
  final int downloadBytes;
  final String? reason;

  const NativeSpeechAvailability({required this.supported, required this.modelsReady, this.downloadBytes = 0, this.reason});

  bool get canStart => supported && modelsReady;
}

/// Converts one native segment map ({id, speakerIndex, text, start, end,
/// isFinal}) to a [DiarizedSegment].
DiarizedSegment diarizedSegmentFromNative(Map<dynamic, dynamic> m) => DiarizedSegment(
      speakerIndex: (m['speakerIndex'] as num?)?.toInt() ?? 0,
      text: (m['text'] ?? '').toString().trim(),
      start: (m['start'] as num?)?.toDouble() ?? 0,
      end: (m['end'] as num?)?.toDouble() ?? 0,
      isFinal: m['isFinal'] as bool? ?? true,
    );

/// Joins consecutive segments from the same voice into one turn.
List<DiarizedSegment> mergeTurns(Iterable<DiarizedSegment> segments) {
  final out = <DiarizedSegment>[];
  for (final s in segments) {
    if (s.text.isEmpty) continue;
    if (out.isNotEmpty && out.last.speakerIndex == s.speakerIndex && out.last.isFinal == s.isFinal) {
      out[out.length - 1] = out.last.mergedWith(s);
    } else {
      out.add(s);
    }
  }
  return out;
}

/// Maps a native status string to [TranscriptionStatus].
TranscriptionStatus? nativeStatusToTranscription(String? s) => switch (s) {
      'loading' => TranscriptionStatus.connecting,
      'listening' => TranscriptionStatus.listening,
      'behind' => TranscriptionStatus.listening,
      'paused' => TranscriptionStatus.paused,
      'finalizing' => TranscriptionStatus.closing,
      'stopped' => TranscriptionStatus.stopped,
      'failed' => TranscriptionStatus.failed,
      _ => null,
    };

/// On-device speech engine with speaker separation.
///
/// Live: each utterance arrives as a final segment with a voice index as soon
/// as the speaker pauses (about 0.4 s of silence); words of the utterance in
/// progress show as [TranscriptUpdate.interim]. On [stop] the engine runs a
/// whole-recording diarization pass, which may re-label or split earlier
/// segments; the returned transcript and the last update use those labels.
class NativeSpeechProvider implements TranscriptionProvider, AudioLevelSource {
  final ModelManager models;
  final NativeSpeechOptions options;
  final MethodChannel _channel;
  final Stream<dynamic> _events;

  /// Roles pinned by the clinician (speaker index to role).
  final Map<int, String> roleOverrides = {};

  final ValueNotifier<double> _level = ValueNotifier(0);

  /// Loudness of the microphone audio the native engine reads ("level"
  /// events from its capture loop, RMS in dBFS).
  @override
  ValueListenable<double> get audioLevel => _level;

  NativeSpeechProvider({
    ModelManager? models,
    this.options = const NativeSpeechOptions(),
    MethodChannel? methodChannel,
    Stream<dynamic>? eventStream,
  })  : models = models ?? ModelManager(),
        _channel = methodChannel ?? NativeSpeechChannels.methodChannel,
        _events = eventStream ?? NativeSpeechChannels.eventStream;

  /// Checks the native library and the models without starting anything.
  static Future<NativeSpeechAvailability> checkAvailability({ModelManager? models, MethodChannel? methodChannel}) async {
    if (!Platform.isAndroid) {
      return const NativeSpeechAvailability(supported: false, modelsReady: false, reason: 'On-device speaker separation is available on Android only.');
    }
    final channel = methodChannel ?? NativeSpeechChannels.methodChannel;
    final m = models ?? ModelManager();
    try {
      final caps = await channel.invokeMapMethod<String, dynamic>('getCapabilities');
      final supported = caps?['supported'] == true;
      if (!supported) {
        return NativeSpeechAvailability(supported: false, modelsReady: false, reason: caps?['reason']?.toString());
      }
      final ready = await m.isReady();
      return NativeSpeechAvailability(
        supported: true,
        modelsReady: ready,
        downloadBytes: ready ? 0 : await m.remainingDownloadBytes(),
        reason: ready ? null : 'Speech models need to be downloaded.',
      );
    } on MissingPluginException {
      return const NativeSpeechAvailability(supported: false, modelsReady: false, reason: 'Native speech engine is not registered.');
    } catch (e) {
      return NativeSpeechAvailability(supported: false, modelsReady: false, reason: '$e');
    }
  }

  /// Checks the device and models and, when both are ready, sets
  /// [SpeechEngines.onDeviceFactory] so the encounter screen can pick this
  /// engine. Call at app start and again after [ModelManager.prepare] finishes.
  /// Clears the factory when the engine cannot run.
  static Future<NativeSpeechAvailability> register({
    ModelManager? models,
    NativeSpeechOptions options = const NativeSpeechOptions(),
  }) async {
    final m = models ?? ModelManager();
    final a = await checkAvailability(models: m);
    SpeechEngines.onDeviceFactory = a.canStart
        ? ({bool noiseSuppression = true}) => NativeSpeechProvider(models: m, options: options.copyWith(noiseSuppression: noiseSuppression))
        : null;
    return a;
  }

  StreamController<TranscriptUpdate>? _out;
  StreamSubscription<dynamic>? _sub;
  final List<Map<dynamic, dynamic>> _early = [];
  int? _sessionId;

  @visibleForTesting
  int? get sessionIdForTest => _sessionId;
  bool _started = false;
  bool _stopping = false;
  bool _stopped = false;
  TranscriptionStatus _status = TranscriptionStatus.connecting;
  final List<DiarizedSegment> _final = [];
  String _interimText = '';
  int _interimSpeaker = 0;
  double _interimStart = 0;
  double _interimEnd = 0;
  String? _lastError;

  TranscriptionStatus get status => _status;

  /// Progress of the final diarization pass (0 to 1) while stopping.
  double? finalizingProgress;

  /// How the last final pass labeled speakers: pyannote, recluster, online or none.
  String? diarizationMethod;

  /// The engine reported it cannot keep up with real time (very slow phone).
  bool lagging = false;

  /// Final segments as reported by the engine (not merged into turns).
  List<DiarizedSegment> get rawSegments => List.unmodifiable(_final);

  List<DiarizedSegment> get segments => [
        ...mergeTurns(_final),
        if (_interimText.isNotEmpty)
          DiarizedSegment(speakerIndex: _interimSpeaker, text: _interimText, start: _interimStart, end: _interimEnd, isFinal: false),
      ];

  Map<int, String> get roles => SpeakerRoleMapper.assign(_final, overrides: roleOverrides);

  /// The current finalized transcript with role labels.
  String get transcript => buildLabeledTranscript(_final, roles: roles);

  /// Pins [speakerIndex] to [role] (a "swap speakers" control) and re-emits.
  void setRole(int speakerIndex, String role) {
    roleOverrides[speakerIndex] = role;
    _emit();
  }

  @override
  Stream<TranscriptUpdate> start() {
    if (_started) {
      throw StateError('NativeSpeechProvider.start() was already called. Create a new provider per recording.');
    }
    _started = true;
    _out = StreamController<TranscriptUpdate>();
    _sub = _events.listen(_onEvent, onError: (Object e) => _emit(error: 'Speech engine event error: $e'));
    unawaited(_begin());
    return _out!.stream;
  }

  Future<void> _begin() async {
    _setStatus(TranscriptionStatus.connecting);
    try {
      if (!await models.isReady()) {
        _fail('Speech models are not downloaded yet.');
        return;
      }
      final paths = await models.modelPaths();
      final res = await _channel.invokeMapMethod<String, dynamic>('start', {
        'models': paths,
        ...options.toArgs(),
      });
      _sessionId = (res?['sessionId'] as num?)?.toInt();
      final early = List.of(_early);
      _early.clear();
      for (final e in early) {
        _onEvent(e);
      }
      if (_stopping && !_stopped) {
        // stop() was called while start was in flight; it handles the rest.
        return;
      }
    } on PlatformException catch (e) {
      _fail(e.message ?? e.code);
    } on MissingPluginException {
      _fail('The on-device speech engine is not available in this build.');
    } catch (e) {
      _fail('Could not start on-device speech: $e');
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    if (type == 'modelProgress') return;
    final sid = (raw['sessionId'] as num?)?.toInt();
    if (_sessionId == null) {
      // Events can arrive before start() returns the session id.
      if (!_stopped) _early.add(raw);
      return;
    }
    if (sid != null && sid != _sessionId) return;
    handleEvent(raw);
  }

  /// Applies one engine event. Public for tests.
  void handleEvent(Map<dynamic, dynamic> e) {
    switch (e['type']) {
      case 'status':
        final s = e['status'] as String?;
        if (s == 'behind') lagging = true;
        final p = e['progress'];
        if (s == 'finalizing') finalizingProgress = p is num ? p.toDouble() : finalizingProgress;
        final mapped = nativeStatusToTranscription(s);
        if (mapped != null) {
          if (_status == TranscriptionStatus.failed && mapped != TranscriptionStatus.stopped) return;
          _status = mapped;
        }
        _emit();
      case 'level':
        final db = e['dbfs'];
        if (db is num) _level.value = dbfsToLevel(db.toDouble());
      case 'start':
        _emit();
      case 'partial':
        _interimText = (e['text'] ?? '').toString().trim();
        _interimSpeaker = (e['speakerIndex'] as num?)?.toInt() ?? _interimSpeaker;
        _interimStart = (e['start'] as num?)?.toDouble() ?? _interimStart;
        _interimEnd = (e['end'] as num?)?.toDouble() ?? _interimEnd;
        _emit();
      case 'segment':
        final seg = e['segment'];
        if (seg is Map) {
          final s = diarizedSegmentFromNative(seg);
          if (s.text.isNotEmpty) _final.add(s);
          _interimText = '';
          _interimSpeaker = s.speakerIndex;
        }
        _emit();
      case 'final':
        _applyFinal(e);
        _emit();
      case 'error':
        final msg = (e['message'] ?? e['code'] ?? 'Speech engine error').toString();
        _lastError = msg;
        if (e['fatal'] == true) {
          _status = TranscriptionStatus.failed;
          _emit(status: TranscriptionStatus.failed, error: msg);
        } else {
          _emit(error: msg);
        }
      case 'end':
        break;
    }
  }

  void _applyFinal(Map<dynamic, dynamic> payload) {
    final segs = payload['segments'];
    diarizationMethod = payload['method']?.toString();
    if (segs is List) {
      final list = segs.whereType<Map>().map(diarizedSegmentFromNative).where((s) => s.text.isNotEmpty).toList();
      // An empty final list with live segments present means the final pass
      // produced nothing; keep what was shown.
      if (list.isNotEmpty || _final.isEmpty) {
        _final
          ..clear()
          ..addAll(list);
        // Indices may have changed; overrides would now point at other voices.
        if (diarizationMethod == 'pyannote' || diarizationMethod == 'recluster') roleOverrides.clear();
      }
    }
    _interimText = '';
    finalizingProgress = 1;
  }

  @override
  Future<void> pause() async {
    if (_stopped || _stopping) return;
    try {
      await _channel.invokeMethod<bool>('pause');
    } catch (e) {
      _emit(error: 'Could not pause the microphone ($e).');
    }
  }

  @override
  Future<void> resume() async {
    if (_stopped || _stopping) return;
    try {
      await _channel.invokeMethod<bool>('resume');
    } catch (e) {
      _emit(error: 'Could not resume the microphone ($e).');
    }
  }

  @override
  Future<String> stop() async {
    if (_stopped) return transcript;
    if (_stopping) {
      await _out?.done.catchError((_) {});
      return transcript;
    }
    _stopping = true;
    if (_status != TranscriptionStatus.failed) _emit(status: TranscriptionStatus.closing);
    try {
      final payload = await _channel.invokeMapMethod<String, dynamic>('stop').timeout(options.stopTimeout);
      if (payload != null) _applyFinal(payload);
    } on TimeoutException {
      _lastError = 'The final speaker pass took too long; using live speaker labels.';
      unawaited(_channel.invokeMethod<void>('cancel').catchError((_) {}));
    } catch (e) {
      _lastError = 'Could not finish on-device transcription ($e); using live speaker labels.';
    }
    _interimText = '';
    _stopped = true;
    if (_status != TranscriptionStatus.failed) _status = TranscriptionStatus.stopped;
    _emit(status: _status, error: _status == TranscriptionStatus.failed ? _lastError : null);
    await _sub?.cancel();
    _sub = null;
    await _out?.close();
    return transcript;
  }

  void _fail(String message) {
    _lastError = message;
    _status = TranscriptionStatus.failed;
    _emit(status: TranscriptionStatus.failed, error: message);
  }

  void _setStatus(TranscriptionStatus s) {
    if (_status == s) return;
    _emit(status: s);
  }

  void _emit({TranscriptionStatus? status, String? error}) {
    if (status != null) _status = status;
    final out = _out;
    if (out == null || out.isClosed) return;
    final r = roles;
    out.add(TranscriptUpdate(
      transcript: buildLabeledTranscript(_final, roles: r),
      interim: _interimText,
      segments: segments,
      roles: r,
      status: _status,
      error: error,
    ));
  }
}
