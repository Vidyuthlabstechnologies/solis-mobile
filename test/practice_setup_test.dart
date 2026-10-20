import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/screens/provider_profile_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/app_session.dart';
import 'package:solis_mobile/services/auth_service.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/services/npi_registry.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

import 'support/test_provider.dart';

void main() {
  group('Provider identity', () {
    test('a real clinician starts from an empty profile that cannot bill', () {
      final p = ProviderProfile.empty();
      expect(p.isComplete, isFalse);
      expect(p.isDemoIdentity, isFalse);
      expect(p.missingForClaims, containsAll(['Full name', 'Individual NPI', 'Tax ID (EIN)', 'Practice name', 'Street address', 'ZIP']));
      expect(p.feeSchedule, isNotEmpty, reason: 'the editable placeholder fee list stays');
    });

    test('the demo profile is complete but flagged as the demo identity', () {
      final d = ProviderProfile.demo();
      expect(d.isComplete, isTrue);
      expect(d.isDemoIdentity, isTrue);
      expect(testProvider().isDemoIdentity, isFalse);
      expect(testProvider().isComplete, isTrue);
    });

    test('saved places and the note engine preference survive JSON', () {
      final p = testProvider().copyWith(
        preferOnDevice: true,
        savedPlaces: const [SavedPlace(id: 'a', name: 'Sunrise SNF', placeOfService: '31', latitude: 37.7, longitude: -122.4, radiusMeters: 200)],
      );
      final back = ProviderProfile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.preferOnDevice, isTrue);
      expect(back.savedPlaces.single.name, 'Sunrise SNF');
      expect(back.savedPlaces.single.placeOfService, '31');
      expect(back.savedPlaces.single.radiusMeters, 200);
    });
  });

  group('Demo data only in demo mode', () {
    test('a new store has no patients and an empty provider', () {
      final repo = AccountRepository.memory();
      expect(repo.demoMode, isFalse);
      expect(repo.accounts, isEmpty);
      expect(repo.provider.isComplete, isFalse);
    });

    test('demo mode seeds labeled sample patients that real mode never shows', () async {
      final repo = AccountRepository.memory();
      await repo.seedDemoIfEmpty();
      expect(repo.demoMode, isTrue);
      expect(repo.accounts, hasLength(5));
      expect(repo.accounts.every((a) => a.isSample), isTrue);
      expect(repo.provider.npi, ProviderProfile.demoNpi);

      repo.setDemoMode(false);
      expect(repo.accounts, isEmpty);
      expect(repo.provider.isDemoIdentity, isFalse);
      final real = await repo.createAccount(firstName: 'Ann', lastName: 'Real');
      expect(real.isSample, isFalse);
      expect(repo.accounts.single.accountNumber, real.accountNumber);

      // Seeding again (back in demo) does not duplicate the samples.
      await repo.seedDemoIfEmpty();
      expect(repo.accounts, hasLength(5));
    });

    test('demo profile edits never overwrite the clinician profile', () async {
      final repo = AccountRepository.memory();
      await repo.saveProvider(testProvider());
      await repo.seedDemoIfEmpty();
      await repo.saveProvider(ProviderProfile.demo().copyWith(practiceName: 'Demo edit'));
      repo.setDemoMode(false);
      expect(repo.provider.npi, testProvider().npi);
      expect(repo.provider.practiceName, testProvider().practiceName);
    });

    test('a store saved by an older build with the demo provider loads as empty', () async {
      final dir = await Directory.systemTemp.createTemp('solis_setup');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/solis_provider.json').writeAsStringSync(jsonEncode(ProviderProfile.demo().toJson()));
      File('${dir.path}/solis_accounts.json').writeAsStringSync(jsonEncode({
        'nextSequence': 1000010,
        'accounts': [
          PatientAccount(accountNumber: 'SOL-10000017', firstName: 'Marcus', lastName: 'Thorne', createdAtUtc: DateTime.utc(2026), sampleConversationKey: 'x')
              .toJson()
            ..remove('isSample'),
        ],
      }));
      final repo = await AccountRepository.openAt(dir);
      expect(repo.provider.isDemoIdentity, isFalse);
      expect(repo.provider.isComplete, isFalse);
      expect(repo.accounts, isEmpty, reason: 'old seeded patients are recognized as samples');
      repo.setDemoMode(true);
      expect(repo.accounts.single.firstName, 'Marcus');
    });

    test('claims for the demo provider or a sample patient are errors outside demo mode', () {
      final account = PatientAccount(
        accountNumber: 'SOL-1',
        firstName: 'A',
        lastName: 'B',
        createdAtUtc: DateTime(2026),
        isSample: true,
      );
      final visit = Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '11', createdAtUtc: DateTime(2026));
      final claim = ClaimDraft(diagnoses: const [], lines: const [], generatedAtUtc: DateTime(2026));
      List<String> rules(bool demo, ProviderProfile p) =>
          ClaimScrubber.check(claim: claim, account: account, visit: visit, provider: p, noteSigned: true, demoMode: demo).map((i) => i.ruleId ?? '').toList();
      expect(rules(false, ProviderProfile.demo()), containsAll(['CLAIM-PROVIDER-01', 'CLAIM-SAMPLE-01']));
      expect(rules(true, ProviderProfile.demo()), isNot(contains('CLAIM-PROVIDER-01')));
      expect(rules(true, ProviderProfile.demo()), isNot(contains('CLAIM-SAMPLE-01')));
      expect(rules(false, ProviderProfile.empty()), contains('CLAIM-PROVIDER-02'));
      final providerFix = ClaimScrubber.check(claim: claim, account: account, visit: visit, provider: ProviderProfile.empty(), noteSigned: true)
          .firstWhere((i) => i.ruleId == 'CLAIM-PROVIDER-02')
          .fix;
      expect(providerFix?.kind, FixKind.editProvider);
    });
  });

  group('First route', () {
    test('signed out goes to login, demo to patients, an incomplete account to setup', () async {
      final repo = AccountRepository.memory();
      expect(AppSession.routeFor(AuthMode.signedOut, repo), AppSession.loginRoute);
      await AppSession.apply(AuthMode.account, repo);
      expect(AppSession.routeFor(AuthMode.account, repo), AppSession.setupRoute);
      await repo.saveProvider(testProvider());
      expect(AppSession.routeFor(AuthMode.account, repo), AppSession.homeRoute);
      await AppSession.apply(AuthMode.demo, repo);
      expect(repo.demoMode, isTrue);
      expect(AppSession.routeFor(AuthMode.demo, repo), AppSession.homeRoute);
    });
  });

  group('Set up your practice', () {
    Future<void> pumpSetup(WidgetTester t, {NpiLookup? lookup}) async {
      t.view.physicalSize = const Size(412, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: SolisTheme.lightTheme(),
        home: ProviderProfileScreen(firstRun: true, npiLookup: lookup),
        routes: {'/patients': (_) => const Scaffold(body: Text('PATIENTS'))},
      ));
    }

    testWidgets('a valid NPI is looked up on its own and prefills the form; save opens patients', (t) async {
      final repo = AccountRepository.memory();
      AccountRepository.instance = repo;
      final looked = <String>[];
      await pumpSetup(t, lookup: (npi) async {
        looked.add(npi);
        return const NpiRecord(
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
      });
      expect(find.text('Set up your practice'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);
      await t.enterText(find.byKey(const Key('profile_npi')), '1234567893');
      await t.pump(const Duration(milliseconds: 450));
      await t.pump();
      expect(looked, ['1234567893']);
      expect(find.widgetWithText(TextFormField, 'Ada Lovelace'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '1 Main St'), findsOneWidget);

      // Save is refused until the tax ID and practice name are in.
      await t.tap(find.byKey(const Key('profile_save')));
      await t.pump();
      expect(find.text('PATIENTS'), findsNothing);
      expect(repo.provider.isComplete, isFalse);

      await t.enterText(find.byKey(const Key('profile_practiceName')), 'Lovelace Family Practice');
      await t.enterText(find.byKey(const Key('profile_tax_id')), '12-3456789');
      await t.tap(find.byKey(const Key('profile_save')));
      await t.pumpAndSettle();
      expect(find.text('PATIENTS'), findsOneWidget);
      expect(repo.provider.isComplete, isTrue);
      expect(repo.provider.npi, '1234567893');
      expect(repo.provider.taxonomyCode, '207Q00000X');
      expect(repo.provider.zip, '946071234');
    });

    testWidgets('the demo NPI is refused for a real account', (t) async {
      AccountRepository.instance = AccountRepository.memory();
      await pumpSetup(t, lookup: (_) async => null);
      await t.enterText(find.byKey(const Key('profile_npi')), ProviderProfile.demoNpi);
      await t.pump(const Duration(milliseconds: 450));
      await t.tap(find.byKey(const Key('profile_save')));
      await t.pump();
      expect(find.text('This is the demo NPI. Enter your own.'), findsOneWidget);
    });
  });
}
