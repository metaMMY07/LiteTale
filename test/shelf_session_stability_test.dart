import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/services/shelf_api_error.dart';
import 'package:wild/sources/shelf_session.dart';

class MemorySession {
  MemorySession(Future<http.Response> Function(http.Request) handle) {
    session = ShelfSession(
      createClient:
          () => MockClient((request) {
            calls++;
            return handle(request);
          }),
      readCredential: () async => credential,
      writeCredential: (value) async {
        credential = value;
      },
      deleteCredential: () async {
        deletes++;
        credential = null;
      },
      requestTimeout: const Duration(milliseconds: 100),
    );
  }
  late final ShelfSession session;
  String? credential = 'fixture-refresh';
  int calls = 0, deletes = 0;
}

http.Response access(String value) =>
    http.Response(jsonEncode({'success': true, 'response': value}), 200);

void main() {
  test('replacement login saves after the queued logout deletion', () async {
    final f = MemorySession(
      (_) async => http.Response(
        jsonEncode({
          'success': true,
          'response': {'token': 'new-access', 'refreshToken': 'new-refresh'},
        }),
        200,
      ),
    );
    final logout = f.session.logout();
    final login = f.session.login('fixture@example.com', 'fixture');
    await Future.wait([logout, login]);
    expect(f.credential, 'new-refresh');
    expect(f.session.signedIn.value, isTrue);
    expect(await f.session.token(), 'new-access');
  });

  test('failed replacement login cannot cancel an explicit logout', () async {
    final f = MemorySession((_) async => http.Response('', 502));
    await f.session.load();
    final logout = f.session.logout();
    final failedLogin = expectLater(
      f.session.login('fixture@example.com', 'fixture'),
      throwsA(isA<ShelfApiException>()),
    );
    await Future.wait([logout, failedLogin]);
    await f.session.load();
    expect(f.credential, isNull);
    expect(f.session.signedIn.value, isFalse);
  });

  test('502 preserves saved account and reports a service failure', () async {
    final f = MemorySession((_) async => http.Response('Bad gateway', 502));
    await f.session.load();
    await expectLater(
      f.session.token(),
      throwsA(isA<ShelfApiException>().having((e) => e.status, 'status', 502)),
    );
    expect(f.session.signedIn.value, isTrue);
    expect(f.credential, 'fixture-refresh');
    expect(f.deletes, 0);
    expect(f.calls, 1);
  });

  for (final status in [401, 404]) {
    test(
      'explicit refresh HTTP $status invalidates only its credential',
      () async {
        final f = MemorySession((_) async => http.Response('', status));
        await f.session.load();
        await expectLater(
          f.session.token(),
          throwsA(isA<ShelfSignInRequired>()),
        );
        expect(f.credential, isNull);
        expect(f.deletes, 1);
        expect(f.session.signedIn.value, isFalse);
      },
    );
  }

  test(
    'business failures without an auth status do not discard a token',
    () async {
      final f = MemorySession(
        (_) async => http.Response('{"success":false,"status":500}', 200),
      );
      await f.session.load();
      await expectLater(f.session.token(), throwsA(isA<ShelfApiException>()));
      expect(f.session.signedIn.value, isTrue);
      expect(f.deletes, 0);
    },
  );

  test(
    'concurrent refreshes share one request and do not revive a logged-out account',
    () async {
      final pending = Completer<http.Response>();
      final f = MemorySession((_) => pending.future);
      await f.session.load();
      final a = f.session.token(), b = f.session.token();
      await Future<void>.delayed(Duration.zero);
      expect(f.calls, 1);
      expect(identical(a, b), isTrue);
      await f.session.logout();
      pending.complete(access('old-access'));
      expect(await a, isNull);
      expect(await b, isNull);
      expect(f.credential, isNull);
      expect(f.session.signedIn.value, isFalse);
    },
  );

  test(
    'late refresh cannot clear a newer login or its pending refresh',
    () async {
      final old = Completer<http.Response>(),
          newer = Completer<http.Response>();
      final f = MemorySession((request) {
        if (request.url.path.endsWith('/login')) {
          return Future.value(
            http.Response(
              jsonEncode({
                'success': true,
                'response': {
                  'token': 'new-access',
                  'refreshToken': 'new-refresh',
                },
              }),
              200,
            ),
          );
        }
        return fPlaceholder(request, old, newer);
      });
      final oldRead = f.session.token();
      await Future<void>.delayed(Duration.zero);
      await f.session.logout();
      await f.session.login('fixture@example.com', 'fixture');
      final newRead = f.session.token(refresh: true);
      await Future<void>.delayed(Duration.zero);
      old.complete(access('old-access'));
      expect(await oldRead, isNull);
      final duplicate = f.session.token(refresh: true);
      expect(identical(newRead, duplicate), isTrue);
      newer.complete(access('newer-access'));
      expect(await newRead, 'newer-access');
      expect(f.credential, 'new-refresh');
      expect(f.session.signedIn.value, isTrue);
      expect(f.calls, 3);
    },
  );

  test(
    'failed login sends credentials once, without automatic retry',
    () async {
      final f = MemorySession((_) async => http.Response('', 502));
      await expectLater(
        f.session.login('fixture@example.com', 'fixture'),
        throwsA(isA<ShelfApiException>()),
      );
      expect(f.calls, 1);
      expect(f.credential, 'fixture-refresh');
    },
  );

  test('logout while login is pending cannot save a late login', () async {
    final pending = Completer<http.Response>();
    final f = MemorySession((_) => pending.future);
    final login = f.session.login('fixture@example.com', 'fixture');
    await f.session.logout();
    pending.complete(
      http.Response(
        '{"success":true,"response":{"token":"late-access","refreshToken":"late-refresh"}}',
        200,
      ),
    );
    await expectLater(login, throwsA(isA<ShelfApiException>()));
    expect(f.credential, isNull);
    expect(f.session.signedIn.value, isFalse);
  });

  test('a timeout remains recoverable without signing out', () async {
    var n = 0;
    final f = MemorySession(
      (_) =>
          ++n == 1
              ? Completer<http.Response>().future
              : Future.value(access('recovered')),
    );
    await f.session.load();
    await expectLater(f.session.token(), throwsA(isA<ShelfApiException>()));
    expect(f.session.signedIn.value, isTrue);
    expect(await f.session.token(), 'recovered');
    expect(f.deletes, 0);
  });
}

Future<http.Response> fPlaceholder(
  http.Request request,
  Completer<http.Response> old,
  Completer<http.Response> newer,
) =>
    jsonDecode(request.body)['token'] == 'fixture-refresh'
        ? old.future
        : newer.future;
