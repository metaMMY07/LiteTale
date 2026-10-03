import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';

final Uint8List _pngFixture = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  ),
);

Uint8List _newPngFixture() => Uint8List.fromList(_pngFixture);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'copyWith preserves nullable state and clears only requested fields',
    () {
      final captcha = _newPngFixture();
      final state = AuthState(
        status: AuthStatus.error,
        username: 'reader',
        errorMessage: 'login failed',
        checkcode: captcha,
        checkcodeStatus: CheckcodeStatus.success,
        checkcodeErrorMessage: 'captcha warning',
      );

      final preserved = state.copyWith(status: AuthStatus.loading);
      expect(preserved.username, 'reader');
      expect(preserved.errorMessage, 'login failed');
      expect(identical(preserved.checkcode, captcha), isTrue);
      expect(preserved.checkcodeStatus, CheckcodeStatus.success);
      expect(preserved.checkcodeErrorMessage, 'captcha warning');

      final cleared = preserved.copyWith(
        clearUsername: true,
        clearErrorMessage: true,
        clearCheckcode: true,
        clearCheckcodeErrorMessage: true,
      );
      expect(cleared.username, isNull);
      expect(cleared.errorMessage, isNull);
      expect(cleared.checkcode, isNull);
      expect(cleared.checkcodeErrorMessage, isNull);
    },
  );

  test('captcha fixture is a decodable one-pixel PNG', () async {
    final codec = await ui.instantiateImageCodec(_pngFixture);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1);
    expect(frame.image.height, 1);
    frame.image.dispose();
    codec.dispose();
  });

  test('login loading and failure preserve captcha and username', () async {
    final loginResult = Completer<void>();
    final captcha = _newPngFixture();
    final cubit = AuthCubit(
      login:
          ({required username, required password, required checkcode}) =>
              loginResult.future,
      preLoginState: () async => false,
      downloadCheckcode: () async => captcha,
    );
    addTearDown(cubit.close);

    await cubit.loadCheckcode();
    expect(cubit.state.checkcodeStatus, CheckcodeStatus.success);
    expect(identical(cubit.state.checkcode, captcha), isTrue);

    final login = cubit.login('reader', 'password', 'ABCD');
    expect(cubit.state.status, AuthStatus.loading);
    expect(cubit.state.username, 'reader');
    expect(cubit.state.checkcodeStatus, CheckcodeStatus.success);
    expect(identical(cubit.state.checkcode, captcha), isTrue);

    loginResult.completeError(StateError('invalid credentials'));
    await login;
    expect(cubit.state.status, AuthStatus.error);
    expect(cubit.state.username, 'reader');
    expect(cubit.state.errorMessage, contains('invalid credentials'));
    expect(cubit.state.checkcodeErrorMessage, isNull);
    expect(cubit.state.checkcodeStatus, CheckcodeStatus.success);
    expect(identical(cubit.state.checkcode, captcha), isTrue);
  });

  test(
    'login and refresh are no-ops while the other operation is pending',
    () async {
      final captchaResult = Completer<Uint8List>();
      final loginResult = Completer<void>();
      var downloadCalls = 0;
      var loginCalls = 0;
      final cubit = AuthCubit(
        login: ({required username, required password, required checkcode}) {
          loginCalls++;
          return loginResult.future;
        },
        preLoginState: () async => false,
        downloadCheckcode: () {
          downloadCalls++;
          return captchaResult.future;
        },
      );
      addTearDown(cubit.close);

      final refresh = cubit.loadCheckcode();
      expect(cubit.state.checkcodeStatus, CheckcodeStatus.loading);
      await cubit.login('reader', 'password', 'ABCD');
      expect(loginCalls, 0);

      captchaResult.complete(_newPngFixture());
      await refresh;
      expect(cubit.state.checkcodeStatus, CheckcodeStatus.success);

      final firstLogin = cubit.login('reader', 'password', 'ABCD');
      await cubit.login('reader', 'password', 'EFGH');
      await cubit.loadCheckcode();
      expect(loginCalls, 1);
      expect(downloadCalls, 1);
      expect(cubit.state.status, AuthStatus.loading);
      expect(cubit.state.checkcodeStatus, CheckcodeStatus.success);

      loginResult.complete();
      await firstLogin;
      expect(cubit.state.status, AuthStatus.authenticated);
    },
  );

  test(
    'only the newest overlapping captcha refresh may update state',
    () async {
      final first = Completer<Uint8List>();
      final second = Completer<Uint8List>();
      var calls = 0;
      final cubit = AuthCubit(
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async => false,
        downloadCheckcode: () {
          calls++;
          return calls == 1 ? first.future : second.future;
        },
      );
      addTearDown(cubit.close);

      final firstRefresh = cubit.loadCheckcode();
      final secondRefresh = cubit.loadCheckcode();
      expect(calls, 2);

      final newestCaptcha = _newPngFixture();
      second.complete(newestCaptcha);
      await secondRefresh;
      expect(identical(cubit.state.checkcode, newestCaptcha), isTrue);

      final staleCaptcha = _newPngFixture();
      first.complete(staleCaptcha);
      await firstRefresh;
      expect(identical(cubit.state.checkcode, newestCaptcha), isTrue);
      expect(cubit.state.checkcodeStatus, CheckcodeStatus.success);
    },
  );

  test('late init cannot overwrite a newer successful login', () async {
    final initResult = Completer<bool>();
    final cubit = AuthCubit(
      login:
          ({required username, required password, required checkcode}) async {},
      preLoginState: () => initResult.future,
      downloadCheckcode: () async => _newPngFixture(),
    );
    addTearDown(cubit.close);

    final init = cubit.init();
    await cubit.login('reader', 'password', 'ABCD');
    expect(cubit.state.status, AuthStatus.authenticated);
    expect(cubit.state.username, 'reader');

    initResult.complete(false);
    await init;
    expect(cubit.state.status, AuthStatus.authenticated);
    expect(cubit.state.username, 'reader');
  });

  test('logout invalidates a pending login result', () async {
    final loginResult = Completer<void>();
    final cubit = AuthCubit(
      login:
          ({required username, required password, required checkcode}) =>
              loginResult.future,
      preLoginState: () async => false,
      downloadCheckcode: () async => _newPngFixture(),
    );
    addTearDown(cubit.close);

    final login = cubit.login('reader', 'password', 'ABCD');
    expect(cubit.state.status, AuthStatus.loading);
    cubit.logout();
    expect(cubit.state.status, AuthStatus.unauthenticated);
    expect(cubit.state.username, isNull);

    loginResult.complete();
    await login;
    expect(cubit.state.status, AuthStatus.unauthenticated);
    expect(cubit.state.username, isNull);
  });

  test('init invalidates a pending captcha result', () async {
    final captchaResult = Completer<Uint8List>();
    final cubit = AuthCubit(
      login:
          ({required username, required password, required checkcode}) async {},
      preLoginState: () async => false,
      downloadCheckcode: () => captchaResult.future,
    );
    addTearDown(cubit.close);

    final refresh = cubit.loadCheckcode();
    expect(cubit.state.checkcodeStatus, CheckcodeStatus.loading);
    await cubit.init();
    expect(cubit.state.status, AuthStatus.unauthenticated);
    expect(cubit.state.checkcodeStatus, CheckcodeStatus.initial);

    captchaResult.complete(_newPngFixture());
    await refresh;
    expect(cubit.state.checkcode, isNull);
    expect(cubit.state.checkcodeStatus, CheckcodeStatus.initial);
  });

  test(
    'closing prevents pending login and captcha results from emitting',
    () async {
      final captchaResult = Completer<Uint8List>();
      final loginResult = Completer<void>();
      final captchaCubit = AuthCubit(
        login:
            ({required username, required password, required checkcode}) =>
                loginResult.future,
        preLoginState: () async => false,
        downloadCheckcode: () => captchaResult.future,
      );
      final captchaLoad = captchaCubit.loadCheckcode();
      final captchaStateAtClose = captchaCubit.state;
      await captchaCubit.close();
      captchaResult.complete(_newPngFixture());
      await captchaLoad;
      expect(captchaCubit.state, captchaStateAtClose);

      final loginCubit = AuthCubit(
        login:
            ({required username, required password, required checkcode}) =>
                loginResult.future,
        preLoginState: () async => false,
        downloadCheckcode: () async => _newPngFixture(),
      );
      final login = loginCubit.login('reader', 'password', 'ABCD');
      final loginStateAtClose = loginCubit.state;
      await loginCubit.close();
      loginResult.complete();
      await login;
      expect(loginCubit.state, loginStateAtClose);
    },
  );

  test(
    'captcha errors keep safe site-verification and expiry categories',
    () async {
      Future<String?> classify(String failure) async {
        final cubit = AuthCubit(
          login:
              ({
                required username,
                required password,
                required checkcode,
              }) async {},
          preLoginState: () async => false,
          downloadCheckcode: () async => throw StateError(failure),
        );
        await cubit.loadCheckcode();
        final message = cubit.state.checkcodeErrorMessage;
        await cubit.close();
        return message;
      }

      final forbidden = await classify('HTTP 403 Forbidden');
      expect(forbidden, contains('HTTP 403'));
      expect(forbidden, contains('站点验证'));
      expect(forbidden, isNot(contains('Forbidden')));

      final challenge = await classify('cf_challenge');
      expect(challenge, contains('站点验证'));

      final browserVerification = await classify('浏览器提示：站点验证尚未完成');
      expect(browserVerification, contains('站点验证'));
      expect(browserVerification, isNot(contains('HTTP 403')));
      final absentImage = await classify('文库8没有返回可用验证码，请刷新或打开站点登录。');
      expect(absentImage, contains('无法获取验证码'));
      expect(absentImage, isNot(contains('HTTP 403')));
      expect(browserVerification, isNot(contains('浏览器提示')));

      final expired = await classify('浏览器提示：验证码已过期');
      expect(expired, contains('验证码已过期'));
      expect(expired, contains('刷新'));
      expect(expired, isNot(contains('浏览器提示')));
    },
  );

  test(
    'init lookup failure settles signed out without exposing the exception',
    () async {
      final cubit = AuthCubit(
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async {
          throw StateError('sensitive database detail');
        },
        downloadCheckcode: () async => _newPngFixture(),
      );
      addTearDown(cubit.close);

      await expectLater(cubit.init(), completes);
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(cubit.state.errorMessage, isNull);
      expect(cubit.state.checkcodeErrorMessage, isNull);
    },
  );
  test(
    'captcha errors stay separate and use safe actionable messages',
    () async {
      final cubit = AuthCubit(
        login: ({
          required username,
          required password,
          required checkcode,
        }) async {
          throw StateError('invalid credentials');
        },
        preLoginState: () async => false,
        downloadCheckcode: () async {
          throw StateError(
            'captcha_fetch_failed status=403 content_type=text/html',
          );
        },
      );
      addTearDown(cubit.close);

      await cubit.login('reader', 'password', 'ABCD');
      final loginError = cubit.state.errorMessage;
      await cubit.loadCheckcode();

      expect(cubit.state.status, AuthStatus.error);
      expect(cubit.state.errorMessage, loginError);
      expect(cubit.state.checkcodeErrorMessage, contains('HTTP 403'));
      expect(cubit.state.checkcodeErrorMessage, contains('站点完成验证'));
      expect(cubit.state.checkcodeStatus, CheckcodeStatus.error);

      final networkCubit = AuthCubit(
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async => false,
        downloadCheckcode: () async {
          throw Exception('connection timed out');
        },
      );
      addTearDown(networkCubit.close);

      await networkCubit.loadCheckcode();
      expect(networkCubit.state.errorMessage, isNull);
      expect(networkCubit.state.checkcodeErrorMessage, contains('网络连接失败'));
      expect(networkCubit.state.checkcodeErrorMessage, contains('重试'));
    },
  );
}
