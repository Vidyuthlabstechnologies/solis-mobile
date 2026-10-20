import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'speaker_roles.dart';
import 'transcription_provider.dart';

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------

/// Query parameters for Deepgram's live endpoint.
/// Reference: https://developers.deepgram.com/reference/speech-to-text-api/listen-streaming
class DeepgramOptions {
  static const String endpoint = 'wss://api.deepgram.com/v1/listen';

  final String model;
  final String language;

  /// Uses `diarize_model=<value>` (current API). Set [legacyDiarizeFlag] to
  /// send the deprecated `diarize=true` instead. Never send both: Deepgram
  /// rejects requests that include both.
  final String diarizeModel;
  final bool legacyDiarizeFlag;

  final bool smartFormat;
  final bool punctuate;
  final bool interimResults;

  /// Milliseconds of silence before Deepgram sets speech_final.
  final int endpointingMs;

  /// Milliseconds of word gap before an UtteranceEnd message. Must be 1000
  /// or more and requires interim results.
  final int utteranceEndMs;

  /// Up to 100 terms (drug names, clinic vocabulary) to boost (Nova-3 only).
  final List<String> keyterms;

  final int sampleRate;
  final int channels;

  const DeepgramOptions({
    this.model = 'nova-3-medical',
    this.language = 'en-US',
    this.diarizeModel = 'latest',
    this.legacyDiarizeFlag = false,
    this.smartFormat = true,
    this.punctuate = true,
    this.interimResults = true,
    this.endpointingMs = 300,
    this.utteranceEndMs = 1000,
    this.keyterms = const [],
    this.sampleRate = 16000,
    this.channels = 1,
  });

  Uri buildUri() {
    final pairs = <MapEntry<String, String>>[
      MapEntry('model', model),
      MapEntry('language', language),
      MapEntry('encoding', 'linear16'),
      MapEntry('sample_rate', '$sampleRate'),
      MapEntry('channels', '$channels'),
      legacyDiarizeFlag ? const MapEntry('diarize', 'true') : MapEntry('diarize_model', diarizeModel),
      MapEntry('punctuate', '$punctuate'),
      MapEntry('smart_format', '$smartFormat'),
      MapEntry('interim_results', '$interimResults'),
      MapEntry('endpointing', '$endpointingMs'),
      if (interimResults) MapEntry('utterance_end_ms', '${utteranceEndMs < 1000 ? 1000 : utteranceEndMs}'),
      MapEntry('vad_events', 'true'),
      for (final k in keyterms.take(100)) MapEntry('keyterm', k),
    ];
    final query = pairs.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return Uri.parse('$endpoint?$query');
  }
}

// -----------------------------------------------------------------------------
// Injectable transport and audio
// -----------------------------------------------------------------------------

/// The websocket as the provider sees it. Tests pass a fake.
abstract class TranscriptionSocket {
  /// Incoming frames: String (JSON) or `List<int>`.
  Stream<dynamic> get messages;
  void sendBytes(List<int> bytes);
  void sendText(String text);
  int? get closeCode;
  String? get closeReason;
  Future<void> close();
}

typedef TranscriptionSocketFactory = Future<TranscriptionSocket> Function(Uri uri, Map<String, String> headers);

/// Real websocket via web_socket_channel (dart:io, so custom headers work).
class IoTranscriptionSocket implements TranscriptionSocket {
  final IOWebSocketChannel _channel;
  IoTranscriptionSocket._(this._channel);

  static Future<TranscriptionSocket> connect(Uri uri, Map<String, String> headers) async {
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    );
    await channel.ready;
    return IoTranscriptionSocket._(channel);
  }

  @override
  Stream<dynamic> get messages => _channel.stream;
  @override
  void sendBytes(List<int> bytes) => _channel.sink.add(bytes);
  @override
  void sendText(String text) => _channel.sink.add(text);
  @override
  int? get closeCode => _channel.closeCode;
  @override
  String? get closeReason => _channel.closeReason;
  @override
  Future<void> close() => _channel.sink.close(ws_status.normalClosure);
}

/// Microphone PCM as the provider sees it. Tests pass a fake.
abstract class AudioCaptureSource {
  Future<bool> hasPermission();

  /// Starts capture of 16-bit little-endian mono PCM at the given rate.
  Future<Stream<Uint8List>> start({required int sampleRate, required int channels});
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

/// Microphone capture through the record package.
class RecordAudioSource implements AudioCaptureSource {
  /// Android's noise suppressor on the capture (the Session details switch).
  final bool noiseSuppress;
  RecordAudioSource({this.noiseSuppress = true});

  AudioRecorder? _recorder;
  AudioRecorder get _rec => _recorder ??= AudioRecorder();

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<Stream<Uint8List>> start({required int sampleRate, required int channels}) => _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        noiseSuppress: noiseSuppress,
        // Tuned for speech recognition on Android: no heavy call processing
        // that would blur the differences between voices.
        androidConfig: const AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
      ));

  @override
  Future<void> pause() => _rec.pause();
  @override
  Future<void> resume() => _rec.resume();
  @override
  Future<void> stop() async {
    await _rec.stop();
  }

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
    _recorder = null;
  }
}

// -----------------------------------------------------------------------------
// Message parsing and turn assembly (pure, no I/O)
// -----------------------------------------------------------------------------

enum DeepgramMessageKind { results, utteranceEnd, speechStarted, metadata, error, unknown }

/// Turns Deepgram's streaming messages into speaker turns.
///
/// Deepgram sends a Results message about once a second. While
/// `is_final` is false the words for the current audio window may still be
/// revised, and each new interim replaces the previous one. When `is_final`
/// is true those words are fixed: they are appended to the finalized turns
/// and the interim is cleared. Consecutive words from the same speaker are
/// merged into one turn.
class DeepgramTranscriptAssembler {
  final List<DiarizedSegment> _final = [];
  List<DiarizedSegment> _interim = const [];
  String _interimText = '';
  double? _finalWordEnd;

  /// Added to every speaker index (see [speakerSessionStride]).
  int speakerOffset = 0;

  /// Added to every timestamp, so times keep increasing after a reconnect.
  double timeOffset = 0;

  String? lastError;
  String? requestId;

  List<DiarizedSegment> get finalSegments => List.unmodifiable(_final);
  List<DiarizedSegment> get interimSegments => List.unmodifiable(_interim);
  List<DiarizedSegment> get segments => [..._final, ..._interim];
  String get interimText => _interimText;

  double get lastEnd {
    var end = timeOffset;
    for (final s in [..._final, ..._interim]) {
      if (s.end > end) end = s.end;
    }
    return end;
  }

  /// Parses one frame. Malformed input is reported as [DeepgramMessageKind.error]
  /// with [lastError] set; it never throws.
  DeepgramMessageKind handle(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return DeepgramMessageKind.unknown;
      msg = decoded;
    } catch (e) {
      lastError = 'Could not read a transcription message ($e).';
      return DeepgramMessageKind.error;
    }

    switch (msg['type']) {
      case 'Results':
        _handleResults(msg);
        return DeepgramMessageKind.results;
      case 'UtteranceEnd':
        // The speaker stopped. Deepgram still sends is_final for the last
        // window, so nothing is promoted here (that would duplicate words).
        return DeepgramMessageKind.utteranceEnd;
      case 'SpeechStarted':
        return DeepgramMessageKind.speechStarted;
      case 'Metadata':
        requestId = msg['request_id']?.toString();
        return DeepgramMessageKind.metadata;
      case 'Error':
        final parts = [msg['description'], msg['message'], msg['variant'], msg['code']]
            .where((p) => p != null && p.toString().isNotEmpty)
            .map((p) => p.toString())
            .toList();
        lastError = parts.isEmpty ? 'Transcription service reported an error.' : parts.join(' ');
        return DeepgramMessageKind.error;
      default:
        // Older Deepgram responses had no "type" but carried "channel".
        if (msg['type'] == null && msg['channel'] is Map) {
          _handleResults(msg);
          return DeepgramMessageKind.results;
        }
        return DeepgramMessageKind.unknown;
    }
  }

  void _handleResults(Map<String, dynamic> msg) {
    final isFinal = msg['is_final'] == true;
    final channel = msg['channel'];
    if (channel is! Map) return;
    final alternatives = channel['alternatives'];
    if (alternatives is! List || alternatives.isEmpty || alternatives.first is! Map) return;
    final alt = alternatives.first as Map;
    final words = alt['words'] is List ? alt['words'] as List : const [];
    // Words already finalized (for example promoted before a reconnect) are
    // skipped so a late final result cannot duplicate them.
    final segs = wordsToSegments(
      words,
      isFinal: isFinal,
      speakerOffset: speakerOffset,
      timeOffset: timeOffset,
      skipEndingBy: _finalWordEnd,
    );

    if (isFinal) {
      for (final s in segs) {
        _appendFinal(s);
      }
      _interim = const [];
      _interimText = '';
    } else {
      _interim = segs;
      _interimText = (alt['transcript'] ?? '').toString().trim();
      if (_interimText.isEmpty) _interimText = segs.map((s) => s.text).join(' ');
    }
  }

  void _appendFinal(DiarizedSegment s) {
    if (s.text.trim().isEmpty) return;
    if (s.end > (_finalWordEnd ?? double.negativeInfinity)) _finalWordEnd = s.end;
    if (_final.isNotEmpty && _final.last.speakerIndex == s.speakerIndex) {
      _final[_final.length - 1] = _final.last.mergedWith(s);
    } else {
      _final.add(s);
    }
  }

  /// Keeps the current interim words as final (used before a reconnect and
  /// at stop, so nothing heard is lost).
  void promoteInterim() {
    for (final s in _interim) {
      _appendFinal(s.copyWith(isFinal: true));
    }
    _interim = const [];
    _interimText = '';
  }

  /// Groups a Results message's words into one segment per run of the same
  /// speaker. Words without a speaker (diarization off) count as speaker 0.
  static List<DiarizedSegment> wordsToSegments(
    List<dynamic> words, {
    required bool isFinal,
    int speakerOffset = 0,
    double timeOffset = 0,
    double? skipEndingBy,
  }) {
    final out = <DiarizedSegment>[];
    for (final w in words) {
      if (w is! Map) continue;
      final token = (w['punctuated_word'] ?? w['word'] ?? '').toString().trim();
      if (token.isEmpty) continue;
      final speaker = (w['speaker'] is num ? (w['speaker'] as num).toInt() : 0) + speakerOffset;
      final start = (w['start'] is num ? (w['start'] as num).toDouble() : 0) + timeOffset;
      final end = (w['end'] is num ? (w['end'] as num).toDouble() : 0) + timeOffset;
      if (skipEndingBy != null && end <= skipEndingBy + 1e-6) continue;
      final seg = DiarizedSegment(speakerIndex: speaker, text: token, start: start, end: end, isFinal: isFinal);
      if (out.isNotEmpty && out.last.speakerIndex == speaker) {
        out[out.length - 1] = out.last.mergedWith(seg);
      } else {
        out.add(seg);
      }
    }
    return out;
  }
}

// -----------------------------------------------------------------------------
// Provider
// -----------------------------------------------------------------------------

/// Live transcription with speaker diarization through Deepgram's streaming
/// API. Audio goes from the microphone (16 kHz mono linear16) straight to
/// Deepgram over a websocket; turns come back labeled by voice and are mapped
/// to Doctor / Patient / Other by [SpeakerRoleMapper].
class DeepgramStreamingProvider implements TranscriptionProvider, AudioLevelSource {
  final String apiKey;
  final DeepgramOptions options;
  final TranscriptionSocketFactory _connect;
  final AudioCaptureSource _audio;

  /// How often KeepAlive is sent while paused (Deepgram: every 3 to 5 s;
  /// the socket closes after 10 s without audio or KeepAlive).
  final Duration keepAliveInterval;

  /// How long [stop] waits for the last results after CloseStream.
  final Duration closeTimeout;

  /// Unexpected closes that are retried before giving up.
  final int maxReconnects;

  /// Roles the clinician pinned by hand; they win over inference.
  final Map<int, String> roleOverrides = {};

  final DeepgramTranscriptAssembler assembler = DeepgramTranscriptAssembler();

  final ValueNotifier<double> _level = ValueNotifier(0);

  /// Loudness of the microphone audio this provider streams.
  @override
  ValueListenable<double> get audioLevel => _level;

  DeepgramStreamingProvider(
    this.apiKey, {
    this.options = const DeepgramOptions(),
    TranscriptionSocketFactory? socketFactory,
    AudioCaptureSource? audioSource,
    this.keepAliveInterval = const Duration(seconds: 4),
    this.closeTimeout = const Duration(seconds: 3),
    this.maxReconnects = 1,
  })  : _connect = socketFactory ?? IoTranscriptionSocket.connect,
        _audio = audioSource ?? RecordAudioSource(),
        _tokenSource = null;

  /// Authenticates with short-lived tokens from the SOLIS server instead of
  /// an API key, so the Deepgram key never reaches the phone. A fresh token
  /// is fetched for every connection, including reconnects.
  DeepgramStreamingProvider.withTokens(
    Future<String> Function() tokenSource, {
    this.options = const DeepgramOptions(),
    TranscriptionSocketFactory? socketFactory,
    AudioCaptureSource? audioSource,
    this.keepAliveInterval = const Duration(seconds: 4),
    this.closeTimeout = const Duration(seconds: 3),
    this.maxReconnects = 1,
  })  : apiKey = '',
        _tokenSource = tokenSource,
        _connect = socketFactory ?? IoTranscriptionSocket.connect,
        _audio = audioSource ?? RecordAudioSource();

  final Future<String> Function()? _tokenSource;

  StreamController<TranscriptUpdate>? _out;
  TranscriptionSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<Uint8List>? _audioSub;
  Completer<void>? _socketDone;
  Timer? _keepAlive;
  int _reconnects = 0;
  int _connection = 0;
  bool _started = false;
  bool _paused = false;
  bool _stopping = false;
  bool _stopped = false;
  TranscriptionStatus _status = TranscriptionStatus.connecting;

  /// Audio captured while a reconnect is in progress, sent once it opens.
  final List<Uint8List> _pending = [];
  int _pendingBytes = 0;
  static const int _maxPendingBytes = 16000 * 2 * 10; // 10 s of 16 kHz mono PCM

  Future<Map<String, String>> _headers() async {
    final tokens = _tokenSource;
    if (tokens == null) return {'Authorization': 'Token $apiKey'};
    return {'Authorization': 'Bearer ${await tokens()}'};
  }

  TranscriptionStatus get status => _status;

  /// The current finalized transcript with role labels.
  String get transcript => buildLabeledTranscript(assembler.finalSegments, roles: roles);

  Map<int, String> get roles => SpeakerRoleMapper.assign(assembler.segments, overrides: roleOverrides);

  /// Pins [speakerIndex] to [role] (for a "swap speakers" control) and
  /// re-emits the transcript.
  void setRole(int speakerIndex, String role) {
    roleOverrides[speakerIndex] = role;
    _emit();
  }

  @override
  Stream<TranscriptUpdate> start() {
    if (_started) {
      throw StateError('DeepgramStreamingProvider.start() was already called. Create a new provider per recording.');
    }
    _started = true;
    _out = StreamController<TranscriptUpdate>();
    unawaited(_begin());
    return _out!.stream;
  }

  Future<void> _begin() async {
    if (_tokenSource == null && apiKey.trim().isEmpty) {
      _fail('No Deepgram API key is configured.');
      return;
    }
    try {
      if (!await _audio.hasPermission()) {
        _fail('Microphone permission was denied.');
        return;
      }
    } catch (e) {
      _fail('Could not check microphone permission ($e).');
      return;
    }

    if (!await _openSocket()) {
      _fail(assembler.lastError ?? 'Could not connect to the transcription service.');
      return;
    }
    if (_stopping) return;

    try {
      final stream = await _audio.start(sampleRate: options.sampleRate, channels: options.channels);
      _audioSub = stream.listen(
        _onAudio,
        onError: (Object e) => _emit(error: 'Microphone error: $e'),
        cancelOnError: false,
      );
    } catch (e) {
      _fail('Could not start the microphone ($e).');
      return;
    }
    _setStatus(_paused ? TranscriptionStatus.paused : TranscriptionStatus.listening);
  }

  Future<bool> _openSocket() async {
    _setStatus(_connection == 0 ? TranscriptionStatus.connecting : TranscriptionStatus.reconnecting);
    final TranscriptionSocket socket;
    try {
      socket = await _connect(options.buildUri(), await _headers());
    } catch (e) {
      assembler.lastError = _describeConnectError(e);
      return false;
    }
    if (_stopped) {
      unawaited(socket.close().catchError((_) {}));
      return false;
    }
    _connection++;
    _socket = socket;
    final done = Completer<void>();
    _socketDone = done;
    _socketSub = socket.messages.listen(
      _onMessage,
      onError: (Object e) {
        assembler.lastError = 'Transcription connection error: $e';
        _emit(error: assembler.lastError);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
        _onSocketClosed(socket);
      },
      cancelOnError: false,
    );
    // Flush audio buffered during a reconnect.
    for (final chunk in _pending) {
      _safeSendBytes(chunk);
    }
    _pending.clear();
    _pendingBytes = 0;
    if (_paused) _startKeepAlive();
    return true;
  }

  String _describeConnectError(Object e) {
    final text = e.toString();
    if (text.contains('401') || text.contains('403')) {
      return 'Deepgram rejected the API key (check it in Settings).';
    }
    return 'Could not connect to the transcription service ($text).';
  }

  void _onMessage(dynamic raw) {
    final kind = assembler.handle(raw);
    switch (kind) {
      case DeepgramMessageKind.results:
      case DeepgramMessageKind.utteranceEnd:
        _emit();
      case DeepgramMessageKind.error:
        _emit(error: assembler.lastError);
      case DeepgramMessageKind.speechStarted:
      case DeepgramMessageKind.metadata:
      case DeepgramMessageKind.unknown:
        break;
    }
  }

  void _onAudio(Uint8List bytes) {
    if (_paused || _stopped) return;
    _level.value = pcm16Level(bytes);
    if (_socket == null) {
      // Reconnecting: keep the most recent audio so the words are not lost.
      _pending.add(bytes);
      _pendingBytes += bytes.length;
      while (_pendingBytes > _maxPendingBytes && _pending.isNotEmpty) {
        _pendingBytes -= _pending.removeAt(0).length;
      }
      return;
    }
    _safeSendBytes(bytes);
  }

  void _safeSendBytes(List<int> bytes) {
    try {
      _socket?.sendBytes(bytes);
    } catch (_) {
      // The socket is closing; onDone handles reconnection.
    }
  }

  void _safeSendText(String text) {
    try {
      _socket?.sendText(text);
    } catch (_) {}
  }

  void _onSocketClosed(TranscriptionSocket socket) {
    if (!identical(socket, _socket)) return;
    _stopKeepAlive();
    unawaited(_socketSub?.cancel());
    _socketSub = null;
    _socket = null;
    if (_stopping || _stopped) return;

    final code = socket.closeCode;
    final reason = socket.closeReason;
    final why = [if (code != null) 'code $code', if (reason != null && reason.isNotEmpty) reason].join(', ');
    if (_reconnects >= maxReconnects) {
      _fail('Transcription connection closed${why.isEmpty ? '' : ' ($why)'}.');
      return;
    }
    _reconnects++;
    // A new connection restarts Deepgram's clock and speaker numbers.
    assembler.promoteInterim();
    assembler.timeOffset = assembler.lastEnd;
    assembler.speakerOffset = _reconnects * speakerSessionStride;
    _emit(status: TranscriptionStatus.reconnecting);
    unawaited(() async {
      final ok = await _openSocket();
      if (!ok) {
        _fail(assembler.lastError ?? 'Could not reconnect to the transcription service.');
      } else {
        _setStatus(_paused ? TranscriptionStatus.paused : TranscriptionStatus.listening);
      }
    }());
  }

  @override
  Future<void> pause() async {
    if (_paused || _stopped || _stopping) return;
    _paused = true;
    try {
      await _audio.pause();
    } catch (e) {
      _emit(error: 'Could not pause the microphone ($e).');
    }
    // Ask Deepgram to finalize what it has, then keep the socket alive.
    _safeSendText(jsonEncode({'type': 'Finalize'}));
    _startKeepAlive();
    _setStatus(TranscriptionStatus.paused);
  }

  @override
  Future<void> resume() async {
    if (!_paused || _stopped || _stopping) return;
    _paused = false;
    _stopKeepAlive();
    try {
      await _audio.resume();
    } catch (e) {
      _emit(error: 'Could not resume the microphone ($e).');
    }
    _setStatus(TranscriptionStatus.listening);
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(keepAliveInterval, (_) => _safeSendText(jsonEncode({'type': 'KeepAlive'})));
  }

  void _stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  @override
  Future<String> stop() async {
    if (_stopped) return transcript;
    if (_stopping) {
      await _out?.done.catchError((_) {});
      return transcript;
    }
    _stopping = true;
    _stopKeepAlive();
    _setStatus(TranscriptionStatus.closing);

    try {
      await _audioSub?.cancel();
    } catch (_) {}
    _audioSub = null;
    try {
      await _audio.stop();
    } catch (_) {}

    final socket = _socket;
    if (socket != null) {
      // CloseStream makes Deepgram flush the remaining final results and
      // then close the socket itself.
      _safeSendText(jsonEncode({'type': 'CloseStream'}));
      final done = _socketDone;
      if (done != null) {
        await done.future.timeout(closeTimeout, onTimeout: () {});
      }
      try {
        await socket.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    await _socketSub?.cancel();
    _socketSub = null;
    _socket = null;

    assembler.promoteInterim();
    _stopped = true;
    _emit(status: TranscriptionStatus.stopped);
    try {
      await _audio.dispose();
    } catch (_) {}
    await _out?.close();
    return transcript;
  }

  void _fail(String message) {
    _status = TranscriptionStatus.failed;
    _emit(status: TranscriptionStatus.failed, error: message);
    // Keep the stream open: stop() still returns whatever was transcribed
    // and closes it, so the screen can fall back to on-device recognition.
    unawaited(_audioSub?.cancel());
    _audioSub = null;
    unawaited(_audio.stop().catchError((_) {}));
    _stopKeepAlive();
  }

  void _setStatus(TranscriptionStatus s) {
    if (_status == TranscriptionStatus.failed && s != TranscriptionStatus.stopped && s != TranscriptionStatus.closing) return;
    if (_status == s) return;
    _emit(status: s);
  }

  void _emit({TranscriptionStatus? status, String? error}) {
    if (status != null) _status = status;
    final out = _out;
    if (out == null || out.isClosed) return;
    final r = roles;
    out.add(TranscriptUpdate(
      transcript: buildLabeledTranscript(assembler.finalSegments, roles: r),
      interim: assembler.interimText,
      segments: assembler.segments,
      roles: r,
      status: _status,
      error: error,
    ));
  }
}
