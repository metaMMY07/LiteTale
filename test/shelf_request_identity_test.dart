import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/services/shelf_api_error.dart';
import 'package:wild/services/shelf_device_id.dart';
import 'package:wild/sources/shelf_session.dart';

import 'shelf_transport_stability_test.dart' as transport;

const deviceKey = 'litetale.lns.deviceId';
const refreshKey = 'litetale.lns.refresh';
const fixtureId = '01234567-89ab-4cde-8fab-0123456789ab';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding is needed for the storage channel; use real loopback sockets
  // instead of its default HTTP-400 stub for the transport assertions below.
  HttpOverrides.global = null;

  test(
    'default HTTP and WebSocket clients share one persisted ID across accounts and retries',
    () async {
      final values = <String, String>{};
      var deviceReads = 0, deviceWrites = 0, attempts = 0;
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        final key = args['key'] as String;
        switch (call.method) {
          case 'read':
            if (key == deviceKey) deviceReads++;
            return values[key];
          case 'write':
            if (key == deviceKey) deviceWrites++;
            values[key] = args['value'] as String;
            return null;
          case 'delete':
            values.remove(key);
            return null;
          default:
            throw StateError('Unexpected storage method');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final ids = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        ids.add(request.headers.value('x-id'));
        if (++attempts == 1) {
          request.response.statusCode = 502;
          await request.response.close();
        } else {
          await transport.reply(request);
        }
      });
      final target = Uri.parse('ws://127.0.0.1:${server.port}/hub/api');
      final first = LightNovelShelfService(
        testHub: target,
        retryDelay: Duration.zero,
      );
      final second = LightNovelShelfService(
        testHub: target,
        retryDelay: Duration.zero,
      );
      final session = ShelfSession(
        createClient:
            () => MockClient((request) async {
              ids.add(request.headers['x-id']);
              final login = request.url.path.endsWith('/login');
              return http.Response(
                jsonEncode({
                  'success': true,
                  'response':
                      login
                          ? {
                            'token': 'fixture-access',
                            'refreshToken': 'fixture-refresh',
                          }
                          : 'fixture-renewed',
                }),
                200,
              );
            }),
      );
      await Future.wait([
        first.invoke('GetBookInfo', {'Id': 1}),
        second.invoke('GetBookInfo', {'Id': 2}),
        session.login('fixture@example.com', 'fixture'),
      ]);
      final saved = values[deviceKey];
      expect(saved, isNotNull);
      expect(ids.toSet(), {saved});
      expect(attempts, 3);
      expect(deviceReads, 1);
      expect(deviceWrites, 1);
      await session.logout();
      expect(values[deviceKey], saved);
      expect(values.containsKey(refreshKey), isFalse);
      await session.login('other@example.com', 'fixture');
      await session.token(refresh: true);
      final restartedIdentity = ShelfDeviceId();
      final restartedClient = LightNovelShelfService(
        testHub: target,
        deviceId: restartedIdentity.value,
      );
      await restartedClient.invoke('GetBookInfo', {'Id': 3});
      expect(ids.toSet(), {saved});
      expect(deviceReads, 2);
      expect(deviceWrites, 1);
    },
  );

  test(
    'expired socket attempts cannot connect after ID initialization finishes late',
    () async {
      final pendingId = Completer<String>();
      var connections = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        connections++;
        await request.response.close();
      });
      final client = LightNovelShelfService(
        testHub: Uri.parse('ws://127.0.0.1:${server.port}/hub/api'),
        deviceId: () => pendingId.future,
        attemptTimeout: const Duration(milliseconds: 30),
        retryDelay: Duration.zero,
      );
      await expectLater(
        client.invoke('GetBookInfo', {'Id': 1}),
        throwsA(isA<ShelfApiException>()),
      );
      pendingId.complete(fixtureId);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connections, 0);
    },
  );

  test('logout while identity is loading prevents a late login POST', () async {
    final pendingId = Completer<String>();
    var posts = 0;
    final session = ShelfSession(
      deviceId: () => pendingId.future,
      createClient:
          () => MockClient((_) async {
            posts++;
            return http.Response('', 500);
          }),
      readCredential: () async => null,
      writeCredential: (_) async {},
      deleteCredential: () async {},
    );
    final login = session.login('fixture@example.com', 'fixture');
    await session.logout();
    pendingId.complete(fixtureId);
    await expectLater(login, throwsA(isA<ShelfApiException>()));
    expect(posts, 0);
  });

  test(
    'identity wait is within the HTTP deadline and cannot submit a late POST',
    () async {
      final pendingId = Completer<String>();
      var posts = 0;
      final session = ShelfSession(
        deviceId: () => pendingId.future,
        createClient:
            () => MockClient((_) async {
              posts++;
              return http.Response('', 500);
            }),
        readCredential: () async => null,
        writeCredential: (_) async {},
        deleteCredential: () async {},
        requestTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        session.login('fixture@example.com', 'fixture'),
        throwsA(isA<ShelfApiException>()),
      );
      pendingId.complete(fixtureId);
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
    },
  );
}
