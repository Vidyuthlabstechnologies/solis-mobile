import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/screens/patients_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/front_desk.dart';
import 'package:solis_mobile/services/subscriptions/subscription_service.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

import 'support/billing_fixtures.dart';

class _TrialStore implements SubscriptionBackend {
  final ProRenewal r;
  _TrialStore(this.r);
  @override
  Future<void> configure({String? appUserId}) async {}
  @override
  Future<bool> isPro() async => true;
  @override
  Future<ProRenewal?> renewal() async => r;
  @override
  Future<List<SubscriptionPlan>> plans() async => const [];
  @override
  Future<PurchaseOutcome> purchase(SubscriptionPlan plan) async => PurchaseOutcome.cancelled;
  @override
  Future<bool> restore() async => true;
  @override
  Future<bool> logIn(String appUserId) async => true;
  @override
  Future<void> logOut() async {}
  @override
  Future<String?> managementUrl() async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> _phone(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: home));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() {
    FrontDesk.instance = FrontDesk(MemoryFrontDeskStore());
    SubscriptionService.instance = SubscriptionService(backend: null);
  });

  group('front desk mode', () {
    test('PIN turns it on and off, survives a restart, and locks after 5 wrong tries', () async {
      var now = DateTime(2026, 11, 13, 9);
      final store = MemoryFrontDeskStore();
      final fd = FrontDesk(store, now: () => now);
      expect(FrontDesk.validPin('12'), isFalse);
      expect(FrontDesk.validPin('12ab'), isFalse);
      await fd.turnOn('2468');
      expect(fd.isOn, isTrue);
      expect(store.value, isNot(contains('2468')), reason: 'only a salted hash is stored');

      final again = FrontDesk(store, now: () => now);
      await again.restore();
      expect(again.isOn, isTrue);

      for (var i = 0; i < FrontDesk.maxTries; i++) {
        expect(await again.turnOff('0000'), isFalse);
      }
      expect(again.lockedFor, isNotNull);
      expect(await again.turnOff('2468'), isFalse, reason: 'locked out, even with the right PIN');
      now = now.add(FrontDesk.lockout + const Duration(seconds: 1));
      expect(await again.turnOff('2468'), isTrue);
      expect(again.isOn, isFalse);
      expect(store.value, isNull);
    });

    testWidgets('staff see Today and Patients only, and charts without visits', (tester) async {
      final repo = await realRepo();
      AccountRepository.instance = repo;
      final a = await billablePatient(repo);
      await visitWith(repo, a);
      await FrontDesk.instance.turnOn('2468');

      await _phone(tester, const PatientsScreen(initialTab: 2));
      expect(find.byKey(const Key('front_desk_strip')), findsOneWidget);
      expect(find.text('Billing'), findsNothing);
      expect(find.byTooltip('Provider profile'), findsNothing);
      expect(find.byTooltip('More'), findsNothing);
      expect(find.text('Scan card'), findsOneWidget);

      await _phone(tester, PatientChartScreen(accountNumber: a.accountNumber));
      expect(find.text('Insurance'), findsOneWidget);
      expect(find.text('Visits'), findsNothing);
      expect(find.text("Start today's visit"), findsNothing);
      expect(find.byKey(const Key('chart_menu')), findsNothing);
      await _done(tester);
    });

    testWidgets('the clinician turns it on from the menu and off with the PIN', (tester) async {
      final repo = await realRepo();
      AccountRepository.instance = repo;
      await billablePatient(repo);
      await _phone(tester, const PatientsScreen(initialTab: 0));

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Front desk mode (free)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('front_desk_pin')), '2468');
      await tester.enterText(find.byKey(const Key('front_desk_pin_again')), '2469');
      await tester.tap(find.byKey(const Key('front_desk_start')));
      await tester.pumpAndSettle();
      expect(find.text('The two PINs do not match.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('front_desk_pin_again')), '2468');
      await tester.tap(find.byKey(const Key('front_desk_start')));
      await tester.pumpAndSettle();
      expect(FrontDesk.instance.isOn, isTrue);
      expect(find.byKey(const Key('front_desk_strip')), findsOneWidget);

      await tester.tap(find.byKey(const Key('front_desk_leave')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('front_desk_exit_pin')), '1111');
      await tester.tap(find.byKey(const Key('front_desk_exit')));
      await tester.pumpAndSettle();
      expect(find.text('Wrong PIN.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('front_desk_exit_pin')), '2468');
      await tester.tap(find.byKey(const Key('front_desk_exit')));
      await tester.pumpAndSettle();
      expect(FrontDesk.instance.isOn, isFalse);
      expect(find.text('Billing'), findsOneWidget);
      await _done(tester);
    });
  });

  group('trial ending reminder', () {
    final now = DateTime.utc(2026, 11, 13, 12);
    test('only in the last 3 days of a trial that will charge', () {
      expect(ProRenewal(inTrial: true, endsAt: now.add(const Duration(days: 5))).trialEndingReminder(now), isNull);
      expect(ProRenewal(inTrial: true, willRenew: false, endsAt: now.add(const Duration(days: 1))).trialEndingReminder(now), isNull);
      expect(ProRenewal(endsAt: now.add(const Duration(days: 1))).trialEndingReminder(now), isNull, reason: 'paid plan, not a trial');
      expect(ProRenewal(inTrial: true, endsAt: now.subtract(const Duration(hours: 1))).trialEndingReminder(now), isNull);
      final soon = ProRenewal(inTrial: true, endsAt: now.add(const Duration(days: 2, hours: 3))).trialEndingReminder(now)!;
      expect(soon, startsWith('Your free trial ends in 3 days (Nov 15)'));
      expect(soon, contains('cancel in Google Play before then and you pay nothing'));
      expect(ProRenewal(inTrial: true, endsAt: now.add(const Duration(hours: 5))).trialEndingReminder(now), startsWith('Your free trial ends today'));
    });

    testWidgets('Today shows the reminder with a Google Play link', (tester) async {
      final repo = await realRepo();
      AccountRepository.instance = repo;
      final subs = SubscriptionService(backend: _TrialStore(ProRenewal(inTrial: true, endsAt: DateTime.now().add(const Duration(days: 2)))));
      await subs.refresh();
      SubscriptionService.instance = subs;
      await _phone(tester, const PatientsScreen(initialTab: 0));
      expect(find.byKey(const Key('trial_reminder')), findsOneWidget);
      expect(find.text('Manage in Google Play'), findsOneWidget);
      await _done(tester);
    });
  });
}
