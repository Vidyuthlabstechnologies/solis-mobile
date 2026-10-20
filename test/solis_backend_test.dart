import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solis_mobile/services/billing/stedi_client.dart';
import 'package:solis_mobile/services/billing/integration_settings.dart';
import 'package:solis_mobile/services/integrations.dart';
import 'package:solis_mobile/services/solis_backend.dart';
import 'package:solis_mobile/services/transcription/deepgram_provider.dart';
import 'package:solis_mobile/services/transcription/engine_selector.dart';

void main() {
  final base = Uri.parse('https://solis.example.workers.dev');

  test('without an app token the backend is off and never calls out', () async {
    var calls = 0;
    final b = SolisBackend(baseUrl: base, appToken: '', httpClient: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    expect(b.isConfigured, isFalse);
    await expectLater(b.writeNote(transcript: 'x'), throwsA(isA<BackendException>()));
    expect(calls, 0);
  });

  test('writeNote sends the bearer token and parses the note', () async {
    late http.Request seen;
    final b = SolisBackend(
      baseUrl: base,
      appToken: 'tok123',
      httpClient: MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'success': true,
            'provider': 'anthropic',
            'model': 'claude',
            'note': {
              'soap': {
                'subjective': ['Headache for two days.'],
                'objective': ['BP 150/95.'],
                'assessment': ['Migraine with aura.'],
                'plan': ['Sumatriptan.', ''],
              },
              'vitals': [
                {'name': 'Blood pressure', 'value': '150/95', 'unit': 'mmHg'},
              ],
              'diagnoses': [
                {
                  'description': 'Migraine with aura',
                  'icd10Candidate': 'g43.109',
                  'certainty': 'confirmed',
                  'evidence': [
                    {'quote': 'classic migraine with aura', 'matched': true},
                  ],
                },
              ],
            },
            'warnings': [],
          }),
          200,
        );
      }),
    );
    final note = await b.writeNote(transcript: 'Doctor: hello', age: 45, sex: 'male');
    expect(seen.url.toString(), 'https://solis.example.workers.dev/api/v2/note');
    expect(seen.headers['Authorization'], 'Bearer tok123');
    expect(jsonDecode(seen.body)['patient'], {'age': 45, 'sex': 'male'});
    expect(note.provider, 'anthropic');
    expect(note.plan, ['Sumatriptan.']);
    expect(note.vitals.single.display, '150/95 mmHg');
    expect(note.diagnoses.single.icd10Candidate, 'G43.109');
    expect(note.diagnoses.single.confirmed, isTrue);
    expect(note.diagnoses.single.evidence, 'classic migraine with aura');
  });

  test('server errors become readable messages', () async {
    final b = SolisBackend(baseUrl: base, appToken: 't', httpClient: MockClient((_) async => http.Response('{"error":"x"}', 401)));
    await expectLater(
      b.writeNote(transcript: 'x'),
      throwsA(isA<BackendException>().having((e) => e.status, 'status', 401).having((e) => e.message, 'message', contains('not authorized'))),
    );
  });

  test('Stedi through the backend uses the server routes and the app token', () async {
    final urls = <String>[];
    final auths = <String?>[];
    final backend = SolisBackend(baseUrl: base, appToken: 'tok', httpClient: http.Client());
    final client = StediClient.viaBackend(
      backend,
      httpClient: MockClient((req) async {
        urls.add(req.url.toString());
        auths.add(req.headers['Authorization']);
        return http.Response('{}', 200);
      }),
    );
    await client.submitClaim('ISA*00*~', idempotencyKey: 'v1');
    expect(urls, [
      'https://solis.example.workers.dev/api/v2/stedi/claims-x12',
    ]);
    expect(auths.toSet(), {'Bearer tok'});
  });

  group('voice engine choice', () {
    tearDown(() {
      SolisBackend.instance = SolisBackend();
      Integrations.settings = IntegrationSettings.inMemory();
      SpeechEngines.onDeviceFactory = null;
    });

    test('nothing configured falls back to basic recognition', () {
      SolisBackend.instance = SolisBackend(appToken: '');
      Integrations.settings = IntegrationSettings.inMemory();
      expect(SpeechEngines.pick(onDevice: false), isNull);
      expect(SpeechEngines.pick(onDevice: true), isNull);
    });

    test('cloud mode uses Deepgram through the server when a token is built in', () {
      SolisBackend.instance = SolisBackend(appToken: 'tok');
      Integrations.settings = IntegrationSettings.inMemory();
      final picked = SpeechEngines.pick(onDevice: false);
      expect(picked?.$1, isA<DeepgramStreamingProvider>());
      expect(picked?.$2, SpeechEngine.cloud);
    });

    test('on-device mode never picks the cloud engine', () {
      SolisBackend.instance = SolisBackend(appToken: 'tok');
      expect(SpeechEngines.pick(onDevice: true), isNull);
    });
  });
}
