import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/login_screen.dart';
import 'screens/patients_screen.dart';
import 'screens/provider_profile_screen.dart';
import 'screens/sign_up_screen.dart';
import 'services/account_repository.dart';
import 'services/app_session.dart';
import 'services/auth_service.dart';
import 'services/codesets/codeset_updates.dart';
import 'services/codesets/reference_data.dart';
import 'services/integrations.dart';
import 'services/security_and_background_service.dart';
import 'services/solis_backend.dart';
import 'services/theme_preference.dart';
import 'services/transcription/native_speech_provider.dart';
import 'widgets/on_device_speech_card.dart';
import 'theme/solis_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = await AccountRepository.open();
  SecurityAndBackgroundService.setScreenshotsBlocked(repo.provider.blockScreenshots).ignore();
  await Integrations.init();
  // A clinician who signed in before opens straight to their patients, even
  // offline; cloud calls send the session alongside the app token.
  final auth = AuthService.instance;
  SolisBackend.defaultSessions = auth;
  await auth.restore();
  // Demo data only in demo mode; a clinician without a complete practice
  // profile goes to setup before any patient or claim.
  final initialRoute = await AppSession.start(auth, repo);
  final themePreference = await ThemePreference.load();
  // Official code sets load in background isolates; checks use them once
  // ready. A verified downloaded update (if any) is read first, the bundled
  // assets otherwise; a newer one found today is applied at the next start.
  final codesets = await CodesetUpdates.start();
  final referenceLoad = codesets?.loadReferenceData() ?? ReferenceData.load();
  // On-device voice engine, when this phone supports it and models are downloaded.
  NativeSpeechProvider.register(options: onDeviceSpeechOptions).ignore();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(SolisApp(initialRoute: initialRoute, themePreference: themePreference));
  codesets?.scheduleCheck(after: referenceLoad);
}

class SolisApp extends StatefulWidget {
  final String initialRoute;
  final ThemePreference? themePreference;
  const SolisApp({super.key, this.initialRoute = '/login', this.themePreference});

  @override
  State<SolisApp> createState() => _SolisAppState();
}

class _SolisAppState extends State<SolisApp> with WidgetsBindingObserver {
  // Follows the phone's light/dark setting until the clinician picks one.
  late final ThemePreference _theme = widget.themePreference ?? ThemePreference.memory();

  bool get _isDark => _theme.isDark(WidgetsBinding.instance.platformDispatcher.platformBrightness);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (_theme.mode == ThemeMode.system) setState(() {});
  }

  void _toggleTheme(bool isDark) {
    setState(() => _theme.mode = isDark ? ThemeMode.dark : ThemeMode.light);
    _theme.set(_theme.mode);
  }

  @override
  Widget build(BuildContext context) {
    final routes = <String, WidgetBuilder>{
      '/login': (context) => LoginScreen(
            isDark: _isDark,
            onThemeToggle: _toggleTheme,
          ),
      '/signup': (context) => const SignUpScreen(),
      AppSession.setupRoute: (context) => const ProviderProfileScreen(firstRun: true),
      '/patients': (context) => PatientsScreen(
            isDark: _isDark,
            onThemeToggle: _toggleTheme,
          ),
    };
    return MaterialApp(
      title: 'SOLIS Clinical OS',
      debugShowCheckedModeBanner: false,
      themeMode: _theme.mode,
      theme: SolisTheme.lightTheme(),
      darkTheme: SolisTheme.darkTheme(),
      initialRoute: widget.initialRoute,
      // Start on exactly one screen (sign-in or, when signed in, patients).
      onGenerateInitialRoutes: (name) => [
        MaterialPageRoute<void>(
          settings: RouteSettings(name: routes.containsKey(name) ? name : '/login'),
          builder: routes[name] ?? routes['/login']!,
        ),
      ],
      routes: routes,
    );
  }
}
