import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<void> invalidations;

  setUp(() {
    invalidations = StreamController<void>.broadcast(sync: true);
  });

  tearDown(() async {
    await invalidations.close();
  });

  test('a failed pre-login check clears stale authenticated state', () async {
    var preLoginCalls = 0;
    final cubit = AuthCubit(
      sessionInvalidations: invalidations.stream,
      login:
          ({required username, required password, required checkcode}) async {},
      preLoginState: () async {
        preLoginCalls++;
        return false;
      },
      downloadCheckcode: () async => Uint8List(0),
    );
    addTearDown(cubit.close);

    await cubit.login('reader', 'password', '1234');
    expect(cubit.state.status, AuthStatus.authenticated);

    invalidations.add(null);
    await Future<void>.delayed(Duration.zero);

    expect(preLoginCalls, 1);
    expect(cubit.state.status, AuthStatus.unauthenticated);
    expect(cubit.state.username, isNull);
  });

  test(
    'a successful pre-login check preserves the authenticated user',
    () async {
      var preLoginCalls = 0;
      final cubit = AuthCubit(
        sessionInvalidations: invalidations.stream,
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async {
          preLoginCalls++;
          return true;
        },
        downloadCheckcode: () async => Uint8List(0),
      );
      addTearDown(cubit.close);

      await cubit.login('reader', 'password', '1234');
      final authenticatedState = cubit.state;
      invalidations.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(preLoginCalls, 1);
      expect(cubit.state, same(authenticatedState));
      expect(cubit.state.status, AuthStatus.authenticated);
      expect(cubit.state.username, 'reader');
    },
  );

  test(
    'an invalidation arriving during login does not change that login',
    () async {
      final loginResult = Completer<void>();
      var preLoginCalls = 0;
      final cubit = AuthCubit(
        sessionInvalidations: invalidations.stream,
        login:
            ({required username, required password, required checkcode}) =>
                loginResult.future,
        preLoginState: () async {
          preLoginCalls++;
          return false;
        },
        downloadCheckcode: () async => Uint8List(0),
      );
      addTearDown(cubit.close);

      final login = cubit.login('reader', 'password', '1234');
      expect(cubit.state.status, AuthStatus.loading);
      invalidations.add(null);
      expect(preLoginCalls, 0);

      loginResult.complete();
      await login;

      expect(cubit.state.status, AuthStatus.authenticated);
      expect(cubit.state.username, 'reader');
      expect(preLoginCalls, 0);
    },
  );

  test('an older recheck cannot replace a newer invalidation result', () async {
    final firstCheck = Completer<bool>();
    var preLoginCalls = 0;
    final cubit = AuthCubit(
      sessionInvalidations: invalidations.stream,
      login:
          ({required username, required password, required checkcode}) async {},
      preLoginState: () {
        preLoginCalls++;
        return preLoginCalls == 1 ? firstCheck.future : Future.value(true);
      },
      downloadCheckcode: () async => Uint8List(0),
    );
    addTearDown(cubit.close);

    await cubit.login('reader', 'password', '1234');
    invalidations.add(null);
    invalidations.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(preLoginCalls, 2);
    expect(cubit.state.status, AuthStatus.authenticated);

    firstCheck.complete(false);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.status, AuthStatus.authenticated);
    expect(cubit.state.username, 'reader');
  });

  test('close cancels invalidation events before they can emit', () async {
    var preLoginCalls = 0;
    var emissions = 0;
    final cubit = AuthCubit(
      sessionInvalidations: invalidations.stream,
      login:
          ({required username, required password, required checkcode}) async {},
      preLoginState: () async {
        preLoginCalls++;
        return false;
      },
      downloadCheckcode: () async => Uint8List(0),
    );
    final subscription = cubit.stream.listen((_) => emissions++);

    await cubit.close();
    invalidations.add(null);
    await Future<void>.delayed(Duration.zero);

    expect(preLoginCalls, 0);
    expect(emissions, 0);
    await subscription.cancel();
  });
}
