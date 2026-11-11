import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/data/sample_conversations.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/encounter_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

Future<(AccountRepository, String, int)> _visit() async {
  final repo = AccountRepository.memory();
  AccountRepository.instance = repo;
  await repo.seedDemoIfEmpty();
  final a = repo.accounts.firstWhere((a) => a.firstName == 'Margaret');
  final v = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: '11');
  return (repo, a.accountNumber, v.number);
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: home));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

String get _talk => sampleConversations['Diabetic Peripheral Neuropathy']!;

void main() {
  test('a running recording is saved with the visit and cleared', () {
    final cp = RecordingCheckpoint(startedAtUtc: DateTime.utc(2026, 11, 11, 9), savedAtUtc: DateTime.utc(2026, 11, 11, 9, 4), seconds: 240);
    final v = Visit(number: 1, dateOfService: '2026-11-11', placeOfService: '11', createdAtUtc: DateTime.utc(2026, 11, 11), liveRecording: cp);
    final back = Visit.fromJson(v.toJson());
    expect(back.liveRecording!.seconds, 240);
    expect(back.liveRecording!.savedAtUtc, cp.savedAtUtc);
    expect(back.copyWith(clearLiveRecording: true).toJson().containsKey('liveRecording'), isFalse);
    expect(Visit.fromJson({...v.toJson(), 'liveRecording': 'junk'}).liveRecording, isNull);
  });

  testWidgets('a recording cut off by the app closing is kept and can continue', (tester) async {
    final (repo, acct, n) = await _visit();
    final visit = repo.byNumber(acct)!.visit(n)!;
    await repo.updateVisit(
      acct,
      visit.copyWith(
        transcript: _talk,
        consentConfirmed: true,
        consentAtUtc: DateTime.now().toUtc(),
        liveRecording: RecordingCheckpoint(startedAtUtc: DateTime.now().toUtc(), savedAtUtc: DateTime.now().toUtc(), seconds: 312),
      ),
    );
    await _pump(tester, EncounterScreen(accountNumber: acct, visitNumber: n));
    expect(find.byKey(const Key('recording_interrupted')), findsOneWidget);
    expect(find.textContaining('5 min 12 s'), findsOneWidget);
    expect(find.byKey(const Key('resume_recording')), findsOneWidget);
    // The transcript is kept and the note is written from it.
    expect(repo.byNumber(acct)!.visit(n)!.transcript, _talk);
    expect(find.text('Nothing documented.'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('dismiss_interrupted')));
    await tester.tap(find.byKey(const Key('dismiss_interrupted')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('recording_interrupted')), findsNothing);
    expect(repo.byNumber(acct)!.visit(n)!.liveRecording, isNull);
    expect(repo.byNumber(acct)!.visit(n)!.transcript, _talk);
    await _drain(tester);
  });

  testWidgets('a note sentence nobody said is flagged; tapping shows each source', (tester) async {
    final (repo, acct, n) = await _visit();
    final enc = LocalClinicalEngine.synthesizeOnDevice(rawSpeech: _talk, patientName: 'Margaret Vance', mrn: '1', ageGender: '67F', attending: 'Dr. Lin');
    final invented = enc.copyWith(subjective: '${enc.subjective.trim()} History of stroke with left sided weakness.');
    final visit = repo.byNumber(acct)!.visit(n)!;
    await repo.updateVisit(acct, visit.copyWith(transcript: _talk, encounter: invented.toJson()));

    await _pump(tester, EncounterScreen(accountNumber: acct, visitNumber: n));
    expect(find.textContaining('without a source'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('note_subjective')));
    await tester.pump();
    // The top of the section: its centre can sit under the bottom bar.
    await tester.tapAt(tester.getTopLeft(find.byKey(const Key('note_subjective'))) + const Offset(20, 10));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('sources_sheet')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('no_source')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('sources_sheet')), matching: find.byType(Scrollable)).first);
    expect(find.byKey(const Key('no_source')), findsOneWidget);
    expect(find.textContaining('History of stroke with left sided weakness.'), findsWidgets);
    expect(find.textContaining('Patient: '), findsWidgets);
    await _drain(tester);
  });
}
