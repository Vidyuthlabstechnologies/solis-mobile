// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the main screens to PNG with real fonts for design review.
//
//   flutter test screenshots/screenshot_test.dart --update-goldens
//
// Output lands in screenshots/out/. Not part of the regular test suite.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/encounter_screen.dart';
import 'package:solis_mobile/screens/login_screen.dart';
import 'package:solis_mobile/screens/sign_up_screen.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/screens/patients_screen.dart';
import 'package:solis_mobile/screens/provider_profile_screen.dart';
import 'package:solis_mobile/screens/scan_card_screen.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/ambulance_transport.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/billing/claim_submission_service.dart';
import 'package:solis_mobile/services/npi_registry.dart';

import '../test/support/billing_fixtures.dart';
import '../test/support/fake_clearinghouse.dart';
import 'package:solis_mobile/services/card_parser.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\tools\flutter';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String f) async => ByteData.sublistView(File('$dir/$f').readAsBytesSync());

  final roboto = FontLoader('Roboto')
    ..addFont(read('roboto-regular.ttf'))
    ..addFont(read('roboto-medium.ttf'))
    ..addFont(read('roboto-bold.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(read('materialicons-regular.otf'));
  await icons.load();
}

Future<AccountRepository> _repo() async {
  final repo = AccountRepository.memory();
  AccountRepository.instance = repo;
  await repo.seedDemoIfEmpty();
  return repo;
}

Future<(String, int)> _visit(AccountRepository repo, String firstName, {String pos = '11', bool earlier = false}) async {
  final a = repo.accounts.firstWhere((a) => a.firstName == firstName);
  if (earlier) {
    final v1 = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 7, 9), placeOfService: pos);
    await repo.updateVisit(a.accountNumber, v1.copyWith(status: VisitStatus.claimReady));
    final v2 = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 8, 20), placeOfService: pos);
    await repo.updateVisit(a.accountNumber, v2.copyWith(status: VisitStatus.signed));
  }
  final v = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: pos);
  return (a.accountNumber, v.number);
}

Future<void> _shoot(
  WidgetTester tester,
  String name,
  Widget home, {
  bool dark = false,
  Size size = const Size(412, 915),
  Future<void> Function(WidgetTester)? interact,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  // flutter_test draws elevation as a solid black outline unless real
  // shadows are on; restored after the capture (the test checks it).
  debugDisableShadows = false;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: SolisTheme.lightTheme(),
      darkTheme: SolisTheme.darkTheme(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: home,
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  if (interact != null) await interact(tester);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name.png'));
  debugDisableShadows = true;
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
}

Future<void> _sample(WidgetTester t) async {
  await t.tap(find.text('Sample conversation'));
  await _settle(t);
  await t.pump(const Duration(milliseconds: 600));
}

/// Scrolls the encounter list until [f] is built, then a little more.
Future<void> _dragTo(WidgetTester t, Finder f) async {
  for (var i = 0; i < 20 && f.evaluate().isEmpty; i++) {
    await t.drag(find.byType(ListView).first, const Offset(0, -300));
    await _settle(t);
  }
  await t.ensureVisible(f.first);
  await _settle(t);
}

Future<void> _tab(WidgetTester t, String tab) async {
  await t.tap(find.text(tab));
  await _settle(t);
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('01 sign in', (t) => _shoot(t, '01_sign_in', const LoginScreen()));
  testWidgets('02 patients', (t) async {
    final repo = await _repo();
    await _visit(repo, 'Margaret', earlier: true);
    await _shoot(t, '02_patients', const PatientsScreen(initialTab: 1));
  });
  testWidgets('03 scan review', (t) async {
    await _repo();
    await _shoot(
      t,
      '03_scan_review',
      ScanCardScreen(
        preview: ScannedIdentity(
          firstName: 'Jane',
          lastName: 'Doe',
          dateOfBirth: DateTime(1985, 4, 2),
          sex: PatientSex.female,
          payerName: 'Aetna',
          memberId: 'W99887766',
          groupNumber: '285214-010',
          planType: 'PPO',
          rxBin: '610502',
          copays: const {'PCP': '\$25', 'Specialist': '\$50'},
          sources: const {'Insurance card', "Driver's license barcode"},
        ),
      ),
    );
  });
  testWidgets('04 chart', (t) async {
    final repo = await _repo();
    final (acct, _) = await _visit(repo, 'Margaret', earlier: true);
    await _shoot(t, '04_chart', PatientChartScreen(accountNumber: acct));
  });
  testWidgets('05 provider', (t) async {
    await _repo();
    await _shoot(t, '05_provider', const ProviderProfileScreen());
  });
  testWidgets('06 ready', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _shoot(t, '06_ready', EncounterScreen(accountNumber: acct, visitNumber: n));
  });
  testWidgets('07 recording', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Margaret');
    await _shoot(t, '07_recording', EncounterScreen(accountNumber: acct, visitNumber: n, previewRecording: true));
  });
  testWidgets('08 note', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Elena');
    await _shoot(t, '08_note', EncounterScreen(accountNumber: acct, visitNumber: n), interact: _sample);
  });
  testWidgets('09 claim pneumonia', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Elena');
    await _shoot(t, '09_claim_uncertain', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
    });
  });
  testWidgets('10 claim pneumonia scrolled', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Elena');
    await _shoot(t, '10_claim_checks', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
      await t.drag(find.byType(ListView).first, const Offset(0, -900));
      await _settle(t);
    });
  });
  testWidgets('11 claim stemi ed', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Robert', pos: '23');
    await _shoot(t, '11_claim_stemi_ed', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
      await t.drag(find.byType(ListView).first, const Offset(0, -420));
      await _settle(t);
    });
  });
  testWidgets('12 talk', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Margaret');
    await _shoot(t, '12_talk', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Talk');
    });
  });
  testWidgets('13 claim dark', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _shoot(t, '13_claim_dark', EncounterScreen(accountNumber: acct, visitNumber: n, isDark: true), dark: true, interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
    });
  });
  testWidgets('14 compact claim 320', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'David');
    await _shoot(t, '14_compact_claim', EncounterScreen(accountNumber: acct, visitNumber: n), size: const Size(320, 640), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
    });
  });
  testWidgets('15 create account', (t) => _shoot(t, '15_create_account', const SignUpScreen()));
  testWidgets('16 consent', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Marcus');
    await _shoot(t, '16_consent', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await t.tap(find.bySemanticsLabel('Start recording'));
      await _settle(t);
    });
  });
  testWidgets('17 orders', (t) async {
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Robert', pos: '23');
    await _shoot(t, '17_orders', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Orders');
    });
  });

  // UX review screens: practice setup, Today, Billing, sign-and-send,
  // ambulance transport. Each at 412dp and the compact 320dp.
  Future<void> setup(WidgetTester t) async {
    await t.enterText(find.byKey(const Key('profile_npi')), '1234567893');
    await t.pump(const Duration(milliseconds: 450));
    await t.pump(const Duration(milliseconds: 300));
  }

  NpiRecord? fakeNpi(String _) => const NpiRecord(
        npi: '1234567893',
        isOrganization: false,
        firstName: 'Ada',
        lastName: 'Lovelace',
        credential: 'MD',
        taxonomyCode: '207Q00000X',
        addressLine1: '1 Main St',
        city: 'Oakland',
        state: 'CA',
        zip: '946071234',
        phone: '(510) 555-0100',
      );

  for (final (size, suffix) in const [(Size(412, 915), ''), (Size(320, 640), '_320')]) {
    testWidgets('22 setup$suffix', (t) async {
      AccountRepository.instance = AccountRepository.memory();
      await _shoot(t, '22_setup$suffix', ProviderProfileScreen(firstRun: true, npiLookup: (n) async => fakeNpi(n)), size: size, interact: setup);
    });

    testWidgets('23 today$suffix', (t) async {
      final repo = await _repo();
      final today = DateTime.now();
      for (final (name, status) in const [('Marcus', VisitStatus.inProgress), ('Elena', VisitStatus.signed), ('Margaret', VisitStatus.submitted)]) {
        final a = repo.accounts.firstWhere((a) => a.firstName == name);
        final v = await repo.addVisit(a.accountNumber, dateOfService: today, placeOfService: '11');
        await repo.updateVisit(a.accountNumber, v.copyWith(status: status));
      }
      await _shoot(t, '23_today$suffix', const PatientsScreen(), size: size);
    });

    testWidgets('24 billing$suffix', (t) async {
      final repo = await realRepo();
      final jane = await billablePatient(repo);
      final ann = await billablePatient(repo, first: 'Ann');
      final raj = await billablePatient(repo, first: 'Raj');
      await visitWith(repo, jane);
      await visitWith(repo, ann);
      await visitWith(repo, raj, status: VisitStatus.inProgress);
      await visitWith(repo, raj, claim: cleanClaim().copyWith(lines: const []));
      await visitWith(repo, ann, status: VisitStatus.queued);
      final denied = await visitWith(repo, jane, status: VisitStatus.denied, dos: '2026-10-01');
      await repo.updateVisit(jane.accountNumber, denied.copyWith(submission: {'lastStatus': 'Denied: CO-16 missing information'}));
      final settings = await submitterSettings();
      PatientsScreen.resetLaunchRefresh();
      final service = ClaimSubmissionService(repo: repo, client: () => FakeClearinghouse(), settings: () => settings);
      await _shoot(t, '24_billing$suffix', PatientsScreen(initialTab: 2, claimService: service), size: size);
      PatientsScreen.resetLaunchRefresh();
    });

    testWidgets('25 sign sheet$suffix', (t) async {
      final repo = await _repo();
      final (acct, n) = await _visit(repo, 'Marcus');
      await _shoot(t, '25_sign_sheet$suffix', EncounterScreen(accountNumber: acct, visitNumber: n), size: size, interact: (t) async {
        await _sample(t);
        await t.tap(find.byKey(const Key('review_and_sign')));
        await _settle(t);
      });
    });

    testWidgets('26 claim fixes$suffix', (t) async {
      final repo = await _repo();
      final (acct, n) = await _visit(repo, 'Elena');
      await _shoot(t, '26_claim_fixes$suffix', EncounterScreen(accountNumber: acct, visitNumber: n), size: size, interact: (t) async {
        await _sample(t);
        await _tab(t, 'Claim');
      });
    });

    testWidgets('27 transport$suffix', (t) async {
      final repo = await _repo();
      final (acct, n) = await _visit(repo, 'Robert', pos: '41');
      final v = repo.byNumber(acct)!.visit(n)!;
      await repo.updateVisit(acct, v.copyWith(transport: const AmbulanceTransport(
        pickup: TransportAddress(line1: '12 Oak St', city: 'Oakland', state: 'CA', zip: '94607'),
        loadedMiles: 7.3,
        milesSource: 'gps',
        gpsMiles: 7.3,
      )));
      await _shoot(t, '27_transport$suffix', EncounterScreen(accountNumber: acct, visitNumber: n), size: size, interact: (t) async {
        await _sample(t);
        await _tab(t, 'Claim');
        await _dragTo(t, find.text('Transport'));
      });
    });

    testWidgets('28 ready return$suffix', (t) async {
      final repo = await _repo();
      final a = repo.accounts.firstWhere((a) => a.firstName == 'Margaret');
      final v1 = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 9, 20), placeOfService: '11');
      await repo.updateVisit(a.accountNumber, v1.copyWith(
        status: VisitStatus.paid,
        claim: ClaimDraft(generatedAtUtc: DateTime(2026, 9, 20), diagnoses: const [
          ClaimDiagnosis(code: 'E11.42', description: 'Type 2 diabetes with diabetic polyneuropathy', source: DxSource.physicianConfirmed),
          ClaimDiagnosis(code: 'Z79.84', description: 'Long term (current) use of oral hypoglycemic drugs', source: DxSource.history),
        ], lines: const []),
        encounter: const {'plan': 'Recheck A1c in 3 months\nContinue metformin'},
      ));
      final (acct, n) = await _visit(repo, 'Margaret');
      await _shoot(t, '28_ready_return$suffix', EncounterScreen(accountNumber: acct, visitNumber: n), size: size);
    });
  }

  // The knowledge base: real bundled assets, the "Why" sheet and the coding
  // notes of a diagnosis.
  Future<void> loadKnowledge(WidgetTester t) => t.runAsync(() async {
        CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes'));
        await ReferenceData.load();
      });

  testWidgets('18 claim knowledge checks', (t) async {
    await loadKnowledge(t);
    addTearDown(ReferenceData.clear);
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Margaret');
    await _shoot(t, '18_claim_kb_checks', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
      await _dragTo(t, find.text('Checks'));
      await t.drag(find.byType(ListView).first, const Offset(0, -500));
      await _settle(t);
    });
  });
  testWidgets('19 claim why sheet', (t) async {
    await loadKnowledge(t);
    addTearDown(ReferenceData.clear);
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Elena');
    await _shoot(t, '19_claim_why', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
      await _dragTo(t, find.text('Primary diagnosis is a symptom'));
      final row = find.ancestor(of: find.text('Primary diagnosis is a symptom'), matching: find.byType(Row)).first;
      final why = find.descendant(of: row, matching: find.text('Why'));
      await t.ensureVisible(why);
      await _settle(t);
      await t.tap(why);
      await _settle(t);
    });
  });
  testWidgets('20 claim coding notes', (t) async {
    await loadKnowledge(t);
    addTearDown(ReferenceData.clear);
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Margaret');
    await _shoot(t, '20_claim_coding_notes', EncounterScreen(accountNumber: acct, visitNumber: n), interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
      await _dragTo(t, find.textContaining('Coding notes'));
      final toggle = find.textContaining('Coding notes').first;
      await t.ensureVisible(toggle);
      await _settle(t);
      await t.tap(toggle);
      await _settle(t);
      await t.drag(find.byType(ListView).first, const Offset(0, -200));
      await _settle(t);
    });
  });
  testWidgets('21 claim why dark', (t) async {
    await loadKnowledge(t);
    addTearDown(ReferenceData.clear);
    final repo = await _repo();
    final (acct, n) = await _visit(repo, 'Margaret');
    await _shoot(t, '21_claim_why_dark', EncounterScreen(accountNumber: acct, visitNumber: n, isDark: true), dark: true, interact: (t) async {
      await _sample(t);
      await _tab(t, 'Claim');
      await _dragTo(t, find.text('Why'));
      await t.tap(find.text('Why').first);
      await _settle(t);
    });
  });
}
