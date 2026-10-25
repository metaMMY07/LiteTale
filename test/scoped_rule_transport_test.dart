import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/rules/scoped_rule_transport.dart';

void main() {
  late HttpServer server;
  late Uri base;
  Future<void> Function(HttpRequest) respond = (_) async {};
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((request) async {
      await respond(request);
    });
  });
  tearDown(() async {
    await server.close(force: true);
  });
  Future<dynamic> get(
    ScopedRuleSourceTransport transport,
    String path, {
    int maxBytes = 8192,
    Duration timeout = const Duration(seconds: 2),
  }) => transport.get(base.resolve(path), timeout: timeout, maxBytes: maxBytes);

  test(
    'source sessions send only matching cookies and the declared static UA',
    () async {
      final received = <String, Map<String, String>>{};
      respond = (request) async {
        received[request.uri.path] = {
          for (final cookie in request.cookies) cookie.name: cookie.value,
        };
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          'LiteTale fixture UA',
        );
        if (request.uri.path == '/seed') {
          request.response.cookies.addAll([
            Cookie('session', 'one')..path = '/',
            Cookie('chapter', 'two')..path = '/book',
            Cookie('other', 'no')..domain = 'elsewhere.example',
            Cookie('secret', 'no')..secure = true,
            Cookie('expired', 'no')..maxAge = 0,
          ]);
        }
        request.response.write('fixture');
        await request.response.close();
      };
      final session = ScopedRuleSourceTransport(
        origin: base,
        userAgent: 'LiteTale fixture UA',
        cookiesEnabled: true,
      );
      await get(session, '/seed');
      await get(session, '/book/one');
      expect(received['/book/one'], {'session': 'one', 'chapter': 'two'});
      await get(session, '/bookish');
      expect(received['/bookish'], {'session': 'one'});
      final isolated = ScopedRuleSourceTransport(
        origin: base,
        userAgent: 'LiteTale fixture UA',
        cookiesEnabled: true,
      );
      await get(isolated, '/new');
      expect(received['/new'], isEmpty);
      await expectLater(
        session.get(
          Uri.parse('https://elsewhere.example/book'),
          timeout: const Duration(seconds: 1),
          maxBytes: 10,
        ),
        throwsFormatException,
      );
    },
  );

  test('cookies are opt in and explicit deletions are honored', () async {
    var calls = 0;
    respond = (request) async {
      calls++;
      if (calls < 3) {
        request.response.cookies.add(Cookie('session', 'one')..path = '/');
      } else if (calls == 3) {
        expect(request.cookies.single.value, 'one');
        request.response.cookies.add(
          Cookie('session', '')
            ..path = '/'
            ..maxAge = 0,
        );
      } else {
        expect(request.cookies, isEmpty);
      }
      request.response.write('fixture');
      await request.response.close();
    };
    final disabled = ScopedRuleSourceTransport(origin: base);
    await get(disabled, '/');
    final enabled = ScopedRuleSourceTransport(
      origin: base,
      cookiesEnabled: true,
    );
    await get(enabled, '/');
    await get(enabled, '/');
    await get(enabled, '/');
  });

  test('429 respects Retry-After without retries or redirects', () async {
    var requests = 0;
    respond = (request) async {
      requests++;
      request.response.statusCode = 429;
      request.response.headers.set(HttpHeaders.retryAfterHeader, '60');
      await request.response.close();
    };
    final session = ScopedRuleSourceTransport(origin: base);
    expect((await get(session, '/')).statusCode, 429);
    await expectLater(get(session, '/'), throwsStateError);
    expect(requests, 1);
  });

  test(
    'bounded responses fail and redirects are returned for engine validation',
    () async {
      var calls = 0;
      respond = (request) async {
        calls++;
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set(HttpHeaders.locationHeader, '/target');
        } else {
          request.response.write('too many bytes for the limit');
        }
        await request.response.close();
      };
      final session = ScopedRuleSourceTransport(origin: base);
      await expectLater(
        get(session, '/large', maxBytes: 3),
        throwsFormatException,
      );
      expect((await get(session, '/redirect')).statusCode, 302);
      expect(calls, 2);
    },
  );

  test('deadline closes a server that never completes its response', () async {
    respond = (request) async {
      /* Deliberately no response. */
    };
    final session = ScopedRuleSourceTransport(origin: base);
    await expectLater(
      get(session, '/', timeout: const Duration(milliseconds: 60)),
      throwsA(isA<TimeoutException>()),
    );
  });
}
