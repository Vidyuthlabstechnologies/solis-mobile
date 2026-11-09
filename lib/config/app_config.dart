import 'package:flutter/services.dart' show appFlavor;

/// Values passed at build time with `--dart-define` (or
/// `--dart-define-from-file`). Nothing secret lives in the repo: the release
/// workflow reads them from GitHub secrets. A feature whose key is missing
/// stays hidden instead of failing in front of the clinician.
class AppConfig {
  const AppConfig._();

  /// The Android build this is: `play` (Google Play) or `standalone`
  /// (installed from the website). Set by `flutter build --flavor`.
  static String get distribution => appFlavor ?? 'play';

  /// No Google Play here: no Play Billing, no Play Integrity, nothing locked.
  static bool get isStandalone => distribution == 'standalone';

  /// RevenueCat public SDK key for Google Play (starts with `goog_`).
  static const revenueCatAndroidKey = String.fromEnvironment('REVENUECAT_ANDROID_KEY');

  /// The RevenueCat entitlement that unlocks SOLIS Pro.
  static const proEntitlement = String.fromEnvironment('REVENUECAT_ENTITLEMENT', defaultValue: 'pro');

  static const privacyPolicyUrl = String.fromEnvironment('PRIVACY_POLICY_URL', defaultValue: 'https://solis-health.pages.dev/privacy');
  static const termsUrl = String.fromEnvironment('TERMS_URL', defaultValue: 'https://solis-health.pages.dev/terms');
  static const deleteAccountUrl = String.fromEnvironment('DELETE_ACCOUNT_URL', defaultValue: 'https://solis-health.pages.dev/delete-account');
  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL');

  /// Google Play's own subscriptions page, used when RevenueCat has no
  /// management link yet.
  static const playSubscriptionsUrl = 'https://play.google.com/store/account/subscriptions?package=com.solis.clinical.solis_mobile';

  /// Subscriptions are sold only in the Google Play build with a key.
  static bool get hasRevenueCat => !isStandalone && revenueCatAndroidKey.startsWith('goog_');
}
