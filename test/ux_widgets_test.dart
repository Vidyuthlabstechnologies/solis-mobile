import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/screens/encounter_screen.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/screens/patients_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/billing/claim_submission_service.dart';
import 'package:solis_mobile/services/transcription/engine_selector.dart';
import 'package:solis_mobile/services/transcription/transcription_provider.dart';
import 'package:solis_mobile/theme/solis_theme.dart';
import 'package:solis_mobile/widgets/encounter_widgets.dart';
import 'package:solis_mobile/widgets/signature_pad.dart';

import 'support/billing_fixtures.dart';
import 'support/fake_clearinghouse.dart';

/// A recording engine that hears nothing until the test says so.
class _QuietEngine implements TranscriptionProvider, AudioLevelSource {
  final level = ValueNotifier<double>(0);
  final _out = StreamController<TranscriptUpdate>();
  @override
  ValueListenable<double> get audioLevel => level;
  @override
  Stream<TranscriptUpdate> start() => _out.stream;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<String> stop() async {
    if (!_out.isClosed) await _out.close();
    return '';
  }
}

const _security = MethodChannel('com.solis.clinical/security');
const _recording = MethodChannel('com.solis.clinical/recording');
Map<String, dynamic> _gps = const {'available': false, 'reason': 'unsupported'};
final _platformCalls = <String>[];

void _mockPlatform() {
  _platformCalls.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_recording, (call) async {
    _platformCalls.add('recording.${call.method}');
    return true;
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_security, (call) async {
    _platformCalls.add('security.${call.method}');
    switch (call.method) {
      case 'getGpsCoordinates':
        return _gps;
      case 'checkSecurityPosture':
        return {'isTampered': false};
      default:
        return true;
    }
  });
}

Future<AccountRepository> _demo() async {
  final repo = AccountRepository.memory();
  AccountRepository.instance = repo;
  await repo.seedDemoIfEmpty();
  return repo;
}

Future<(String, int)> _visit(AccountRepository repo, String firstName, {String pos = '11'}) async {
  final a = repo.accounts.firstWhere((a) => a.firstName == firstName);
  final v = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: pos);
  return (a.accountNumber, v.number);
}

Future<void> _pump(WidgetTester t, Widget home, {Size size = const Size(412, 915)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: home));
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
}

Future<void> _drain(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 5));
}

/// The review tab's list (not the app bar's session strip).
Finder _list() => find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;

Future<void> _sample(WidgetTester t) async {
  await t.ensureVisible(find.text('Sample conversation'));
  await t.tap(find.text('Sample conversation'));
  await _settle(t);
  await t.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() {
    _gps = const {'available': false, 'reason': 'unsupported'};
    _mockPlatform();
  });
  tearDown(() {
    SpeechEngines.override = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_security, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_recording, null);
  });

  testWidgets('the record button works with TalkBack (semantic tap)', (t) async {
    final handle = t.ensureSemantics();
    var taps = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: RecordButton(onPressed: () => taps++)))));
    expect(t.getSemantics(find.bySemanticsLabel('Start recording')), matchesSemantics(label: 'Start recording', isButton: true, hasTapAction: true, hasEnabledState: true, isEnabled: true));
    t.semantics.tap(find.semantics.byLabel('Start recording'));
    await t.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('the level meter shows the real level, flat when silent', (t) async {
    final handle = t.ensureSemantics();
    final level = ValueNotifier<double>(0);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: LevelMeter(level: level, active: true, color: Colors.red)))));
    expect(find.bySemanticsLabel('Microphone level 0 percent'), findsOneWidget);
    level.value = 0.8;
    await t.pump();
    expect(find.bySemanticsLabel('Microphone level 80 percent'), findsOneWidget);
    final tallest = t.widgetList<Container>(find.byType(Container)).map((c) => c.constraints?.maxHeight ?? 0).reduce((a, b) => a > b ? a : b);
    expect(tallest, greaterThan(20));
    handle.dispose();
  });

  testWidgets('a silent microphone is reported within 10 seconds, and clears when sound arrives', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await repo.updateVisit(acct, repo.byNumber(acct)!.visit(n)!.copyWith(
          consentConfirmed: true,
          consentAtUtc: DateTime.now().toUtc(),
          consent: ConsentRecord(method: 'verbal', atUtc: DateTime.now().toUtc()),
        ));
    final engine = _QuietEngine();
    SpeechEngines.override = ({required bool onDevice}) => engine;
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    await t.tap(find.bySemanticsLabel('Start recording'));
    await _settle(t);
    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('No sound'), findsNothing);
    for (var i = 0; i < 11; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.text('No sound'), findsOneWidget);
    expect(find.text('SOLIS hears nothing. Check the microphone.'), findsWidgets);
    engine.level.value = 0.7;
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('No sound'), findsNothing);
    await _drain(t);
  });

  testWidgets('recording runs the microphone foreground service; its Stop action stops the recording', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await repo.updateVisit(acct, repo.byNumber(acct)!.visit(n)!.copyWith(
          consentConfirmed: true,
          consentAtUtc: DateTime.now().toUtc(),
          consent: ConsentRecord(method: 'verbal', atUtc: DateTime.now().toUtc()),
        ));
    final engine = _QuietEngine();
    SpeechEngines.override = ({required bool onDevice}) => engine;
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    _platformCalls.clear();
    await t.tap(find.bySemanticsLabel('Start recording'));
    await _settle(t);
    expect(find.text('Recording'), findsOneWidget);
    final recordingCalls = _platformCalls.where((c) => c.startsWith('recording.')).toList();
    expect(recordingCalls, ['recording.requestNotificationPermission', 'recording.start']);
    expect(_platformCalls, isNot(contains('security.acquireBackgroundWakeLock')), reason: 'the service holds the wake lock');

    // Stop pressed in the notification.
    _platformCalls.clear();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      _recording.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('stopRequested')),
      (_) {},
    );
    await _settle(t);
    expect(find.text('Recording'), findsNothing);
    expect(_platformCalls, contains('recording.stop'));
    await _drain(t);
  });

  testWidgets('without the foreground service the screen keeps the wake lock itself', (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_recording, (call) async {
      _platformCalls.add('recording.${call.method}');
      return call.method == 'start' ? false : true;
    });
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await repo.updateVisit(acct, repo.byNumber(acct)!.visit(n)!.copyWith(
          consentConfirmed: true,
          consentAtUtc: DateTime.now().toUtc(),
          consent: ConsentRecord(method: 'verbal', atUtc: DateTime.now().toUtc()),
        ));
    final engine = _QuietEngine();
    SpeechEngines.override = ({required bool onDevice}) => engine;
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    _platformCalls.clear();
    await t.tap(find.bySemanticsLabel('Start recording'));
    await _settle(t);
    expect(find.text('Recording'), findsOneWidget);
    expect(_platformCalls, containsAllInOrder(['recording.start', 'security.acquireBackgroundWakeLock']));
    await _drain(t);
    expect(_platformCalls, contains('security.releaseBackgroundWakeLock'));
  });

  testWidgets('recording runs the microphone foreground service; its Stop action stops the recording', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await repo.updateVisit(acct, repo.byNumber(acct)!.visit(n)!.copyWith(
          consentConfirmed: true,
          consentAtUtc: DateTime.now().toUtc(),
          consent: ConsentRecord(method: 'verbal', atUtc: DateTime.now().toUtc()),
        ));
    final engine = _QuietEngine();
    SpeechEngines.override = ({required bool onDevice}) => engine;
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    _platformCalls.clear();
    await t.tap(find.bySemanticsLabel('Start recording'));
    await _settle(t);
    expect(find.text('Recording'), findsOneWidget);
    final recordingCalls = _platformCalls.where((c) => c.startsWith('recording.')).toList();
    expect(recordingCalls, ['recording.requestNotificationPermission', 'recording.start']);
    expect(_platformCalls, isNot(contains('security.acquireBackgroundWakeLock')), reason: 'the service holds the wake lock');

    // Stop pressed in the notification.
    _platformCalls.clear();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      _recording.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('stopRequested')),
      (_) {},
    );
    await _settle(t);
    expect(find.text('Recording'), findsNothing);
    expect(_platformCalls, contains('recording.stop'));
    await _drain(t);
  });

  testWidgets('without the foreground service the screen keeps the wake lock itself', (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_recording, (call) async {
      _platformCalls.add('recording.${call.method}');
      return call.method == 'start' ? false : true;
    });
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await repo.updateVisit(acct, repo.byNumber(acct)!.visit(n)!.copyWith(
          consentConfirmed: true,
          consentAtUtc: DateTime.now().toUtc(),
          consent: ConsentRecord(method: 'verbal', atUtc: DateTime.now().toUtc()),
        ));
    final engine = _QuietEngine();
    SpeechEngines.override = ({required bool onDevice}) => engine;
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    _platformCalls.clear();
    await t.tap(find.bySemanticsLabel('Start recording'));
    await _settle(t);
    expect(find.text('Recording'), findsOneWidget);
    expect(_platformCalls, containsAllInOrder(['recording.start', 'security.acquireBackgroundWakeLock']));
    await _drain(t);
    expect(_platformCalls, contains('security.releaseBackgroundWakeLock'));
  });

  testWidgets('orders: ticks are saved, Mark as sent persists and Undo reverts', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Robert', pos: '23');
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    await _sample(t);
    await t.tap(find.text('Orders'));
    await _settle(t);
    List<Map> steps() => [for (final s in (repo.byNumber(acct)!.visit(n)!.encounter!['nextSteps'] as List)) s as Map];
    final included = steps().where((s) => s['included'] == true).length;
    expect(included, greaterThan(0), reason: 'STAT and urgent orders start ticked');
    expect(find.text('Mark $included ${included == 1 ? 'order' : 'orders'} as sent'), findsOneWidget);

    // Ticking a routine order is saved at once.
    final unchecked = find.byWidgetPredicate((w) => w is Checkbox && w.value == false);
    if (steps().any((s) => s['included'] != true)) {
      for (var i = 0; i < 20 && unchecked.evaluate().isEmpty; i++) {
        await t.drag(_list(), const Offset(0, -200));
        await t.pump();
      }
      await t.ensureVisible(unchecked.first);
      await t.pump();
      await t.tap(unchecked.first);
      await _settle(t);
      expect(steps().where((s) => s['included'] == true).length, included + 1);
    }
    final toMark = steps().where((s) => s['included'] == true).length;
    await t.tap(find.byKey(const Key('mark_orders_sent')));
    await _settle(t);
    expect(steps().where((s) => s['isCompleted'] == true).length, toMark);
    expect(find.text('Marked sent'), findsWidgets);
    await t.tap(find.text('Undo'));
    await _settle(t);
    expect(steps().where((s) => s['isCompleted'] == true), isEmpty);
    await _drain(t);
  });

  testWidgets('removing a code offers Undo; the E/M level changes in one tap', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    await _sample(t);
    await t.tap(find.text('Claim'));
    await _settle(t);
    final lines = repo.byNumber(acct)!.visit(n)!.claim!.lines;
    final em = lines.firstWhere((l) => l.isEvaluationAndManagement);
    await t.scrollUntilVisible(find.textContaining('Why this level:'), 200, scrollable: _list());
    expect(find.textContaining('Why this level:'), findsOneWidget);

    // One tap on another level of the family.
    final other = em.code == '99203' ? '99204' : '99203';
    await t.ensureVisible(find.byKey(Key('em_level_$other')));
    await t.pump();
    await t.tap(find.byKey(Key('em_level_$other')));
    await _settle(t);
    var claim = repo.byNumber(acct)!.visit(n)!.claim!;
    final changed = claim.lines.firstWhere((l) => l.isEvaluationAndManagement);
    expect(changed.code, other);
    expect(changed.evidence, contains('Level chosen by physician'));
    expect(find.text('Changed ${em.code} to $other'), findsOneWidget);
    await t.tap(find.text('Undo'));
    await _settle(t);
    expect(repo.byNumber(acct)!.visit(n)!.claim!.lines.firstWhere((l) => l.isEvaluationAndManagement).code, em.code);

    // Removing the line can be undone.
    await t.ensureVisible(find.byTooltip('Remove ${em.code}'));
    await t.pump();
    await t.tap(find.byTooltip('Remove ${em.code}'));
    await _settle(t);
    expect(repo.byNumber(acct)!.visit(n)!.claim!.lines.any((l) => l.code == em.code), isFalse);
    expect(find.text('Removed ${em.code}'), findsOneWidget);
    await t.tap(find.text('Undo'));
    await _settle(t);
    claim = repo.byNumber(acct)!.visit(n)!.claim!;
    expect(claim.lines.any((l) => l.code == em.code), isTrue);
    await _drain(t);
  });

  testWidgets('checks come first with a fix button; Sign note opens the review sheet', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    await _sample(t);
    await t.tap(find.text('Claim'));
    await _settle(t);
    expect(find.byKey(const Key('claim_issues_banner')), findsOneWidget);
    final fix = find.byKey(const Key('fix_CLAIM-SIGNED-01_'));
    expect(fix, findsOneWidget);
    expect(find.descendant(of: fix, matching: find.text('Sign note')), findsOneWidget);
    await t.ensureVisible(fix);
    await t.tap(fix);
    await _settle(t);
    expect(find.byKey(const Key('sign_confirm')), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('confirm_codes')));
    await t.tap(find.byKey(const Key('confirm_codes')));
    await t.pump();
    await t.tap(find.byKey(const Key('sign_confirm')));
    await _settle(t);
    expect(repo.byNumber(acct)!.visit(n)!.status, VisitStatus.claimReady);
    await _drain(t);
  });

  testWidgets('the ready screen shows the place of service and, for a return patient, the last visit', (t) async {
    final repo = await _demo();
    final (acct, first) = await _visit(repo, 'Margaret');
    final v1 = repo.byNumber(acct)!.visit(first)!;
    await repo.updateVisit(
      acct,
      v1.copyWith(status: VisitStatus.signed, claim: cleanClaim(), encounter: const {'plan': 'Recheck A1c in 3 months\nContinue metformin'}),
    );
    final (_, n) = await _visit(repo, 'Margaret');
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    expect(find.text('Office (11)'), findsOneWidget);
    expect(find.byKey(const Key('since_last_visit')), findsOneWidget);
    expect(find.textContaining('J06.9'), findsOneWidget);
    expect(find.text('Recheck A1c in 3 months'), findsOneWidget);
    expect(find.text('Continue metformin'), findsNothing, reason: 'only follow-up lines');
    expect(find.byKey(const Key('ready_eligibility')), findsOneWidget);
    await _drain(t);
  });

  testWidgets('a location fix inside a saved place sets the place of service', (t) async {
    final repo = await _demo();
    await repo.saveProvider(repo.provider.copyWith(savedPlaces: const [
      SavedPlace(id: 'p', name: 'Sunrise SNF', placeOfService: '31', latitude: 37.7749, longitude: -122.4194),
    ]));
    _gps = const {'available': true, 'latitude': 37.7750, 'longitude': -122.4195, 'accuracy': 12.0};
    final (acct, n) = await _visit(repo, 'Elena');
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    await _settle(t);
    final v = repo.byNumber(acct)!.visit(n)!;
    expect(v.placeOfService, '31');
    expect(v.posSource, 'place');
    expect(find.textContaining('At Sunrise SNF'), findsOneWidget);
    await _drain(t);
  });

  testWidgets('session details hold real microphone settings, no fake controls', (t) async {
    final repo = await _demo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _pump(t, EncounterScreen(accountNumber: acct, visitNumber: n));
    await t.tap(find.byTooltip('More'));
    await _settle(t);
    await t.tap(find.text('Session details'));
    await _settle(t);
    expect(find.text('Room noise filter'), findsNothing);
    expect(find.text('Indian English / Accent'), findsNothing);
    expect(find.byKey(const Key('noise_suppression')), findsOneWidget);
    await t.ensureVisible(find.text('Spanish and English'));
    await t.tap(find.text('Spanish and English'));
    await _settle(t);
    expect(find.textContaining('basic recognition uses US Spanish'), findsOneWidget);
    await _drain(t);
  });

  testWidgets('a signature stroke inside a scrolling sheet draws instead of scrolling', (t) async {
    final pad = GlobalKey<SignaturePadState>();
    final scroll = ScrollController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          controller: scroll,
          child: Column(children: [
            const SizedBox(height: 200),
            SignaturePad(key: pad, onChanged: (_) {}),
            const SizedBox(height: 1500),
          ]),
        ),
      ),
    ));
    final center = t.getCenter(find.byType(SignaturePad)) - const Offset(0, 20);
    final g = await t.startGesture(center);
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, 6));
      await t.pump();
    }
    await g.up();
    await t.pump();
    expect(scroll.offset, 0, reason: 'the page did not scroll');
    expect(pad.currentState!.pointCount, greaterThan(5));
    expect(find.text('Clear'), findsOneWidget);
    await t.tap(find.text('Clear'));
    await t.pump();
    expect(pad.currentState!.pointCount, 0);
  });

  testWidgets('deleting a patient from the chart can be undone', (t) async {
    final repo = await _demo();
    final a = repo.accounts.firstWhere((a) => a.firstName == 'David');
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: SolisTheme.lightTheme(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => PatientChartScreen(accountNumber: a.accountNumber))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await _settle(t);
    await t.tap(find.byKey(const Key('chart_menu')));
    await _settle(t);
    await t.tap(find.text('Delete patient'));
    await _settle(t);
    expect(repo.byNumber(a.accountNumber), isNull);
    expect(find.text('open'), findsOneWidget, reason: 'back on the previous screen');
    expect(find.textContaining('David Miller deleted'), findsOneWidget);
    await t.tap(find.text('Undo'));
    await _settle(t);
    expect(repo.byNumber(a.accountNumber), isNotNull);
  });

  testWidgets('Billing groups visits, and sends the ready ones in one batch', (t) async {
    final repo = await realRepo();
    final jane = await billablePatient(repo);
    final ann = await billablePatient(repo, first: 'Ann');
    await visitWith(repo, jane);
    await visitWith(repo, ann);
    await visitWith(repo, ann, status: VisitStatus.denied);
    final ch = FakeClearinghouse();
    final settings = await submitterSettings();
    final service = ClaimSubmissionService(repo: repo, client: () => ch, settings: () => settings);
    PatientsScreen.resetLaunchRefresh();
    await _pump(t, PatientsScreen(initialTab: 2, claimService: service));
    await _settle(t);
    expect(find.text('Ready to send'), findsOneWidget);
    expect(find.text('Denied'), findsWidgets);
    await t.tap(find.byKey(const Key('batch_send')));
    await _settle(t);
    expect(find.text('Send 2 test claims?'), findsOneWidget);
    await t.tap(find.byKey(const Key('batch_send_confirm')));
    await _settle(t);
    expect(find.text('Sent'), findsNWidgets(2));
    expect(ch.submitted, hasLength(2));
    await t.tap(find.text('Done'));
    await _settle(t);
    expect(find.text('Sent, awaiting payer'), findsOneWidget);
    expect(find.byKey(const Key('batch_send')), findsNothing);
  });

  testWidgets('home opens on Today and lists today\'s visits with their status', (t) async {
    final repo = await realRepo();
    final jane = await billablePatient(repo);
    await visitWith(repo, jane, dos: DateTime.now().toIso8601String().split('T').first, status: VisitStatus.inProgress);
    await _pump(t, const PatientsScreen());
    expect(find.text('Today'), findsWidgets);
    expect(find.byKey(const Key('today_list')), findsOneWidget);
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
  });
}
