import 'package:flutter/foundation.dart';

import '../../config/app_config.dart';
import '../auth_service.dart';

/// One plan on the paywall, as Google Play prices it for this phone.
class SubscriptionPlan {
  final String id;
  final String title;

  /// Localized price from Google Play, e.g. "$149.00".
  final String price;

  /// "month" or "year".
  final String period;

  /// e.g. "7-day free trial", when Google Play offers one to this account.
  final String? trial;

  /// e.g. "$129.00/month", for yearly plans.
  final String? perMonth;

  /// The store object the backend needs to buy it.
  final Object? handle;

  const SubscriptionPlan({required this.id, required this.title, required this.price, required this.period, this.trial, this.perMonth, this.handle});

  bool get isYearly => period == 'year';
}

/// A purchase or restore problem, worded for the clinician.
class SubscriptionException implements Exception {
  final String message;
  const SubscriptionException(this.message);
  @override
  String toString() => message;
}

enum PurchaseOutcome { purchased, cancelled, pending }

/// What a store SDK must do. The RevenueCat version is used in release
/// builds; tests use a fake.
/// When the current Pro period ends, and what happens then.
class ProRenewal {
  final DateTime? endsAt;
  final bool willRenew;
  final bool inTrial;

  const ProRenewal({this.endsAt, this.willRenew = true, this.inTrial = false});

  /// "Free trial until Nov 25, then renews", "Renews Dec 11",
  /// "Ends Dec 11 (cancelled)".
  String describe() {
    final d = endsAt?.toLocal();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final when = d == null ? null : '${months[d.month - 1]} ${d.day}, ${d.year}';
    if (inTrial) return when == null ? 'Free trial' : 'Free trial until $when${willRenew ? ', then the plan starts' : ', then ends'}';
    if (when == null) return willRenew ? 'Renews automatically' : 'Cancelled';
    return willRenew ? 'Renews $when' : 'Ends $when (cancelled)';
  }
}

abstract class SubscriptionBackend {
  Future<void> configure({String? appUserId});

  /// Whether the Pro entitlement is active for the current customer.
  Future<bool> isPro();
  Future<List<SubscriptionPlan>> plans();

  /// Throws [SubscriptionException] for real problems.
  Future<PurchaseOutcome> purchase(SubscriptionPlan plan);
  Future<bool> restore();
  Future<bool> logIn(String appUserId);
  Future<void> logOut();
  Future<String?> managementUrl();

  /// The current Pro period, or null when not Pro or not known.
  Future<ProRenewal?> renewal();
}

/// SOLIS Pro: whether this clinician may start new visits, and the actions
/// on the paywall. The demo account is always free, and a build without a
/// RevenueCat key does not ask anyone to pay.
class SubscriptionService extends ChangeNotifier {
  static SubscriptionService? _instance;
  static SubscriptionService get instance => _instance ??= SubscriptionService(backend: null);

  /// Set once at start-up (and by tests).
  static set instance(SubscriptionService? s) => _instance = s;

  final SubscriptionBackend? _backend;
  SubscriptionService({required SubscriptionBackend? backend}) : _backend = backend; // ignore: prefer_initializing_formals

  bool _ready = false;
  bool _pro = false;
  String? _customer;
  String? _accessCode;

  /// True when this build sells subscriptions.
  bool get isConfigured => _backend != null;
  bool get isPro => _pro;

  /// The reviewer or partner code in use, if Pro came from one.
  String? get accessCode => _accessCode;

  /// Whether billing a real claim needs Pro first. Notes are free and
  /// unlimited; Pro is what sends claims to payers. Test claims and the demo
  /// are always free.
  bool blocksRealClaims(AuthService auth) => isConfigured && !auth.isDemo && !_pro;

  /// Sets up the SDK and keeps the customer in step with who is signed in.
  Future<void> attach(AuthService auth) async {
    final b = _backend;
    if (b == null) return;
    try {
      await b.configure(appUserId: auth.hasAccount ? auth.user?.id : null);
      _ready = true;
      _customer = auth.hasAccount ? auth.user?.id : null;
      await refresh();
    } catch (_) {
      // Offline or misconfigured: stay locked until a refresh succeeds.
    }
    auth.addListener(() => _follow(auth));
  }

  Future<void> _follow(AuthService auth) async {
    final b = _backend;
    if (b == null || !_ready) return;
    final id = auth.hasAccount ? auth.user?.id : null;
    if (id == _customer && _accessCode == null) return;
    try {
      if (id == null) {
        if (_customer != null || _accessCode != null) await b.logOut();
      } else {
        _pro = await b.logIn(id);
      }
      _customer = id;
      _accessCode = null;
      if (id == null) _pro = false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refresh() async {
    final b = _backend;
    if (b == null) return;
    try {
      _pro = await b.isPro();
      _renewal = _pro && _accessCode == null ? await b.renewal() : null;
      notifyListeners();
    } catch (_) {}
  }

  ProRenewal? _renewal;

  /// Trial end or renewal date for Settings, when Google Play reports one.
  ProRenewal? get renewal => _renewal;

  Future<List<SubscriptionPlan>> plans() async {
    final b = _backend;
    if (b == null) return const [];
    final list = await b.plans();
    if (list.isEmpty) {
      throw const SubscriptionException('No plans are available from Google Play right now. Check your connection and try again.');
    }
    return list;
  }

  Future<PurchaseOutcome> purchase(SubscriptionPlan plan) async {
    final b = _requireBackend();
    final outcome = await b.purchase(plan);
    if (outcome == PurchaseOutcome.purchased) {
      _pro = await b.isPro();
      notifyListeners();
    }
    return outcome;
  }

  /// Returns true when an active subscription was found.
  Future<bool> restore() async {
    final b = _requireBackend();
    _pro = await b.restore();
    notifyListeners();
    return _pro;
  }

  /// Unlocks Pro with a code the owner granted in RevenueCat (customer
  /// `access_<CODE>`), for Play reviewers and pilot clinics.
  Future<void> redeemAccessCode(String raw) async {
    final b = _requireBackend();
    final code = normalizeAccessCode(raw);
    if (code == null) throw const SubscriptionException('Enter the access code you were given (letters and numbers).');
    final ok = await b.logIn('access_$code');
    if (!ok) {
      // Go back to the clinician's own customer before reporting.
      if (_customer != null) {
        await b.logIn(_customer!);
      } else {
        await b.logOut();
      }
      throw const SubscriptionException("That access code isn't active. Check it, or contact the person who gave it to you.");
    }
    _accessCode = code;
    _pro = true;
    notifyListeners();
  }

  Future<String> managementUrl() async {
    final b = _backend;
    final url = b == null ? null : await b.managementUrl().catchError((Object _) => null);
    return url ?? AppConfig.playSubscriptionsUrl;
  }

  SubscriptionBackend _requireBackend() {
    final b = _backend;
    if (b == null) throw const SubscriptionException('Subscriptions are not available in this build.');
    return b;
  }
}

/// Upper-case letters and digits, 4 to 32 long; spaces and dashes ignored.
String? normalizeAccessCode(String raw) {
  final code = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^[A-Z0-9]{4,32}$').hasMatch(code) ? code : null;
}
