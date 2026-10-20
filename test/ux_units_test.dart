import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/screens/claim_tab.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/place_of_service.dart';
import 'package:solis_mobile/services/note_seal.dart';
import 'package:solis_mobile/services/places.dart';
import 'package:solis_mobile/services/transcription/deepgram_provider.dart';
import 'package:solis_mobile/services/transcription/engine_selector.dart';
import 'package:solis_mobile/services/transcription/transcription_provider.dart';

import 'support/test_provider.dart';

/// Microphone that plays back scripted PCM blocks.
class _Mic implements AudioCaptureSource {
  final controller = StreamController<Uint8List>();
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<Stream<Uint8List>> start({required int sampleRate, required int channels}) async => controller.stream;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _Socket implements TranscriptionSocket {
  final _in = StreamController<dynamic>();
  @override
  Stream<dynamic> get messages => _in.stream;
  @override
  void sendBytes(List<int> bytes) {}
  @override
  void sendText(String text) {}
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

Uint8List _sine(double amplitude, {int samples = 1600}) {
  final b = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    b.setInt16(i * 2, (amplitude * 32767 * math.sin(i / 8)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  group('Note seal', () {
    final at = DateTime.utc(2026, 10, 15, 16, 10, 5);
    test('is a real SHA-256 that changes with any edit, the signer or the time', () {
      final seal = NoteSeal.compute(noteText: 'SUBJECTIVE\nCough', signerNpi: '1234567893', signedAtUtc: at);
      expect(seal, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(NoteSeal.verify(seal: seal, noteText: 'SUBJECTIVE\nCough', signerNpi: '1234567893', signedAtUtc: at), isTrue);
      expect(NoteSeal.compute(noteText: 'SUBJECTIVE\nCough.', signerNpi: '1234567893', signedAtUtc: at), isNot(seal));
      expect(NoteSeal.compute(noteText: 'SUBJECTIVE\nCough', signerNpi: '1982736450', signedAtUtc: at), isNot(seal));
      expect(NoteSeal.compute(noteText: 'SUBJECTIVE\nCough', signerNpi: '1234567893', signedAtUtc: at.add(const Duration(seconds: 1))), isNot(seal));
      // Line endings and trailing spaces do not change what was signed.
      expect(NoteSeal.compute(noteText: 'SUBJECTIVE  \r\nCough\n', signerNpi: '1234567893', signedAtUtc: at), seal);
      expect(NoteSeal.verify(seal: '', noteText: 'x', signerNpi: '1', signedAtUtc: at), isFalse);
    });

    test('an unsigned encounter has no seal; clearing the signature removes it', () {
      final e = ClinicalEncounter(
        id: 'e', patientName: 'p', mrn: 'm', ageGender: '50F', attendingPhysician: 'a', date: '2026-10-15',
        vitals: const [], subjective: '', objective: '', assessment: '', plan: '', codes: const [],
      );
      expect(e.sha256Seal, isEmpty);
      final signed = e.copyWith(isSigned: true, signedAtUtc: at, sha256Seal: 'abc');
      final reopened = signed.copyWith(clearSignature: true);
      expect(reopened.isSigned, isFalse);
      expect(reopened.sha256Seal, isEmpty);
      expect(reopened.signedAtUtc, isNull);
      expect(ClinicalEncounter.fromJson(signed.toJson()).signedAtUtc, at);
    });
  });

  group('Microphone level', () {
    test('silence is 0, speech is high, and PCM maps through dBFS', () {
      expect(pcm16Level(Uint8List(3200)), 0);
      expect(pcm16Level(Uint8List(0)), 0);
      expect(pcm16Level(_sine(0.5)), greaterThan(0.8));
      expect(pcm16Level(_sine(0.002)), lessThan(0.2));
      expect(dbfsToLevel(-60), 0);
      expect(dbfsToLevel(-10), 1);
      expect(dbfsToLevel(-35), closeTo(0.5, 0.001));
    });

    test('the Deepgram engine reports the level of the audio it streams', () async {
      final mic = _Mic();
      final p = DeepgramStreamingProvider('key', socketFactory: (_, _) async => _Socket(), audioSource: mic);
      final sub = p.start().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      mic.controller.add(_sine(0.5));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(p.audioLevel.value, greaterThan(0.8));
      mic.controller.add(Uint8List(3200));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(p.audioLevel.value, 0);
      await p.stop();
      await sub.cancel();
    });
  });

  group('Recognizer settings', () {
    test('Spanish and English switches Deepgram to multilingual Nova-3 and Android to es-US', () {
      const en = CaptureSettings();
      expect(en.deepgramOptions.buildUri().queryParameters['model'], 'nova-3-medical');
      expect(en.deepgramOptions.buildUri().queryParameters['language'], 'en-US');
      const both = CaptureSettings(language: SpeechLanguage.spanishEnglish);
      expect(both.deepgramOptions.buildUri().queryParameters['model'], 'nova-3');
      expect(both.deepgramOptions.buildUri().queryParameters['language'], 'multi');
      expect(SpeechLanguage.spanishEnglish.androidLocale, 'es-US');
    });

    test('the on-device engine gets the noise setting and is skipped for Spanish', () {
      bool? asked;
      SpeechEngines.onDeviceFactory = ({bool noiseSuppression = true}) {
        asked = noiseSuppression;
        return null;
      };
      addTearDown(() => SpeechEngines.onDeviceFactory = null);
      SpeechEngines.pick(onDevice: true, settings: const CaptureSettings(noiseSuppression: false));
      expect(asked, isFalse);
      asked = null;
      SpeechEngines.pick(onDevice: true, settings: const CaptureSettings(language: SpeechLanguage.spanishEnglish));
      expect(asked, isNull, reason: 'English-only models are not used for Spanish');
    });
  });

  group('Saved places and the place of service', () {
    const snf = SavedPlace(id: '1', name: 'Sunrise SNF', placeOfService: '31', latitude: 37.7749, longitude: -122.4194, radiusMeters: 150);
    Map<String, dynamic> at(double lat, double lng, {double acc = 10}) => {'available': true, 'latitude': lat, 'longitude': lng, 'accuracy': acc};

    test('a fix inside the radius matches; outside, imprecise or missing does not', () {
      expect(matchSavedPlace([snf], at(37.7750, -122.4195))?.name, 'Sunrise SNF');
      expect(matchSavedPlace([snf], at(37.7800, -122.4194)), isNull, reason: 'about 570 m away');
      expect(matchSavedPlace([snf], at(37.7750, -122.4195, acc: 500)), isNull);
      expect(matchSavedPlace([snf], const {'available': false}), isNull);
    });

    test('new visits use a matched place, then a recent last visit, then the default', () {
      final provider = testProvider().copyWith(savedPlaces: const [snf], defaultPlaceOfService: '11');
      final account = PatientAccount(
        accountNumber: 'SOL-1',
        firstName: 'A',
        lastName: 'B',
        createdAtUtc: DateTime(2026),
        visits: [Visit(number: 1, dateOfService: '2026-10-01', placeOfService: '32', createdAtUtc: DateTime(2026))],
      );
      expect(choosePlaceOfService(provider: provider, account: account, gps: at(37.7750, -122.4195), now: DateTime(2026, 10, 15)).code, '31');
      final last = choosePlaceOfService(provider: provider, account: account, now: DateTime(2026, 10, 15));
      expect((last.code, last.source), ('32', 'last visit'));
      final def = choosePlaceOfService(provider: provider, account: account, now: DateTime(2026, 12, 15));
      expect((def.code, def.source), ('11', 'default'));
    });
  });

  group('Claim fixes', () {
    final provider = testProvider();
    PatientAccount account({int visits = 1}) => PatientAccount(
          accountNumber: 'SOL-1',
          firstName: 'A',
          lastName: 'B',
          sex: PatientSex.female,
          dateOfBirth: DateTime(1970),
          createdAtUtc: DateTime(2026),
          insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: 'W1', payerId: '60054'),
          visits: [for (var i = 1; i <= visits; i++) Visit(number: i, dateOfService: '2026-10-1$i', placeOfService: '10', createdAtUtc: DateTime(2026))],
        );
    ClaimDraft claim(String em) => ClaimDraft(
          generatedAtUtc: DateTime(2026),
          diagnoses: const [ClaimDiagnosis(code: 'J06.9', description: 'URI', source: DxSource.physicianConfirmed)],
          lines: [ServiceLine(code: em, description: 'Visit', charge: 100, diagnosisCodes: const ['J06.9'])],
        );

    test('a new-patient code on a return telehealth visit gets one-tap fixes', () {
      final a = account(visits: 2);
      final issues = ClaimScrubber.check(claim: claim('99204'), account: a, visit: a.visits.last, provider: provider, noteSigned: false);
      final newPt = issues.firstWhere((i) => i.ruleId == 'CLAIM-NEWPT-01');
      expect(newPt.fix!.kind, FixKind.replaceService);
      expect(newPt.fix!.replacement, '99214');
      expect(newPt.fix!.label, 'Use 99214');
      final tele = issues.firstWhere((i) => i.ruleId == 'CLAIM-TELEHEALTH-01');
      expect((tele.fix!.kind, tele.fix!.replacement), (FixKind.addModifier, '95'));
      expect(issues.firstWhere((i) => i.ruleId == 'CLAIM-SIGNED-01').fix!.kind, FixKind.signNote);

      final fixed = applyClaimFix(claim('99204'), newPt.fix!, provider.feeSchedule)!;
      expect(fixed.lines.single.code, '99214');
      expect(fixed.lines.single.diagnosisCodes, ['J06.9'], reason: 'pointers stay');
      expect(fixed.lines.single.charge, provider.feeSchedule['99214']);
      final withMod = applyClaimFix(claim('99204'), tele.fix!, provider.feeSchedule)!;
      expect(withMod.lines.single.modifiers, ['95']);
      expect(applyClaimFix(withMod, tele.fix!, provider.feeSchedule), isNull, reason: 'already applied');
    });

    test('a judgment call has no automatic fix', () {
      final a = account();
      final c = ClaimDraft(
        generatedAtUtc: DateTime(2026),
        diagnoses: const [ClaimDiagnosis(code: 'J06.9', description: 'URI', source: DxSource.physicianConfirmed)],
        lines: const [ServiceLine(code: '99213', description: 'Visit', charge: 100)],
      );
      final pointer = ClaimScrubber.check(claim: c, account: a, visit: a.visits.single, provider: provider, noteSigned: true)
          .firstWhere((i) => i.ruleId == 'CLAIM-POINTER-01');
      expect(pointer.fix, isNull);
    });

    test('E/M levels change within the family, keep pointers and say who chose', () {
      expect(emFamily('99204'), ['99202', '99203', '99204', '99205']);
      expect(emFamily('99310'), contains('99307'));
      expect(emFamily('93000'), isEmpty);
      final changed = changeEmLevel(claim('99214'), 0, '99213', provider.feeSchedule);
      expect(changed.lines.single.code, '99213');
      expect(changed.lines.single.description, emDescription('99213'));
      expect(changed.lines.single.evidence, contains('Level chosen by physician'));
      expect(changed.lines.single.diagnosisCodes, ['J06.9']);
    });

    test('a missing placeholder X offers the corrected code', () {
      final fix = ClaimScrubber.fixFor(
        const ClaimIssue(IssueSeverity.error, 'x', 'y', ruleId: 'CLAIM-PAYER-01'),
        claim('99213'),
      );
      expect(fix!.kind, FixKind.scanCard);
      final replaced = applyClaimFix(
        claim('99213').copyWith(diagnoses: const [ClaimDiagnosis(code: 'T74.4A', description: 'Shaken infant', source: DxSource.manual)]),
        const IssueFix(FixKind.replaceDiagnosis, 'Use T74.4XXA', code: 'T74.4A', replacement: 'T74.4XXA'),
        provider.feeSchedule,
      )!;
      expect(replaced.billable.single.code, 'T74.4XXA');
    });
  });

  group('Patients', () {
    test('a deleted patient is hidden, restorable, then erased after 30 days', () async {
      final repo = AccountRepository.memory();
      final a = await repo.createAccount(firstName: 'Ann', lastName: 'Lee');
      final t0 = DateTime.utc(2026, 10, 1);
      await repo.deletePatient(a.accountNumber, now: t0);
      expect(repo.accounts, isEmpty);
      expect(repo.byNumber(a.accountNumber), isNull);
      expect(repo.recentlyDeleted.single.accountNumber, a.accountNumber);
      expect(await repo.restorePatient(a.accountNumber), isTrue);
      expect(repo.accounts.single.accountNumber, a.accountNumber);

      await repo.deletePatient(a.accountNumber, now: t0);
      expect(await repo.purgeExpired(now: t0.add(const Duration(days: 29))), 0);
      expect(await repo.purgeExpired(now: t0.add(const Duration(days: 31))), 1);
      expect(repo.recentlyDeleted, isEmpty);
      expect(await repo.restorePatient(a.accountNumber), isFalse);
    });

    test('orders default to included only when STAT or urgent, and keep the choice in JSON', () {
      final routine = ClinicalActionItem(id: '1', linkedCode: '', category: ActionCategory.order, title: 'CBC', description: '');
      final stat = ClinicalActionItem(id: '2', linkedCode: '', category: ActionCategory.order, title: 'Troponin', description: '', urgency: 'STAT');
      expect(routine.included, isFalse);
      expect(stat.included, isTrue);
      routine.included = true;
      expect(ClinicalActionItem.fromJson(routine.toJson()).included, isTrue);
      expect(ClinicalActionItem.fromJson({'urgency': 'Urgent'}).included, isTrue);
    });

    test('a declined consent round-trips and says so', () {
      final c = ConsentRecord(method: 'declined', atUtc: DateTime.utc(2026, 10, 15, 10, 42), language: 'es');
      final back = ConsentRecord.fromJson(c.toJson());
      expect(back.declined, isTrue);
      expect(back.language, 'es');
    });
  });
}
