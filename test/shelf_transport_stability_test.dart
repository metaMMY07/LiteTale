import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/services/shelf_api_error.dart';
import 'package:wild/sources/light_novel_shelf_source.dart';
import 'package:wild/sources/shelf_session.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/services/read_request.dart';

const rs = '\u001e';

Future<({HttpServer server, LightNovelShelfService service})> hub(
  Future<void> Function(HttpRequest request, int attempt) handle, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var calls = 0;
  server.listen((request) => unawaited(handle(request, ++calls)));
  addTearDown(() => server.close(force: true));
  return (
    server: server,
    service: LightNovelShelfService(
      testHub: Uri.parse('ws://127.0.0.1:${server.port}/hub/api'),
      deviceId: () async => '00000000-0000-4000-8000-000000000001',
      attemptTimeout: timeout,
      retryDelay: Duration.zero,
    ),
  );
}

Future<void> reply(
  HttpRequest request, {
  bool split = false,
  Map<String, Object?>? envelope,
}) async {
  final socket = await WebSocketTransformer.upgrade(request);
  addTearDown(() async {
    try {
      await socket.close().timeout(const Duration(milliseconds: 100));
    } catch (_) {}
  });
  socket.listen((raw) {
    final message = jsonDecode((raw as String).split(rs).first) as Map;
    if (message['protocol'] != null) {
      if (split) {
        socket.add('{');
        socket.add('}$rs{"type":6}$rs');
      } else {
        socket.add('{}$rs');
      }
    } else if (message['type'] == 1) {
      final text = jsonEncode({
        'type': 3,
        'invocationId': message['invocationId'],
        'result':
            envelope ??
            {
              'Success': true,
              'Response': {'Title': '中文完整内容'},
            },
      });
      if (split) {
        socket.add(text.substring(0, 30));
        socket.add('${text.substring(30)}$rs');
      } else {
        socket.add('$text$rs');
      }
    }
  });
}

void main() {
  for (final status in [401, 500]) {
    test(
      'comment envelope $status preserves the account and scopes token renewal',
      () async {
        var refreshes = 0, deletes = 0, connections = 0;
        final session = ShelfSession(
          deviceId: () async => '00000000-0000-4000-8000-000000000001',
          createClient:
              () => MockClient((_) async {
                refreshes++;
                return http.Response(
                  jsonEncode({
                    'success': true,
                    'response': 'fixture-access-$refreshes',
                  }),
                  200,
                );
              }),
          readCredential: () async => 'fixture-refresh',
          writeCredential: (_) async {},
          deleteCredential: () async {
            deletes++;
          },
        );
        final f = await hub((request, n) async {
          connections = n;
          await reply(
            request,
            envelope:
                status == 500 || n == 1
                    ? {'success': false, 'status': status}
                    : {
                      'success': true,
                      'response': {
                        'Page': 1,
                        'TotalPages': 0,
                        'Users': <String, Object?>{},
                        'Commentaries': <String, Object?>{},
                        'Data': <Object?>[],
                      },
                    },
          );
        });
        final source = LightNovelShelfSource(
          session: session,
          service: f.service,
        );
        if (status == 500) {
          await expectLater(
            source.comments('lns:1'),
            throwsA(
              isA<ShelfApiException>().having((e) => e.status, 'status', 500),
            ),
          );
        } else {
          expect((await source.comments('lns:1')).items, isEmpty);
        }
        expect(connections, 2);
        expect(refreshes, status == 401 ? 2 : 1);
        expect(deletes, 0);
        expect(session.signedIn.value, true);
      },
    );
  }

  test(
    'comments retry one transient server error inside a SignalR envelope',
    () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        await reply(
          request,
          envelope:
              n == 1
                  ? {'Success': false, 'Status': 500}
                  : {
                    'Success': true,
                    'Response': {'Page': 1, 'Data': []},
                  },
        );
      });
      final value = await f.service.invoke('GetComments', {
        'Type': 'Book',
        'Id': 1,
        'Page': 1,
        'Size': 10,
      });
      expect((value as Map)['Response'], {'Page': 1, 'Data': []});
      expect(attempts, 2);
    },
  );

  test('persistent comment envelope errors stop after one retry', () async {
    var attempts = 0;
    final f = await hub((request, n) async {
      attempts = n;
      await reply(request, envelope: {'success': false, 'status': 500});
    });
    await expectLater(
      f.service.invoke('GetComments', {
        'Type': 'Book',
        'Id': 1,
        'Page': 1,
        'Size': 10,
      }),
      throwsA(isA<ShelfApiException>().having((e) => e.status, 'status', 500)),
    );
    expect(attempts, 2);
  });

  for (final status in [401, 403, 429]) {
    test('comment envelope $status is not retried by the transport', () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        await reply(request, envelope: {'Success': false, 'Status': status});
      });
      await expectLater(
        f.service.invoke('GetComments', {
          'Type': 'Book',
          'Id': 1,
          'Page': 1,
          'Size': 10,
        }),
        throwsA(
          isA<ShelfApiException>().having((e) => e.status, 'status', status),
        ),
      );
      expect(attempts, 1);
    });
  }

  test(
    'leaving comments during server-error backoff prevents a late retry',
    () async {
      var attempts = 0;
      final received = Completer<void>();
      final f = await hub((request, n) async {
        attempts = n;
        await reply(request, envelope: {'Success': false, 'Status': 500});
        if (!received.isCompleted) received.complete();
      });
      final service = LightNovelShelfService(
        testHub: Uri.parse('ws://127.0.0.1:${f.server.port}/hub/api'),
        deviceId: () async => '00000000-0000-4000-8000-000000000001',
        retryDelay: const Duration(milliseconds: 100),
      );
      final scope = ReadRequest();
      final pending = ReadRequest.run(
        scope,
        () => service.invoke('GetComments', {
          'Type': 'Book',
          'Id': 1,
          'Page': 1,
          'Size': 10,
        }),
      );
      final checked = expectLater(pending, throwsA(isA<ReadCancelled>()));
      await received.future;
      scope.cancel();
      await checked;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(attempts, 1);
    },
  );

  test(
    'cancelled comments close a stalled socket without replaying it',
    () async {
      var attempts = 0;
      final started = Completer<void>();
      final closed = Completer<void>();
      final f = await hub((request, n) async {
        attempts = n;
        if (n > 1) {
          await reply(request);
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        addTearDown(() => socket.close());
        socket.listen(
          (raw) {
            final message = jsonDecode((raw as String).split(rs).first) as Map;
            if (message['protocol'] != null) {
              socket.add('{}$rs');
            } else if (message['type'] == 1) {
              expect(message['target'], 'GetComments');
              started.complete();
            }
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      final scope = ReadRequest();
      final pending = ReadRequest.run(
        scope,
        () => f.service.invoke('GetComments', {
          'Type': 'Book',
          'Id': 1,
          'Page': 1,
        }),
      );
      final check = expectLater(pending, throwsA(isA<ReadCancelled>()));
      await started.future;
      scope.cancel();
      await check;
      await closed.future.timeout(const Duration(seconds: 2));
      expect(attempts, 1);
      expect(
        await f.service.invoke('GetComments', {
          'Type': 'Book',
          'Id': 1,
          'Page': 1,
        }),
        isA<Map>(),
      );
      expect(attempts, 2);
    },
  );

  test(
    'comments cancelled during device identity lookup never connect late',
    () async {
      var connects = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        connects++;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final identity = Completer<String>();
      final service = LightNovelShelfService(
        testHub: Uri.parse('ws://127.0.0.1:${server.port}/hub/api'),
        deviceId: () => identity.future,
      );
      final scope = ReadRequest();
      final pending = ReadRequest.run(
        scope,
        () =>
            service.invoke('GetComments', {'Type': 'Book', 'Id': 1, 'Page': 1}),
      );
      final check = expectLater(pending, throwsA(isA<ReadCancelled>()));
      scope.cancel();
      await check;
      identity.complete('00000000-0000-4000-8000-000000000001');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connects, 0);
    },
  );

  test(
    'a rejected access token refreshes once and replays the authenticated read',
    () async {
      var refreshes = 0, connections = 0;
      final session = ShelfSession(
        deviceId: () async => '00000000-0000-4000-8000-000000000001',
        createClient:
            () => MockClient((_) async {
              refreshes++;
              return http.Response(
                jsonEncode({'success': true, 'response': 'valid-access'}),
                200,
              );
            }),
        readCredential: () async => 'fixture-refresh',
        writeCredential: (_) async {},
        deleteCredential: () async {},
      );
      final f = await hub((request, n) async {
        connections = n;
        if (n == 1) {
          request.response.statusCode = 401;
          await request.response.close();
          return;
        }
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer valid-access',
        );
        final socket = await WebSocketTransformer.upgrade(request);
        addTearDown(() => socket.close());
        socket.listen((raw) {
          final message = jsonDecode((raw as String).split(rs).first) as Map;
          if (message['protocol'] != null) {
            socket.add('{}$rs');
          } else {
            socket.add(
              '${jsonEncode({
                'type': 3,
                'invocationId': message['invocationId'],
                'result': {
                  'success': true,
                  'response': {
                    'Book': {'Id': 1, 'Title': '重连书籍', 'Chapter': []},
                  },
                },
              })}$rs',
            );
          }
        });
      });
      final source = LightNovelShelfSource(
        session: session,
        service: f.service,
      );
      expect((await source.detail('lns:1')).info.title, '重连书籍');
      expect(connections, 2);
      expect(refreshes, 2);
    },
  );

  test(
    'split SignalR records and coalesced ping preserve the complete result',
    () async {
      final f = await hub((request, _) => reply(request, split: true));
      final value = await f.service.invoke('GetBookInfo', {'Id': 1});
      expect((value as Map)['Response']['Title'], '中文完整内容');
    },
  );

  test(
    'one reconnect recovers a transient 502, without retrying indefinitely',
    () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        if (n == 1) {
          request.response.statusCode = 502;
          await request.response.close();
        } else {
          await reply(request);
        }
      });
      expect(await f.service.invoke('GetBookList', {'Page': 1}), isA<Map>());
      expect(attempts, 2);
    },
  );

  test('persistent 502 has a finite, safe service error', () async {
    var attempts = 0;
    final f = await hub((request, n) async {
      attempts = n;
      request.response.statusCode = 502;
      await request.response.close();
    });
    await expectLater(
      f.service.invoke('GetNovelContent', {
        'Id': 1,
      }, token: 'fixture-private-token'),
      throwsA(
        isA<ShelfApiException>()
            .having((e) => e.status, 'status', 502)
            .having(
              (e) => e.toString(),
              'safe text',
              isNot(contains('fixture-private-token')),
            ),
      ),
    );
    expect(attempts, 2);
  });

  for (final status in [401, 403, 429]) {
    test('HTTP $status is not automatically reconnected', () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        request.response.statusCode = status;
        await request.response.close();
      });
      await expectLater(
        f.service.invoke('GetBookInfo', {'Id': 1}),
        throwsA(isA<ShelfApiException>()),
      );
      expect(attempts, 1);
    });
  }

  test(
    'unknown methods cannot be replayed after an ambiguous failure',
    () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        request.response.statusCode = 502;
        await request.response.close();
      });
      await expectLater(
        f.service.invoke('SaveBookShelf', {'Data': []}),
        throwsA(isA<ShelfApiException>()),
      );
      expect(attempts, 1);
    },
  );

  test(
    'identical pending reads share work only within the same account',
    () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        await reply(request);
      });
      final first = f.service.invoke('GetBookInfo', {
        'Id': 1,
      }, token: 'account-a');
      final repeated = f.service.invoke('GetBookInfo', {
        'Id': 1,
      }, token: 'account-a');
      final other = f.service.invoke('GetBookInfo', {
        'Id': 1,
      }, token: 'account-b');
      expect(identical(first, repeated), isTrue);
      await Future.wait([first, repeated, other]);
      expect(attempts, 2);
    },
  );

  test(
    'a stalled handshake is bounded and later requests remain usable',
    () async {
      var attempts = 0;
      final f = await hub((request, n) async {
        attempts = n;
        if (n <= 2) {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((_) {});
          addTearDown(() => socket.close());
        } else {
          await reply(request);
        }
      }, timeout: const Duration(milliseconds: 80));
      final stopwatch = Stopwatch()..start();
      await expectLater(
        f.service.invoke('GetBookList', {'Page': 1}),
        throwsA(isA<ShelfApiException>()),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(attempts, 2);
      expect(await f.service.invoke('GetBookList', {'Page': 1}), isA<Map>());
      expect(attempts, 3);
    },
  );
}
