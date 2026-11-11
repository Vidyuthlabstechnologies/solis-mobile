import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../config/app_config.dart';
import 'subscription_service.dart';

/// Google Play Billing through RevenueCat. Only built when
/// [AppConfig.revenueCatAndroidKey] is set.
class RevenueCatBackend implements SubscriptionBackend {
  final String apiKey;
  final String entitlement;
  RevenueCatBackend({this.apiKey = AppConfig.revenueCatAndroidKey, this.entitlement = AppConfig.proEntitlement});

  @override
  Future<void> configure({String? appUserId}) async {
    final c = PurchasesConfiguration(apiKey)..appUserID = appUserId;
    await Purchases.configure(c);
  }

  bool _active(CustomerInfo info) => info.entitlements.active[entitlement]?.isActive ?? false;

  @override
  Future<bool> isPro() => _guard(() async => _active(await Purchases.getCustomerInfo()));

  @override
  Future<List<SubscriptionPlan>> plans() => _guard(() async {
        final offering = (await Purchases.getOfferings()).current;
        if (offering == null) return const <SubscriptionPlan>[];
        final packages = [
          if (offering.monthly != null) offering.monthly!,
          if (offering.annual != null) offering.annual!,
        ];
        return [for (final p in packages.isEmpty ? offering.availablePackages : packages) planFor(p)];
      });

  static SubscriptionPlan planFor(Package p) {
    final s = p.storeProduct;
    final yearly = p.packageType == PackageType.annual || s.subscriptionPeriod == 'P1Y';
    final free = s.defaultOption?.freePhase?.billingPeriod;
    return SubscriptionPlan(
      id: p.identifier,
      title: yearly ? 'SOLIS Pro yearly' : 'SOLIS Pro monthly',
      price: s.priceString,
      period: yearly ? 'year' : 'month',
      trial: free == null ? null : trialLabel(free.value, free.unit),
      perMonth: yearly && s.pricePerMonthString != null ? '${s.pricePerMonthString}/month' : null,
      handle: p,
    );
  }

  @override
  Future<PurchaseOutcome> purchase(SubscriptionPlan plan) async {
    try {
      final result = await Purchases.purchase(PurchaseParams.package(plan.handle! as Package));
      return _active(result.customerInfo) ? PurchaseOutcome.purchased : PurchaseOutcome.pending;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) return PurchaseOutcome.cancelled;
      if (code == PurchasesErrorCode.paymentPendingError) return PurchaseOutcome.pending;
      throw SubscriptionException(messageFor(code));
    }
  }

  @override
  Future<bool> restore() => _guard(() async => _active(await Purchases.restorePurchases()));

  @override
  Future<bool> logIn(String appUserId) => _guard(() async => _active((await Purchases.logIn(appUserId)).customerInfo));

  @override
  Future<void> logOut() => _guard(() async {
        if (await Purchases.isAnonymous) return;
        await Purchases.logOut();
      });

  @override
  Future<ProRenewal?> renewal() => _guard(() async {
        final e = (await Purchases.getCustomerInfo()).entitlements.active[entitlement];
        if (e == null) return null;
        return ProRenewal(
          endsAt: DateTime.tryParse(e.expirationDate ?? ''),
          willRenew: e.willRenew,
          inTrial: e.periodType == PeriodType.trial,
        );
      });

  @override
  Future<String?> managementUrl() => _guard(() async => (await Purchases.getCustomerInfo()).managementURL);

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on PlatformException catch (e) {
      throw SubscriptionException(messageFor(PurchasesErrorHelper.getErrorCode(e)));
    }
  }
}

String trialLabel(int value, PeriodUnit unit) => switch (unit) {
      PeriodUnit.day => '$value-day free trial',
      PeriodUnit.week => value == 1 ? '7-day free trial' : '$value-week free trial',
      PeriodUnit.month => value == 1 ? '1-month free trial' : '$value-month free trial',
      PeriodUnit.year => '$value-year free trial',
      PeriodUnit.unknown => 'Free trial',
    };

/// What went wrong, in words a clinician can act on.
String messageFor(PurchasesErrorCode code) => switch (code) {
      PurchasesErrorCode.networkError => 'No connection to Google Play. Check your internet and try again.',
      PurchasesErrorCode.storeProblemError => 'Google Play had a problem. Try again in a few minutes.',
      PurchasesErrorCode.purchaseNotAllowedError => 'This Google account or device is not allowed to make purchases. Check Google Play settings or family controls.',
      PurchasesErrorCode.productNotAvailableForPurchaseError => 'This plan is not available in your country or for this Google account.',
      PurchasesErrorCode.productAlreadyPurchasedError => 'This Google account already has SOLIS Pro. Tap Restore purchase.',
      PurchasesErrorCode.receiptAlreadyInUseError ||
      PurchasesErrorCode.receiptInUseByOtherSubscriberError =>
        'This subscription belongs to another SOLIS account. Sign in with that account, or contact support.',
      PurchasesErrorCode.operationAlreadyInProgressError => 'A purchase is already in progress. Wait a moment.',
      PurchasesErrorCode.ineligibleError => 'This Google account is not eligible for that offer.',
      PurchasesErrorCode.configurationError ||
      PurchasesErrorCode.invalidCredentialsError ||
      PurchasesErrorCode.unexpectedBackendResponseError ||
      PurchasesErrorCode.unknownBackendError =>
        'Subscriptions are not working in this version of SOLIS. Please contact support; you have not been charged.',
      _ => 'The purchase did not go through (${code.name}). You have not been charged.',
    };
