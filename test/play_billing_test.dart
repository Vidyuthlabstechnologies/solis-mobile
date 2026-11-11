import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:solis_mobile/screens/paywall_screen.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/services/auth_service.dart';
import 'package:solis_mobile/services/subscriptions/revenuecat_backend.dart';
import 'package:solis_mobile/services/subscriptions/subscription_service.dart';
import 'package:solis_mobile/theme/solis_theme.dart';
import 'package:solis_mobile/widgets/account_section.dart';

import 'support/billing_fixtures.dart';

class FakeAuth extends AuthService {
  bool demo;
  bool account;
  FakeAuth({this.demo = false, this.account = true}) : super(store: MemorySessionStore());
  @override
  bool get isDemo => demo;
  @override
  bool get hasAccount => account;
}

const _monthly = SubscriptionPlan(id: '\$rc_monthly', title: 'SOLIS Pro monthly', price: '\$149.00', period: 'month', trial: '14-day free trial');
const _yearly = SubscriptionPlan(id: '\$rc_annual', title: 'SOLIS Pro yearly', price: '\$1,548.00', period: 'year', perMonth: '\$129.00/month');

class FakeStore implements SubscriptionBackend {
  bool pro;
  List<SubscriptionPlan> offered;
  PurchaseOutcome outcome = PurchaseOutcome.purchased;
  SubscriptionException? fail;
  bool restorable = false;
  final Set<String> grantedCustomers;
  final logins = <String>[];
  int logouts = 0;

  FakeStore({this.pro = false, this.offered = const [_monthly, _yearly], this.grantedCustomers = const {}});

  @override
  Future<void> configure({String? appUserId}) async {}
  @override
  Future<bool> isPro() async => pro;
  @override
  Future<List<SubscriptionPlan>> plans() async => offered;
  @override
  Future<PurchaseOutcome> purchase(SubscriptionPlan plan) async {
    if (fail != null) throw fail!;
    if (outcome == PurchaseOutcome.purchased) pro = true;
    return outcome;
  }

  @override
  Future<bool> restore() async => pro = restorable;
  @override
  Future<bool> logIn(String id) async {
    logins.add(id);
    return pro = grantedCustomers.contains(id);
  }

  @override
  Future<void> logOut() async => logouts++;
  @override
  Future<String?> managementUrl() async => null;
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: home));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  tearDown(() => SubscriptionService.instance = null);

  group('who has to pay', () {
    test('only signed-in clinicians in a build that sells Pro', () async {
      expect(SubscriptionService(backend: null).blocksNewVisits(FakeAuth()), isFalse, reason: 'no RevenueCat key in this build');
      final subs = SubscriptionService(backend: FakeStore());
      expect(subs.blocksNewVisits(FakeAuth(demo: true, account: false)), isFalse, reason: 'the demo is free for reviewers and trials');
      expect(subs.blocksNewVisits(FakeAuth()), isTrue);
      await subs.restore();
      final pro = SubscriptionService(backend: FakeStore(pro: true));
      await pro.refresh();
      expect(pro.blocksNewVisits(FakeAuth()), isFalse);
    });

    test('a build without a key never offers a purchase', () async {
      final subs = SubscriptionService(backend: null);
      expect(await subs.plans(), isEmpty);
      expect(() => subs.restore(), throwsA(isA<SubscriptionException>()));
    });
  });

  group('access codes', () {
    test('are tidied and checked', () {
      expect(normalizeAccessCode(' play-review 2026 '), 'PLAYREVIEW2026');
      expect(normalizeAccessCode('abc'), isNull);
      expect(normalizeAccessCode('drop table;'), isNull);
    });

    test('an active code unlocks Pro; an unknown one puts the clinician back', () async {
      final store = FakeStore(grantedCustomers: {'access_PLAYREVIEW'});
      final subs = SubscriptionService(backend: store);
      await expectLater(subs.redeemAccessCode('nope1234'), throwsA(isA<SubscriptionException>()));
      expect(subs.isPro, isFalse);
      expect(store.logouts, 1, reason: 'back to the anonymous customer');
      await subs.redeemAccessCode('play-review');
      expect(subs.isPro, isTrue);
      expect(subs.accessCode, 'PLAYREVIEW');
      expect(store.logins.last, 'access_PLAYREVIEW');
    });
  });

  group('RevenueCat wording', () {
    test('trials and errors read plainly', () {
      expect(trialLabel(14, PeriodUnit.day), '14-day free trial');
      expect(trialLabel(1, PeriodUnit.week), '7-day free trial');
      expect(messageFor(PurchasesErrorCode.networkError), contains('internet'));
      expect(messageFor(PurchasesErrorCode.productAlreadyPurchasedError), contains('Restore'));
      expect(messageFor(PurchasesErrorCode.configurationError), contains('not been charged'));
      expect(messageFor(PurchasesErrorCode.unknownError), contains('not been charged'));
    });
  });

  group('paywall', () {
    testWidgets('shows Google Play prices, yearly first choice, and buys', (tester) async {
      final store = FakeStore();
      final subs = SubscriptionService(backend: store);
      await _pump(tester, PaywallScreen(subscriptions: subs));
      await tester.pumpAndSettle();
      expect(find.textContaining('\$149.00 per month'), findsOneWidget);
      expect(find.textContaining('\$129.00/month'), findsOneWidget);
      expect(find.text('Subscribe'), findsOneWidget, reason: 'yearly has no trial here');
      await tester.tap(find.text('SOLIS Pro monthly'));
      await tester.pump();
      expect(find.text('Start free trial'), findsOneWidget);
      expect(find.textContaining('After the trial, \$149.00 is charged'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
      await tester.tap(find.byKey(const Key('paywall_subscribe')));
      await tester.pumpAndSettle();
      expect(subs.isPro, isTrue);
    });

    testWidgets('says why a purchase failed, and when nothing was restored', (tester) async {
      final store = FakeStore()..fail = const SubscriptionException('No connection to Google Play.');
      await _pump(tester, PaywallScreen(subscriptions: SubscriptionService(backend: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('paywall_subscribe')));
      await tester.pumpAndSettle();
      expect(find.text('No connection to Google Play.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('paywall_restore')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No SOLIS Pro subscription was found'), findsOneWidget);
    });

    testWidgets('pending payment is explained, not treated as Pro', (tester) async {
      final store = FakeStore()..outcome = PurchaseOutcome.pending;
      final subs = SubscriptionService(backend: store);
      await _pump(tester, PaywallScreen(subscriptions: subs));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('paywall_subscribe')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paywall_note')), findsOneWidget);
      expect(subs.isPro, isFalse);
    });

    testWidgets('no plans from Google Play offers a retry', (tester) async {
      await _pump(tester, PaywallScreen(subscriptions: SubscriptionService(backend: FakeStore(offered: const []))));
      await tester.pumpAndSettle();
      expect(find.textContaining('No plans are available'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('new visits', () {
    late AuthService savedAuth;
    setUp(() => savedAuth = AuthService.instance);
    tearDown(() => AuthService.instance = savedAuth);

    testWidgets('need Pro for a signed-in clinician; an access code unlocks them', (tester) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      AuthService.instance = FakeAuth();
      SubscriptionService.instance = SubscriptionService(backend: FakeStore(grantedCustomers: {'access_REVIEW2026'}));
      await _pump(tester, PatientChartScreen(accountNumber: a.accountNumber));
      await tester.tap(find.text("Start today's visit"));
      await tester.pumpAndSettle();
      expect(find.byType(PaywallScreen), findsOneWidget);
      expect(repo.byNumber(a.accountNumber)!.visits, isEmpty);
      await tester.tap(find.byKey(const Key('paywall_code')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('access_code')), 'review-2026');
      await tester.tap(find.byKey(const Key('access_code_submit')));
      await tester.pumpAndSettle();
      expect(find.byType(PaywallScreen), findsNothing);
      expect(repo.byNumber(a.accountNumber)!.visits, hasLength(1));
    });

    testWidgets('closing the paywall starts nothing', (tester) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      AuthService.instance = FakeAuth();
      SubscriptionService.instance = SubscriptionService(backend: FakeStore());
      await _pump(tester, PatientChartScreen(accountNumber: a.accountNumber));
      await tester.tap(find.text("Start today's visit"));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(repo.byNumber(a.accountNumber)!.visits, isEmpty);
    });
  });

  testWidgets('settings shows the plan and the legal links', (tester) async {
    final subs = SubscriptionService(backend: FakeStore(grantedCustomers: {'access_PILOT01'}));
    await _pump(tester, Scaffold(body: SingleChildScrollView(child: AccountSection(auth: FakeAuth(), subscriptions: subs))));
    expect(find.text('Get SOLIS Pro'), findsOneWidget);
    expect(find.byKey(const Key('account_privacy')), findsOneWidget);
    expect(find.byKey(const Key('account_terms')), findsOneWidget);
    await subs.redeemAccessCode('PILOT01');
    await tester.pump();
    expect(find.text('Unlocked with access code PILOT01'), findsOneWidget);
    await _pump(tester, Scaffold(body: AccountSection(auth: FakeAuth(demo: true, account: false), subscriptions: subs)));
    expect(find.byKey(const Key('account_subscription')), findsNothing, reason: 'demo is free');
  });
}
