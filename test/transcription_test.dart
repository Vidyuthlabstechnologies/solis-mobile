import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/transcription/deepgram_provider.dart';
import 'package:solis_mobile/services/transcription/speaker_roles.dart';
import 'package:solis_mobile/services/transcription/transcription_provider.dart';

// -----------------------------------------------------------------------------
// Realistic Deepgram live messages (shape from the /v1/listen streaming
// reference and the diarization docs: words carry speaker, no
// speaker_confidence on streaming).
// -----------------------------------------------------------------------------

typedef W = (String word, double start, double end, int speaker);

String results(List<W> words, {required bool isFinal, bool speechFinal = false, double start = 0}) {
  final transcript = words.map((w) => w.$1).join(' ');
  return jsonEncode({
    'type': 'Results',
    'channel_index': [0, 1],
    'duration': words.isEmpty ? 1.0 : words.last.$3 - start,
    'start': start,
    'is_final': isFinal,
    'speech_final': speechFinal,
    'from_finalize': false,
    'channel': {
      'alternatives': [
        {
          'transcript': transcript,
          'confidence': 0.98,
          'words': [
            for (final w in words)
              {
                'word': w.$1.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\x27]'), ''),
                'start': w.$2,
                'end': w.$3,
                'confidence': 0.97,
                'punctuated_word': w.$1,
                'speaker': w.$4,
              },
          ],
        },
      ],
    },
    'metadata': {
      'request_id': 'test-request',
      'model_info': {'name': '2-medical-nova-3', 'version': '2025-01-01', 'arch': 'nova-3'},
      'model_uuid': '00000000-0000-0000-0000-000000000000',
    },
  });
}

/// Words for a sentence, all from one speaker, 0.3 s each starting at [t].
List<W> say(String sentence, int speaker, double t) {
  final parts = sentence.split(' ');
  return [for (var i = 0; i < parts.length; i++) (parts[i], t + i * 0.3, t + i * 0.3 + 0.25, speaker)];
}

// -----------------------------------------------------------------------------
// Fakes: no network, no microphone.
// -----------------------------------------------------------------------------

class FakeSocket implements TranscriptionSocket {
  final _incoming = StreamController<dynamic>();
  final List<List<int>> sentBytes = [];
  final List<String> sentText = [];
  void Function(FakeSocket socket, String text)? onText;
  @override
  int? closeCode;
  @override
  String? closeReason;
  bool closedByClient = false;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  void serverSends(String message) => _incoming.add(message);

  Future<void> serverCloses({int code = 1011, String reason = 'NET-0001'}) async {
    closeCode = code;
    closeReason = reason;
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  void sendBytes(List<int> bytes) {
    if (_incoming.isClosed) throw StateError('closed');
    sentBytes.add(bytes);
  }

  @override
  void sendText(String text) {
    if (_incoming.isClosed) throw StateError('closed');
    sentText.add(text);
    onText?.call(this, text);
  }

  List<String> get sentTypes => sentText.map((t) => (jsonDecode(t) as Map)['type'] as String).toList();

  @override
  Future<void> close() async {
    closedByClient = true;
    closeCode ??= 1000;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class FakeAudio implements AudioCaptureSource {
  final controller = StreamController<Uint8List>();
  bool permission = true;
  bool paused = false;
  bool stopped = false;
  bool disposed = false;
  int? sampleRate;
  int? channels;

  void speak(int n) => controller.add(Uint8List(n));

  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<Stream<Uint8List>> start({required int sampleRate, required int channels}) async {
    this.sampleRate = sampleRate;
    this.channels = channels;
    return controller.stream;
  }

  @override
  Future<void> pause() async => paused = true;
  @override
  Future<void> resume() async => paused = false;
  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  group('DeepgramOptions', () {
    test('builds the live URL with medical model, diarization and PCM settings', () {
      final uri = const DeepgramOptions(keyterms: ['metformin', 'lisinopril']).buildUri();
      expect(uri.scheme, 'wss');
      expect(uri.host, 'api.deepgram.com');
      expect(uri.path, '/v1/listen');
      final q = uri.queryParametersAll;
      expect(q['model'], ['nova-3-medical']);
      expect(q['encoding'], ['linear16']);
      expect(q['sample_rate'], ['16000']);
      expect(q['channels'], ['1']);
      expect(q['diarize_model'], ['latest']);
      expect(q.containsKey('diarize'), isFalse, reason: 'Deepgram rejects diarize together with diarize_model');
      expect(q['smart_format'], ['true']);
      expect(q['punctuate'], ['true']);
      expect(q['interim_results'], ['true']);
      expect(q['utterance_end_ms'], ['1000']);
      expect(q['endpointing'], ['300']);
      expect(q['keyterm'], ['metformin', 'lisinopril']);
    });

    test('legacy flag sends diarize=true only, utterance_end_ms floors at 1000', () {
      final q = const DeepgramOptions(legacyDiarizeFlag: true, utteranceEndMs: 500).buildUri().queryParameters;
      expect(q['diarize'], 'true');
      expect(q.containsKey('diarize_model'), isFalse);
      expect(q['utterance_end_ms'], '1000');
    });
  });

  group('DeepgramTranscriptAssembler', () {
    test('splits one final message into turns by speaker', () {
      final a = DeepgramTranscriptAssembler();
      final kind = a.handle(results([
        ...say('What brings you in today?', 0, 0.0),
        ...say('My chest has been hurting since yesterday.', 1, 2.0),
      ], isFinal: true, speechFinal: true));
      expect(kind, DeepgramMessageKind.results);
      expect(a.finalSegments.length, 2);
      expect(a.finalSegments[0].speakerIndex, 0);
      expect(a.finalSegments[0].text, 'What brings you in today?');
      expect(a.finalSegments[1].speakerIndex, 1);
      expect(a.finalSegments[1].text, 'My chest has been hurting since yesterday.');
      expect(a.finalSegments[1].start, 2.0);
      expect(a.finalSegments.every((s) => s.isFinal), isTrue);
      expect(a.interimText, isEmpty);
    });

    test('merges consecutive final messages from the same speaker into one turn', () {
      final a = DeepgramTranscriptAssembler();
      a.handle(results(say('It started two days ago.', 1, 0), isFinal: true));
      a.handle(results(say('It gets worse when I climb stairs.', 1, 2), isFinal: true));
      a.handle(results(say('Any shortness of breath?', 0, 5), isFinal: true));
      expect(a.finalSegments.length, 2);
      expect(a.finalSegments[0].text, 'It started two days ago. It gets worse when I climb stairs.');
      expect(a.finalSegments[0].start, 0);
      expect(a.finalSegments[0].end, closeTo(2 + 6 * 0.3 + 0.25, 1e-9));
      expect(a.finalSegments[1].speakerIndex, 0);
    });

    test('interim results replace each other and stay separate from final text', () {
      final a = DeepgramTranscriptAssembler();
      a.handle(results(say('Any chest', 0, 0), isFinal: false));
      expect(a.interimText, 'Any chest');
      expect(a.finalSegments, isEmpty);
      expect(a.interimSegments.single.isFinal, isFalse);

      a.handle(results(say('Any chest pain at rest?', 0, 0), isFinal: false));
      expect(a.interimText, 'Any chest pain at rest?');
      expect(a.interimSegments.length, 1);

      a.handle(results(say('Any chest pain at rest?', 0, 0), isFinal: true, speechFinal: true));
      expect(a.interimText, isEmpty);
      expect(a.interimSegments, isEmpty);
      expect(a.finalSegments.single.text, 'Any chest pain at rest?');
      expect(a.segments.length, 1);
    });

    test('UtteranceEnd does not duplicate words that a later final result covers', () {
      final a = DeepgramTranscriptAssembler();
      a.handle(results(say('No, only when walking.', 1, 0), isFinal: false));
      expect(a.handle(jsonEncode({'type': 'UtteranceEnd', 'channel': [0, 1], 'last_word_end': 1.15})), DeepgramMessageKind.utteranceEnd);
      a.handle(results(say('No, only when walking.', 1, 0), isFinal: true));
      expect(a.finalSegments.single.text, 'No, only when walking.');
    });

    test('promoted interim words are not repeated by a late final', () {
      final a = DeepgramTranscriptAssembler();
      a.handle(results(say('I take metformin.', 1, 0), isFinal: false));
      a.promoteInterim();
      a.handle(results(say('I take metformin.', 1, 0), isFinal: true));
      expect(a.finalSegments.single.text, 'I take metformin.');
    });

    test('words without a speaker field count as speaker 0', () {
      final segs = DeepgramTranscriptAssembler.wordsToSegments([
        {'word': 'hello', 'punctuated_word': 'Hello.', 'start': 0.1, 'end': 0.4},
      ], isFinal: true);
      expect(segs.single.speakerIndex, 0);
      expect(segs.single.text, 'Hello.');
    });

    test('Error, Metadata and malformed frames are reported, never thrown', () {
      final a = DeepgramTranscriptAssembler();
      expect(
        a.handle(jsonEncode({'type': 'Error', 'variant': 'BadRequest', 'description': 'Invalid model', 'code': 'INVALID_QUERY_PARAMETER', 'message': ''})),
        DeepgramMessageKind.error,
      );
      expect(a.lastError, contains('Invalid model'));
      expect(
        a.handle(jsonEncode({'type': 'Metadata', 'request_id': 'abc', 'sha256': 'x', 'created': '2026-10-16T00:00:00Z', 'duration': 12.5, 'channels': 1})),
        DeepgramMessageKind.metadata,
      );
      expect(a.requestId, 'abc');
      expect(a.handle('{not json'), DeepgramMessageKind.error);
      expect(a.handle(jsonEncode({'type': 'SpeechStarted', 'channel': [0], 'timestamp': 1.2})), DeepgramMessageKind.speechStarted);
      expect(a.handle(utf8.encode(results(say('Hi.', 0, 0), isFinal: true))), DeepgramMessageKind.results);
      expect(a.finalSegments.single.text, 'Hi.');
    });

    test('speaker and time offsets keep a reconnected session apart', () {
      final a = DeepgramTranscriptAssembler();
      a.handle(results(say('How long has it hurt?', 0, 0), isFinal: true));
      a.timeOffset = a.lastEnd;
      a.speakerOffset = speakerSessionStride;
      a.handle(results(say('About a week.', 0, 0.1), isFinal: true));
      expect(a.finalSegments.length, 2);
      expect(a.finalSegments[1].speakerIndex, 100);
      expect(a.finalSegments[1].start, greaterThan(a.finalSegments[0].end));
    });
  });

  group('Speaker roles', () {
    // Speaker 1 is the doctor here, so the mapping cannot just rely on order.
    final exchange = [
      const DiarizedSegment(speakerIndex: 0, text: "Hi doctor. I've been having a terrible headache for three days.", start: 0, end: 3, isFinal: true),
      const DiarizedSegment(speakerIndex: 1, text: 'I am sorry to hear that. Where exactly is the pain? Any nausea or sensitivity to light?', start: 3, end: 7, isFinal: true),
      const DiarizedSegment(speakerIndex: 0, text: 'It hurts behind my right eye. I feel sick when the lights are bright.', start: 7, end: 10, isFinal: true),
      const DiarizedSegment(speakerIndex: 1, text: "Let me check your vitals and do a quick neuro exam. I'm going to prescribe sumatriptan 50 mg and we'll follow up in two weeks.", start: 10, end: 16, isFinal: true),
      const DiarizedSegment(speakerIndex: 0, text: 'Okay, thank you.', start: 16, end: 17, isFinal: true),
    ];

    test('the questioner using clinical language is the Doctor, the symptom reporter the Patient', () {
      final roles = SpeakerRoleMapper.assign(exchange);
      expect(roles, {1: SpeakerRole.doctor, 0: SpeakerRole.patient});
      final p = SpeakerRoleMapper.profile(exchange);
      expect(p[1]!.questions, 2);
      expect(p[1]!.clinicalTerms, greaterThanOrEqualTo(4));
      expect(p[0]!.symptomTerms, greaterThanOrEqualTo(3));
    });

    test('a third voice is Other, and overrides win', () {
      final withFamily = [
        ...exchange,
        const DiarizedSegment(speakerIndex: 2, text: 'She also missed work yesterday.', start: 17, end: 19, isFinal: true),
      ];
      final roles = SpeakerRoleMapper.assign(withFamily);
      expect(roles[1], SpeakerRole.doctor);
      expect(roles[0], SpeakerRole.patient);
      expect(roles[2], SpeakerRole.other);

      final swapped = SpeakerRoleMapper.assign(exchange, overrides: {0: SpeakerRole.doctor});
      expect(swapped, {0: SpeakerRole.doctor, 1: SpeakerRole.patient});
    });

    test('a single voice dictating is the Doctor', () {
      final roles = SpeakerRoleMapper.assign([
        const DiarizedSegment(speakerIndex: 0, text: 'Exam shows clear lungs. Start amoxicillin 500 mg three times daily.', start: 0, end: 5, isFinal: true),
      ]);
      expect(roles, {0: SpeakerRole.doctor});
    });

    test('each reconnect session gets its own Doctor and Patient', () {
      final roles = SpeakerRoleMapper.assign([
        ...exchange,
        const DiarizedSegment(speakerIndex: 100, text: 'My head still hurts a little.', start: 20, end: 22, isFinal: true),
        const DiarizedSegment(speakerIndex: 101, text: 'Any vomiting? Take the 50 mg tablet at onset.', start: 22, end: 25, isFinal: true),
      ]);
      expect(roles[100], SpeakerRole.patient);
      expect(roles[101], SpeakerRole.doctor);
    });

    test('buildLabeledTranscript writes Doctor/Patient lines the note engine parses', () {
      final text = buildLabeledTranscript(exchange);
      expect(
        text,
        "Patient: Hi doctor. I've been having a terrible headache for three days.\n"
        'Doctor: I am sorry to hear that. Where exactly is the pain? Any nausea or sensitivity to light?\n'
        'Patient: It hurts behind my right eye. I feel sick when the lights are bright.\n'
        "Doctor: Let me check your vitals and do a quick neuro exam. I'm going to prescribe sumatriptan 50 mg and we'll follow up in two weeks.\n"
        'Patient: Okay, thank you.',
      );
      final turns = ClinicalCoder.diarize(text);
      expect(turns.map((t) => t.speaker).toList(), ['Patient', 'Doctor', 'Patient', 'Doctor', 'Patient']);
    });

    test('interim segments are excluded unless asked for, Other is written as Caregiver', () {
      final segs = [
        const DiarizedSegment(speakerIndex: 0, text: 'Any fever?', start: 0, end: 1, isFinal: true),
        const DiarizedSegment(speakerIndex: 1, text: 'No fever.', start: 1, end: 2, isFinal: true),
        const DiarizedSegment(speakerIndex: 2, text: 'He had chills', start: 2, end: 3, isFinal: false),
      ];
      final roles = {0: SpeakerRole.doctor, 1: SpeakerRole.patient, 2: SpeakerRole.other};
      expect(buildLabeledTranscript(segs, roles: roles), 'Doctor: Any fever?\nPatient: No fever.');
      expect(buildLabeledTranscript(segs, roles: roles, includeInterim: true), 'Doctor: Any fever?\nPatient: No fever.\nCaregiver: He had chills');
      expect(buildLabeledTranscript(const []), isEmpty);
    });
  });

  group('DeepgramStreamingProvider with fakes', () {
    test('streams audio, labels turns, keeps alive while paused, closes cleanly', () async {
      final sockets = <FakeSocket>[];
      Uri? usedUri;
      Map<String, String>? usedHeaders;
      final audio = FakeAudio();
      final provider = DeepgramStreamingProvider(
        'test-key-not-real',
        audioSource: audio,
        keepAliveInterval: const Duration(milliseconds: 20),
        closeTimeout: const Duration(milliseconds: 500),
        socketFactory: (uri, headers) async {
          usedUri = uri;
          usedHeaders = headers;
          final s = FakeSocket()
            ..onText = (socket, text) {
              if (text.contains('CloseStream')) {
                // Deepgram flushes the last final result, then closes.
                scheduleMicrotask(() async {
                  socket.serverSends(results(say('Okay, thank you.', 1, 9), isFinal: true));
                  await socket.serverCloses(code: 1000, reason: '');
                });
              }
            };
          sockets.add(s);
          return s;
        },
      );

      final updates = <TranscriptUpdate>[];
      final sub = provider.start().listen(updates.add);
      await pump();

      expect(usedHeaders, {'Authorization': 'Token test-key-not-real'});
      expect(usedUri!.queryParameters['model'], 'nova-3-medical');
      expect(audio.sampleRate, 16000);
      expect(audio.channels, 1);
      expect(provider.status, TranscriptionStatus.listening);

      audio.speak(3200);
      await pump();
      expect(sockets.single.sentBytes.single.length, 3200);

      final s = sockets.single;
      s.serverSends(results(say('What brings you in?', 0, 0), isFinal: false));
      await pump();
      expect(updates.last.interim, 'What brings you in?');
      expect(updates.last.transcript, isEmpty);

      s.serverSends(results(say('What brings you in? Any chest pain?', 0, 0), isFinal: true, speechFinal: true));
      s.serverSends(results(say('I have chest pain and my arm hurts.', 1, 4), isFinal: true, speechFinal: true));
      await pump();
      expect(updates.last.transcript, 'Doctor: What brings you in? Any chest pain?\nPatient: I have chest pain and my arm hurts.');
      expect(updates.last.interim, isEmpty);
      expect(updates.last.roles, {0: SpeakerRole.doctor, 1: SpeakerRole.patient});

      await provider.pause();
      expect(audio.paused, isTrue);
      audio.speak(100); // ignored while paused
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(s.sentTypes.first, 'Finalize');
      expect(s.sentTypes.where((t) => t == 'KeepAlive').length, greaterThanOrEqualTo(2));
      expect(s.sentBytes.length, 1);
      expect(provider.status, TranscriptionStatus.paused);

      await provider.resume();
      final keepAlives = s.sentTypes.where((t) => t == 'KeepAlive').length;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(s.sentTypes.where((t) => t == 'KeepAlive').length, keepAlives, reason: 'no KeepAlive after resume');
      audio.speak(640);
      await pump();
      expect(s.sentBytes.length, 2);

      final finalText = await provider.stop();
      expect(s.sentTypes.last, 'CloseStream');
      expect(audio.stopped, isTrue);
      expect(audio.disposed, isTrue);
      expect(finalText, 'Doctor: What brings you in? Any chest pain?\nPatient: I have chest pain and my arm hurts. Okay, thank you.');
      expect(updates.last.status, TranscriptionStatus.stopped);
      expect(updates.where((u) => u.hasError), isEmpty);
      await sub.cancel();
    });

    test('reconnects once after an unexpected close, then reports failure on the stream', () async {
      final sockets = <FakeSocket>[];
      final audio = FakeAudio();
      final provider = DeepgramStreamingProvider(
        'test-key-not-real',
        audioSource: audio,
        closeTimeout: const Duration(milliseconds: 50),
        socketFactory: (uri, headers) async {
          final s = FakeSocket();
          sockets.add(s);
          return s;
        },
      );
      final updates = <TranscriptUpdate>[];
      final sub = provider.start().listen(updates.add);
      await pump();

      sockets[0].serverSends(results(say('Where does it hurt?', 0, 0), isFinal: true));
      sockets[0].serverSends(results(say('My lower back hurts', 1, 2), isFinal: false));
      await pump();
      await sockets[0].serverCloses();
      await pump();

      expect(sockets.length, 2, reason: 'one reconnect');
      expect(updates.any((u) => u.status == TranscriptionStatus.reconnecting), isTrue);
      expect(provider.status, TranscriptionStatus.listening);
      // The interim words heard before the drop were kept.
      expect(provider.transcript, contains('My lower back hurts'));

      audio.speak(320);
      await pump();
      expect(sockets[1].sentBytes.length, 1);

      sockets[1].serverSends(results(say('Any numbness in your legs?', 0, 0), isFinal: true));
      await pump();
      final last = provider.assembler.finalSegments.last;
      expect(last.speakerIndex, 100);
      expect(last.start, greaterThan(2.0));

      await sockets[1].serverCloses(code: 1011, reason: 'NET-0001');
      await pump();
      expect(sockets.length, 2, reason: 'only one reconnect');
      expect(updates.last.status, TranscriptionStatus.failed);
      expect(updates.last.error, contains('NET-0001'));

      final text = await provider.stop();
      expect(text, contains('Where does it hurt?'));
      expect(text, contains('Any numbness in your legs?'));
      await sub.cancel();
    });

    test('connection failure and missing permission surface as errors, not exceptions', () async {
      final failing = DeepgramStreamingProvider(
        'test-key-not-real',
        audioSource: FakeAudio(),
        socketFactory: (uri, headers) async => throw Exception('HTTP 401 Unauthorized'),
      );
      final u1 = await failing.start().firstWhere((u) => u.hasError);
      expect(u1.status, TranscriptionStatus.failed);
      expect(u1.error, contains('API key'));
      expect(await failing.stop(), isEmpty);

      final denied = DeepgramStreamingProvider(
        'test-key-not-real',
        audioSource: FakeAudio()..permission = false,
        socketFactory: (uri, headers) async => FakeSocket(),
      );
      final u2 = await denied.start().firstWhere((u) => u.hasError);
      expect(u2.error, contains('Microphone permission'));
      await denied.stop();

      final noKey = DeepgramStreamingProvider('', audioSource: FakeAudio(), socketFactory: (uri, headers) async => FakeSocket());
      final u3 = await noKey.start().firstWhere((u) => u.hasError);
      expect(u3.error, contains('No Deepgram API key'));
      await noKey.stop();
    });

    test('a provider Error message is surfaced and the session keeps going', () async {
      final socket = FakeSocket();
      final provider = DeepgramStreamingProvider(
        'test-key-not-real',
        audioSource: FakeAudio(),
        closeTimeout: const Duration(milliseconds: 20),
        socketFactory: (uri, headers) async => socket,
      );
      final updates = <TranscriptUpdate>[];
      final sub = provider.start().listen(updates.add);
      await pump();
      socket.serverSends(jsonEncode({'type': 'Error', 'variant': 'Configure', 'description': 'Keyterm rejected', 'code': 'BAD', 'message': ''}));
      socket.serverSends(results(say('Take a deep breath.', 0, 0), isFinal: true));
      await pump();
      expect(updates.any((u) => u.error?.contains('Keyterm rejected') ?? false), isTrue);
      expect(updates.last.transcript, 'Doctor: Take a deep breath.');
      await provider.stop();
      await sub.cancel();
    });
  });
}
