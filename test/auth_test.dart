import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solis_mobile/screens/login_screen.dart';
import 'package:solis_mobile/screens/sign_up_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/auth_service.dart';
import 'package:solis_mobile/services/solis_backend.dart';
import 'package:solis_mobile/theme/solis_theme.dart';
import 'package:solis_mobile/widgets/account_section.dart';
import 'package:solis_mobile/widgets/medical_disclaimer.dart';

import 'support/test_provider.dart';

final base = Uri.parse('https://solis.example.workers.dev');

Map<String, dynamic> serverSession({String access = 'sat_1', String refresh = 'srt_1', Duration ttl = const Duration(hours: 12)}) => {
      'user': {'id': 'u1', 'email': 'ada@clinic.example', 'fullName': 'Ada Lovelace', 'npi': null},
      'session': {
        'accessToken': access,
        'refreshToken': refresh,
        'expiresAt': DateTime.now().toUtc().add(ttl).toIso8601String(),
        'refreshExpiresAt': DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
      },
    };

/// A fake SOLIS server: routes by path, records every request.
class FakeServer {
  final requests = <http.Request>[];
  final Map<String, FutureOr<http.Response> Function(http.Request)> routes;
  FakeServer(this.routes);

  MockClient get client => MockClient((req) async {
        requests.add(req);
        final p = req.url.path.replaceFirst('/api/v2', '');
        final h = routes[p];
        return h == null ? http.Response('{"error":"not found"}', 404) : await h(req);
      });

  List<http.Request> to(String path) => requests.where((r) => r.url.path.endsWith(path)).toList();
}

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

AuthService makeAuth(FakeServer s, {SessionStore? store, Future<Map<String, String>> Function(String)? integrity}) => AuthService(
      backend: SolisBackend(baseUrl: base, appToken: 'apptok'),
      httpClient: s.client,
      store: store ?? MemorySessionStore(),
      integrityHeaders: integrity ?? (_) async => const {},
    );

Widget host(Widget home) => MaterialApp(
      theme: SolisTheme.lightTheme(),
      home: home,
      routes: {
        '/patients': (_) => const Scaffold(body: Text('PATIENTS')),
        '/setup': (_) => const Scaffold(body: Text('SETUP')),
        '/login': (_) => const Scaffold(body: Text('LOGIN')),
        '/signup': (_) => const SignUpScreen(),
      },
    );

void main() {
  group('AuthService', () {
    test('login stores the session, sends the app token, and survives a restart offline', () async {
      final s = FakeServer({'/auth/login': (_) => json(serverSession())});
      final store = MemorySessionStore();
      final auth = makeAuth(s, store: store);
      final user = await auth.login(email: ' ada@clinic.example ', password: 'correct horse battery');
      expect(user.fullName, 'Ada Lovelace');
      expect(auth.hasAccount, isTrue);
      final req = s.to('/auth/login').single;
      expect(req.headers['Authorization'], 'Bearer apptok');
      expect(jsonDecode(req.body)['email'], 'ada@clinic.example');

      // New process, no network at all: the cached session still opens the app.
      final offline = makeAuth(FakeServer({}), store: store);
      expect(await offline.restore(), AuthMode.account);
      expect(offline.user?.email, 'ada@clinic.example');
      expect(await offline.accessToken(), 'sat_1');
    });

    test('wrong password and offline give clear errors and no session', () async {
      final s = FakeServer({'/auth/login': (_) => json({'error': 'Email or password is incorrect', 'code': 'bad_credentials'}, 401)});
      final auth = makeAuth(s);
      await expectLater(
        auth.login(email: 'ada@clinic.example', password: 'nope nope nope'),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'bad_credentials').having((e) => e.message, 'message', contains('incorrect'))),
      );
      expect(auth.isSignedIn, isFalse);

      final down = AuthService(
        backend: SolisBackend(baseUrl: base, appToken: 'apptok'),
        httpClient: MockClient((_) async => throw const SocketExceptionLike()),
        store: MemorySessionStore(),
        integrityHeaders: (_) async => const {},
      );
      await expectLater(down.login(email: 'a@b.example', password: 'x'), throwsA(isA<AuthException>().having((e) => e.isOffline, 'offline', isTrue)));
    });

    test('sign-in and sign-up carry the Play Integrity headers; other calls do not', () async {
      final paths = <String>[];
      final s = FakeServer({
        '/auth/login': (_) => json(serverSession()),
        '/auth/register': (_) => json(serverSession(), 201),
        '/auth/logout': (_) => json({'ok': true}),
      });
      final auth = makeAuth(s, integrity: (path) async {
        paths.add(path);
        return {'X-Solis-Integrity': 'tok', 'X-Solis-Integrity-Nonce': 'n0nce'};
      });
      await auth.register(fullName: 'Ada', email: 'ada@clinic.example', password: 'correct horse battery');
      await auth.login(email: 'ada@clinic.example', password: 'correct horse battery');
      await auth.signOut();
      expect(paths, ['/api/v2/auth/register', '/api/v2/auth/login']);
      expect(s.to('/auth/login').single.headers['X-Solis-Integrity'], 'tok');
      expect(s.to('/auth/logout').single.headers.containsKey('X-Solis-Integrity'), isFalse);
    });

    test('an expired access token is refreshed once, even with concurrent callers', () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final s = FakeServer({
        '/auth/login': (_) => json(serverSession(ttl: const Duration(seconds: -5))),
        '/auth/refresh': (_) async {
          refreshes++;
          await gate.future;
          return json(serverSession(access: 'sat_2', refresh: 'srt_2'));
        },
      });
      final auth = makeAuth(s);
      await auth.login(email: 'ada@clinic.example', password: 'pw pw pw pw pw');
      final calls = [for (var i = 0; i < 5; i++) auth.accessToken()];
      gate.complete();
      expect(await Future.wait(calls), everyElement('sat_2'));
      expect(refreshes, 1);
    });

    test('a refused refresh signs out locally', () async {
      final s = FakeServer({
        '/auth/login': (_) => json(serverSession(ttl: const Duration(seconds: -5))),
        '/auth/refresh': (_) => json({'error': 'Session expired. Sign in again.', 'code': 'session_invalid'}, 401),
      });
      final auth = makeAuth(s);
      await auth.login(email: 'ada@clinic.example', password: 'pw pw pw pw pw');
      expect(await auth.accessToken(), isNull);
      expect(auth.isSignedIn, isFalse);
    });

    test('cloud calls send the session and retry once after the server rejects it', () async {
      final s = FakeServer({
        '/auth/login': (_) => json(serverSession()),
        '/auth/refresh': (_) => json(serverSession(access: 'sat_2', refresh: 'srt_2')),
      });
      final auth = makeAuth(s);
      await auth.login(email: 'ada@clinic.example', password: 'pw pw pw pw pw');
      final seen = <String?>[];
      final backend = SolisBackend(
        baseUrl: base,
        appToken: 'apptok',
        sessions: auth,
        httpClient: MockClient((req) async {
          seen.add(req.headers[SolisBackend.sessionHeader]);
          if (req.headers[SolisBackend.sessionHeader] == 'sat_1') return json({'error': 'Session expired or signed out', 'code': 'session_invalid'}, 401);
          return json({'success': false, 'error': 'no transcript'}, 400);
        }),
      );
      await expectLater(backend.writeNote(transcript: 'x'), throwsA(isA<BackendException>()));
      expect(seen, ['sat_1', 'sat_2']);
    });

    test('demo mode stays local and has no account to delete', () async {
      final s = FakeServer({});
      final auth = makeAuth(s);
      await auth.startDemo();
      expect(auth.isDemo, isTrue);
      expect(await auth.accessToken(), isNull);
      await expectLater(auth.deleteAccount('x'), throwsA(isA<AuthException>()));
      expect(s.requests, isEmpty);
    });
  });

  group('Login screen', () {
    testWidgets('shows the disclaimer, signs in and opens practice setup first', (t) async {
      final s = FakeServer({'/auth/login': (_) => json(serverSession())});
      AuthService.instance = makeAuth(s);
      final repo = AccountRepository.memory();
      AccountRepository.instance = repo;
      await t.pumpWidget(host(const LoginScreen()));
      expect(find.text(solisDisclaimer), findsOneWidget);
      await t.enterText(find.byKey(const Key('login_email')), 'ada@clinic.example');
      await t.enterText(find.byKey(const Key('login_password')), 'correct horse battery');
      await t.tap(find.byKey(const Key('login_submit')));
      await t.pumpAndSettle();
      // A real account with no practice profile sets it up before patients.
      expect(find.text('SETUP'), findsOneWidget);
      expect(AuthService.instance.hasAccount, isTrue);
      expect(repo.demoMode, isFalse);
      expect(repo.provider.isDemoIdentity, isFalse);
    });

    testWidgets('a clinician whose practice is set up goes straight to patients', (t) async {
      final s = FakeServer({'/auth/login': (_) => json(serverSession())});
      AuthService.instance = makeAuth(s);
      final repo = AccountRepository.memory();
      AccountRepository.instance = repo;
      await repo.saveProvider(testProvider());
      await t.pumpWidget(host(const LoginScreen()));
      await t.enterText(find.byKey(const Key('login_email')), 'ada@clinic.example');
      await t.enterText(find.byKey(const Key('login_password')), 'correct horse battery');
      await t.tap(find.byKey(const Key('login_submit')));
      await t.pumpAndSettle();
      expect(find.text('PATIENTS'), findsOneWidget);
    });

    testWidgets('a wrong password shows the server message and stays', (t) async {
      final s = FakeServer({'/auth/login': (_) => json({'error': 'Email or password is incorrect', 'code': 'bad_credentials'}, 401)});
      AuthService.instance = makeAuth(s);
      await t.pumpWidget(host(const LoginScreen()));
      await t.enterText(find.byKey(const Key('login_email')), 'ada@clinic.example');
      await t.enterText(find.byKey(const Key('login_password')), 'wrong');
      await t.tap(find.byKey(const Key('login_submit')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('login_error')), findsOneWidget);
      expect(find.text('Email or password is incorrect'), findsOneWidget);
      expect(find.text('PATIENTS'), findsNothing);
    });

    testWidgets('a double tap on Sign in sends one request', (t) async {
      final gate = Completer<void>();
      final s = FakeServer({
        '/auth/login': (_) async {
          await gate.future;
          return json(serverSession());
        },
      });
      AuthService.instance = makeAuth(s);
      AccountRepository.instance = AccountRepository.memory();
      await t.pumpWidget(host(const LoginScreen()));
      await t.enterText(find.byKey(const Key('login_email')), 'ada@clinic.example');
      await t.enterText(find.byKey(const Key('login_password')), 'correct horse battery');
      await t.tap(find.byKey(const Key('login_submit')));
      await t.pump();
      await t.tap(find.byKey(const Key('login_submit')), warnIfMissed: false);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      gate.complete();
      await t.pumpAndSettle();
      expect(s.to('/auth/login'), hasLength(1));
    });

    testWidgets('the demo account works with no server and shows only demo data', (t) async {
      final s = FakeServer({});
      AuthService.instance = makeAuth(s);
      final repo = AccountRepository.memory();
      AccountRepository.instance = repo;
      await t.pumpWidget(host(const LoginScreen()));
      await t.tap(find.byKey(const Key('login_demo')));
      await t.pumpAndSettle();
      expect(find.text('PATIENTS'), findsOneWidget);
      expect(AuthService.instance.isDemo, isTrue);
      expect(s.requests, isEmpty);
      expect(repo.demoMode, isTrue);
      expect(repo.accounts, hasLength(5));
      expect(repo.accounts.every((a) => a.isSample), isTrue);
      expect(repo.provider.isDemoIdentity, isTrue);
    });

    testWidgets('Request access opens sign-up, which registers', (t) async {
      final s = FakeServer({'/auth/register': (_) => json(serverSession(), 201)});
      AuthService.instance = makeAuth(s);
      AccountRepository.instance = AccountRepository.memory();
      await t.pumpWidget(host(const LoginScreen()));
      await t.tap(find.byKey(const Key('login_request_access')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('signup_name')), 'Ada Lovelace');
      await t.enterText(find.byKey(const Key('signup_email')), 'ada@clinic.example');
      await t.enterText(find.byKey(const Key('signup_password')), 'short');
      await t.tap(find.byKey(const Key('signup_submit')));
      await t.pumpAndSettle();
      expect(find.text('Use at least ${AuthService.minPasswordLength} characters'), findsOneWidget);
      expect(s.requests, isEmpty);
      await t.enterText(find.byKey(const Key('signup_password')), 'correct horse battery');
      await t.tap(find.byKey(const Key('signup_submit')));
      await t.pumpAndSettle();
      // A new clinician sets up the practice before any patient or claim.
      expect(find.text('SETUP'), findsOneWidget);
      expect(jsonDecode(s.to('/auth/register').single.body)['fullName'], 'Ada Lovelace');
    });
  });

  group('Delete account', () {
    Future<AuthService> signedIn(FakeServer s) async {
      final auth = makeAuth(s);
      await auth.login(email: 'ada@clinic.example', password: 'correct horse battery');
      AuthService.instance = auth;
      return auth;
    }

    Widget section() => host(const Scaffold(body: SingleChildScrollView(child: AccountSection())));

    testWidgets('wrong password keeps the account and the data', (t) async {
      final repo = AccountRepository.memory();
      AccountRepository.instance = repo;
      await repo.seedDemoIfEmpty();
      final s = FakeServer({
        '/auth/login': (_) => json(serverSession()),
        '/auth/delete-account': (_) => json({'error': 'Password is incorrect', 'code': 'bad_credentials'}, 401),
      });
      await t.runAsync(() => signedIn(s));
      await t.pumpWidget(section());
      await t.tap(find.byKey(const Key('account_delete')));
      await t.pumpAndSettle();
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await t.enterText(find.byKey(const Key('delete_password')), 'wrong');
      await t.tap(find.byKey(const Key('delete_confirm')));
      await t.pumpAndSettle();
      expect(find.text('Password is incorrect'), findsOneWidget);
      expect(AuthService.instance.hasAccount, isTrue);
      expect(repo.accounts, isNotEmpty);
    });

    testWidgets('the right password deletes the account, erases local data and signs out', (t) async {
      final repo = AccountRepository.memory();
      AccountRepository.instance = repo;
      await repo.seedDemoIfEmpty();
      final s = FakeServer({
        '/auth/login': (_) => json(serverSession()),
        '/auth/delete-account': (req) {
          expect(req.headers[SolisBackend.sessionHeader], 'sat_1');
          expect(jsonDecode(req.body)['password'], 'correct horse battery');
          return json({'deleted': true});
        },
      });
      await t.runAsync(() => signedIn(s));
      await t.pumpWidget(section());
      expect(find.text('Ada Lovelace'), findsOneWidget);
      await t.tap(find.byKey(const Key('account_delete')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('delete_password')), 'correct horse battery');
      await t.tap(find.byKey(const Key('delete_confirm')));
      await t.pumpAndSettle();
      expect(find.text('LOGIN'), findsOneWidget);
      expect(AuthService.instance.isSignedIn, isFalse);
      expect(repo.accounts, isEmpty);
    });

    testWidgets('demo mode cannot delete and signs out locally', (t) async {
      final s = FakeServer({});
      final auth = makeAuth(s);
      await t.runAsync(auth.startDemo);
      AuthService.instance = auth;
      await t.pumpWidget(section());
      expect(find.text('Demo account'), findsOneWidget);
      final tile = t.widget<ListTile>(find.byKey(const Key('account_delete')));
      expect(tile.enabled, isFalse);
      await t.tap(find.byKey(const Key('account_sign_out')));
      await t.pumpAndSettle();
      expect(find.text('LOGIN'), findsOneWidget);
      expect(s.requests, isEmpty);
    });
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
