import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/encounter_screen.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/screens/patients_screen.dart';
import 'package:solis_mobile/screens/scan_card_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/card_parser.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

Future<AccountRepository> _repo() async {
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

Future<void> _pump(WidgetTester tester, Widget home, {Size size = const Size(412, 915), bool isDark = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: SolisTheme.lightTheme(),
    darkTheme: SolisTheme.darkTheme(),
    themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
    home: home,
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

Future<void> _useSample(WidgetTester tester) async {
  await _tap(tester, find.text('Sample conversation'));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  for (final isDark in [false, true]) {
    final mode = isDark ? 'dark' : 'light';

    testWidgets('every review tab renders on a 320dp phone without overflow ($mode)', (tester) async {
      final repo = await _repo();
      final (acct, n) = await _visit(repo, 'Robert', pos: '23');
      await _pump(tester, EncounterScreen(accountNumber: acct, visitNumber: n, isDark: isDark), size: const Size(320, 640), isDark: isDark);
      expect(find.text('Ready to record'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _useSample(tester);
      for (final tab in ['Talk', 'Orders', 'Claim', 'Note']) {
        await tester.tap(find.text(tab));
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull, reason: 'overflow on $tab');
      }
      await _drain(tester);
    });

    testWidgets('recording phase renders on a 320dp phone ($mode)', (tester) async {
      final repo = await _repo();
      final (acct, n) = await _visit(repo, 'Margaret');
      await _pump(tester, EncounterScreen(accountNumber: acct, visitNumber: n, isDark: isDark, previewRecording: true),
          size: const Size(320, 640), isDark: isDark);
      expect(find.text('Recording'), findsOneWidget);
      expect(find.text('Finish and write note'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _drain(tester);
    });
  }

  testWidgets('recording asks for consent first, and a refusal is recorded', (tester) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _pump(tester, EncounterScreen(accountNumber: acct, visitNumber: n));

    await tester.tap(find.bySemanticsLabel('Start recording'));
    await _settle(tester);
    expect(find.text('Ask for consent to record'), findsOneWidget);
    await tester.tap(find.text('Patient declined'));
    await _settle(tester);
    // The refusal is part of the audit trail, and typing becomes the main path.
    final consent = repo.byNumber(acct)!.visit(n)!.consent!;
    expect(consent.method, 'declined');
    expect(consent.declined, isTrue);
    expect(repo.byNumber(acct)!.visit(n)!.consentConfirmed, isFalse);
    expect(find.text('Recording declined'), findsOneWidget);
    expect(find.byKey(const Key('ready_type_primary')), findsOneWidget);
    expect(find.byKey(const Key('ready_ask_again')), findsOneWidget);
    expect(find.bySemanticsLabel('Start recording'), findsNothing);
    expect(find.textContaining('Patient declined recording at'), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('discard deletes the visit so no record is left', (tester) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Robert');
    await _pump(tester, PatientChartScreen(accountNumber: acct));
    await _tap(tester, find.text('Continue visit $n').hitTestable().evaluate().isEmpty ? find.text('Visit $n') : find.text('Continue visit $n'));
    await _useSample(tester);
    expect(find.text('Draft for your review'), findsOneWidget);

    await tester.tap(find.byTooltip('Discard visit'));
    await _settle(tester);
    expect(find.text('Discard visit $n?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await _settle(tester);

    expect(repo.byNumber(acct)!.visit(n), isNull);
    expect(find.text('Visit $n discarded. Nothing was kept.'), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('one review sheet signs the note and marks the clean claim ready', (tester) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _pump(tester, EncounterScreen(accountNumber: acct, visitNumber: n));
    await _useSample(tester);

    await tester.tap(find.byKey(const Key('review_and_sign')));
    await _settle(tester);
    // The sheet shows the attestation, the claim and the check result.
    expect(find.text('Review and sign'), findsWidgets);
    expect(find.textContaining('I personally performed this encounter'), findsOneWidget);
    expect(find.textContaining('G43.109'), findsWidgets);
    expect(find.text('Sign and mark ready'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sign_confirm')));
    await _settle(tester);
    final visit = repo.byNumber(acct)!.visit(n)!;
    expect(visit.status, VisitStatus.claimReady);
    // A real SHA-256 over the signed note, not a constant.
    final seal = (visit.encounter!['sha256Seal'] as String);
    expect(seal, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(visit.encounter!['signedAtUtc'], isNotNull);

    await tester.tap(find.text('Claim'));
    await _settle(tester);
    expect(find.text('G43.109'), findsWidgets);
    await _drain(tester);
  });

  testWidgets('patients list shows accounts and filters by search', (tester) async {
    await _repo();
    await _pump(tester, const PatientsScreen(initialTab: 1));
    expect(find.text('Margaret Vance'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'cigna');
    await tester.pump();
    expect(find.text('Marcus Thorne'), findsOneWidget);
    expect(find.text('Margaret Vance'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scanned card creates an account after review', (tester) async {
    final repo = await _repo();
    final before = repo.accounts.length;
    await _pump(
      tester,
      ScanCardScreen(
        preview: ScannedIdentity(
          firstName: 'Jane',
          lastName: 'Doe',
          dateOfBirth: DateTime(1985, 4, 2),
          sex: PatientSex.female,
          payerName: 'Aetna',
          memberId: 'W99887766',
          sources: const {'Insurance card'},
        ),
      ),
    );
    expect(find.widgetWithText(TextFormField, 'Jane'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Create account'), 300, scrollable: find.byType(Scrollable).first);
    await _tap(tester, find.text('Create account'));
    expect(repo.accounts.length, before + 1);
    final jane = repo.accounts.firstWhere((a) => a.firstName == 'Jane');
    expect(jane.insurance!.memberId, 'W99887766');
    expect(AccountRepository.isValidAccountNumber(jane.accountNumber), isTrue);
  });

  test('UI source contains no emoji or bullet glyphs', () {
    // Guards the "zero emoji / zero dot glyph" design rule against regressions.
    final source = StringBuffer();
    for (final dir in ['lib/screens', 'lib/widgets', 'lib/theme', 'lib/services', 'lib/services/coding', 'lib/models']) {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        source.write(f.readAsStringSync());
      }
    }
    final forbidden = RegExp('[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2022}\u{25CF}\u{25CB}\u{FE0F}]', unicode: true);
    expect(forbidden.hasMatch(source.toString()), isFalse);
  });
}
