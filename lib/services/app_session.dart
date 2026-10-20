import 'account_repository.dart';
import 'auth_service.dart';

/// Connects the sign-in mode to the local data and picks the first screen.
///
/// Demo mode gets the demo provider and the sample patients. A signed-in
/// clinician gets only their own data, and goes to practice setup until
/// their provider profile can bill, so no claim can leave under a fictional
/// or incomplete identity.
class AppSession {
  AppSession._();

  static const loginRoute = '/login';
  static const setupRoute = '/setup';
  static const homeRoute = '/patients';

  /// Applies [mode] to [repo]: seeds and shows the demo data in demo mode,
  /// hides it otherwise.
  static Future<void> apply(AuthMode mode, AccountRepository repo) async {
    if (mode == AuthMode.demo) {
      await repo.seedDemoIfEmpty();
    } else {
      repo.setDemoMode(false);
    }
  }

  /// The route to open after sign-in, sign-up or app start.
  static String routeFor(AuthMode mode, AccountRepository repo) {
    if (mode == AuthMode.signedOut) return loginRoute;
    if (mode == AuthMode.account && !repo.provider.isComplete) return setupRoute;
    return homeRoute;
  }

  /// Applies the current mode and returns the route to open.
  static Future<String> start(AuthService auth, AccountRepository repo) async {
    await apply(auth.mode, repo);
    return routeFor(auth.mode, repo);
  }
}
