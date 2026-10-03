import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/login_page.dart';

final Uint8List _validPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
  ),
);

class _RouteObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
}

Widget _app(AuthCubit cubit, _RouteObserver observer) => BlocProvider.value(
  value: cubit,
  child: MaterialApp(
    navigatorObservers: [observer],
    home: Builder(
      builder:
          (context) => Scaffold(
            appBar: AppBar(title: const Text('Test home')),
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(builder: (_) => const LoginPage()),
                  );
                },
                child: const Text('Open login'),
              ),
            ),
          ),
    ),
  ),
);

Future<void> _openLogin(WidgetTester tester) async {
  await tester.tap(find.text('Open login'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpFrames(
  WidgetTester tester, {
  int count = 5,
  Duration step = const Duration(milliseconds: 20),
}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(step);
  }
}

Finder get _loginButton => find.byType(FilledButton);
Finder get _siteLoginButton => find.text('打开站点验证 / 登录');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an authenticated user stays on the re-login page when captcha finishes',
    (tester) async {
      final captcha = Completer<Uint8List>();
      final cubit = AuthCubit(
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async => true,
        downloadCheckcode: () => captcha.future,
      );
      addTearDown(cubit.close);
      await cubit.init();
      expect(cubit.state.status, AuthStatus.authenticated);

      final observer = _RouteObserver();
      await tester.pumpWidget(_app(cubit, observer));
      await _openLogin(tester);
      expect(cubit.state.checkcodeStatus, CheckcodeStatus.loading);
      captcha.complete(_validPng);
      await _pumpFrames(tester);

      expect(cubit.state.status, AuthStatus.authenticated);
      expect(find.text('验证码'), findsOneWidget);
      expect(observer.pops, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a 403 shows safe recovery actions, retry works, and login stays disabled',
    (tester) async {
      var downloads = 0;
      final cubit = AuthCubit(
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async => false,
        downloadCheckcode: () async {
          downloads++;
          throw StateError('HTTP 403 Forbidden');
        },
      );
      addTearDown(cubit.close);
      await cubit.init();
      final observer = _RouteObserver();
      await tester.pumpWidget(_app(cubit, observer));
      await _openLogin(tester);
      await _pumpFrames(tester);

      expect(downloads, 1);
      expect(find.text('验证码未加载 · 点此刷新'), findsOneWidget);
      expect(_siteLoginButton, findsOneWidget);
      expect(tester.widget<FilledButton>(_loginButton).onPressed, isNull);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('cf_challenge'), findsNothing);
      expect(observer.pops, 0);

      await tester.tap(find.text('验证码未加载 · 点此刷新'));
      await _pumpFrames(tester);
      expect(downloads, 2);
      expect(find.text('验证码未加载 · 点此刷新'), findsOneWidget);
      expect(_siteLoginButton, findsOneWidget);
      expect(tester.widget<FilledButton>(_loginButton).onPressed, isNull);
      expect(observer.pops, 0);
      expect(find.textContaining('HTTP 403'), findsOneWidget);
    },
  );

  testWidgets('un-decodable captcha bytes render the inline retry action', (
    tester,
  ) async {
    final cubit = AuthCubit(
      login:
          ({required username, required password, required checkcode}) async {},
      preLoginState: () async => false,
      downloadCheckcode: () async => Uint8List.fromList([1, 2, 3, 4]),
    );
    addTearDown(cubit.close);
    await cubit.init();
    final observer = _RouteObserver();
    await tester.pumpWidget(_app(cubit, observer));
    await _openLogin(tester);
    await _pumpFrames(tester, count: 12);

    expect(find.text('验证码未加载 · 点此刷新'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
    expect(observer.pops, 0);
  });

  testWidgets(
    'captcha loading disables submit, a valid local PNG submits once, and success pops once',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final captcha = Completer<Uint8List>();
      final loginResult = Completer<void>();
      var logins = 0;
      final cubit = AuthCubit(
        login: ({required username, required password, required checkcode}) {
          logins++;
          return loginResult.future;
        },
        preLoginState: () async => false,
        downloadCheckcode: () => captcha.future,
      );
      addTearDown(cubit.close);
      await cubit.init();
      final observer = _RouteObserver();
      await tester.pumpWidget(_app(cubit, observer));
      await _openLogin(tester);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'fixture-user');
      await tester.enterText(fields.at(1), 'fixture-password');
      await tester.enterText(fields.at(2), '1234');
      expect(tester.widget<FilledButton>(_loginButton).onPressed, isNull);
      await tester.tap(_loginButton);
      await tester.pump();
      expect(logins, 0);

      captcha.complete(_validPng);
      await _pumpFrames(tester, count: 8);
      expect(tester.widget<FilledButton>(_loginButton).onPressed, isNotNull);
      expect(find.text('验证码未加载 · 点此刷新'), findsNothing);

      final captchaImages =
          tester
              .widgetList<Image>(find.byType(Image))
              .where((image) => image.image is MemoryImage)
              .toList();
      expect(captchaImages, hasLength(1));
      expect(captchaImages.single.width, 200);
      expect(captchaImages.single.height, 50);

      final usernameSize = tester.getSize(fields.at(0));
      final passwordSize = tester.getSize(fields.at(1));
      expect(usernameSize.width, greaterThan(340));
      expect(passwordSize.width, closeTo(usernameSize.width, 0.1));

      await tester.tap(_loginButton);
      await tester.pump();
      expect(logins, 1);
      expect(tester.widget<FilledButton>(_loginButton).onPressed, isNull);
      await tester.tap(_loginButton);
      await tester.pump();
      expect(logins, 1);
      expect(observer.pops, 0);

      loginResult.complete();
      await _pumpFrames(
        tester,
        count: 12,
        step: const Duration(milliseconds: 40),
      );
      expect(logins, 1);
      expect(observer.pops, 1);
      expect(find.text('Test home'), findsOneWidget);
      expect(find.text('验证码'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
