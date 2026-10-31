import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/huanmeng_http_transport.dart';
import 'package:wild/sources/huanmeng_source.dart';
import 'package:wild/sources/rules/rule_source_engine.dart';
import 'package:wild/services/read_request.dart';

Uri target(String id) =>
    Uri.parse('https://www.huanmengacg.com/index.php/bookapi/detail?id=$id');
RuleSourceHttpResponse response(
  int status, {
  String body = '{"code":1,"data":{}}',
  Map<String, String> headers = const {},
}) => RuleSourceHttpResponse(
  statusCode: status,
  headers: headers,
  bytes: Uint8List.fromList(utf8.encode(body)),
);

class Transport implements RuleSourceTransport {
  Transport(this.read);
  final Future<RuleSourceHttpResponse> Function(Uri) read;
  int calls = 0;
  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) {
    calls++;
    return read(uri);
  }
}

void main() {
  test(
    'active cancellation releases an abortable read for the newest chapter',
    () async {
      final started = Completer<void>();
      final paths = <String>[];
      var aborted = 0;
      final raw = Transport((uri) {
        final id = uri.queryParameters['id']!;
        paths.add(id);
        if (id != '1') return Future.value(response(200));
        final reading = Completer<RuleSourceHttpResponse>();
        ReadRequest.current!.onCancel((error) {
          aborted++;
          reading.completeError(error);
        });
        started.complete();
        return reading.future;
      });
      final transport = HuanmengHttpTransport(
        transport: raw,
        spacing: Duration.zero,
      );
      final request = ReadRequest();
      final abandoned = ReadRequest.run(
        request,
        () => transport.read(target('1')),
      );
      final checked = expectLater(abandoned, throwsA(isA<ReadCancelled>()));
      await started.future;
      final latest = transport.read(target('2'));
      request.cancel();
      await checked;
      await latest;
      expect(paths, ['1', '2']);
      expect(aborted, 1);
    },
  );

  test(
    'received 429 still cools down the queue after its caller leaves',
    () async {
      final started = Completer<void>();
      final reading = Completer<RuleSourceHttpResponse>();
      final raw = Transport((_) {
        started.complete();
        return reading.future;
      });
      final transport = HuanmengHttpTransport(
        transport: raw,
        spacing: Duration.zero,
      );
      final request = ReadRequest();
      final abandoned = ReadRequest.run(
        request,
        () => transport.read(target('1')),
      );
      final checked = expectLater(abandoned, throwsA(isA<ReadCancelled>()));
      await started.future;
      final next = transport.read(target('2'));
      final cooledDown = expectLater(
        next,
        throwsA(isA<HuanmengSourceException>()),
      );
      request.cancel();
      await checked;
      reading.complete(response(429, headers: {'retry-after': '120'}));
      await cooledDown;
      expect(raw.calls, 1);
    },
  );

  test(
    'abandoned queued reads are removed before the newest read runs',
    () async {
      final gate = Completer<RuleSourceHttpResponse>();
      final paths = <String>[];
      final raw = Transport((uri) {
        final id = uri.queryParameters['id']!;
        paths.add(id);
        return id == '1' ? gate.future : Future.value(response(200));
      });
      final transport = HuanmengHttpTransport(
        transport: raw,
        spacing: Duration.zero,
      );
      final active = transport.read(target('1'));
      final request = ReadRequest();
      final abandoned = ReadRequest.run(
        request,
        () => transport.read(target('2')),
      );
      final checked = expectLater(abandoned, throwsA(isA<ReadCancelled>()));
      final latest = transport.read(target('3'));
      await Future<void>.delayed(Duration.zero);
      request.cancel();
      await checked;
      gate.complete(response(200));
      await active;
      await latest;
      expect(paths, ['1', '3']);
    },
  );

  test('one shared subscriber leaving never aborts the other', () async {
    final gate = Completer<RuleSourceHttpResponse>();
    var physicalCancels = 0;
    final raw = Transport((_) {
      ReadRequest.current!.onCancel((_) => physicalCancels++);
      return gate.future;
    });
    final transport = HuanmengHttpTransport(
      transport: raw,
      spacing: Duration.zero,
    );
    final request = ReadRequest();
    final first = ReadRequest.run(request, () => transport.read(target('1')));
    final second = transport.read(target('1'));
    final checked = expectLater(first, throwsA(isA<ReadCancelled>()));
    await Future<void>.delayed(Duration.zero);
    request.cancel();
    await checked;
    gate.complete(response(200));
    await second;
    expect(raw.calls, 1);
    expect(physicalCancels, 0);
  });
  test(
    'duplicate reads share one request and distinct reads stay serial',
    () async {
      final first = Completer<RuleSourceHttpResponse>();
      final raw = Transport(
        (uri) async =>
            uri.queryParameters['id'] == '1' ? first.future : response(200),
      );
      final http = HuanmengHttpTransport(
        transport: raw,
        spacing: Duration.zero,
      );
      final a = http.read(target('1')),
          b = http.read(target('1')),
          c = http.read(target('2'));
      await Future<void>.delayed(Duration.zero);
      expect(raw.calls, 1);
      first.complete(response(200));
      expect(await Future.wait([a, b, c]), hasLength(3));
      expect(raw.calls, 2);
    },
  );

  test('expired queued requests cannot start late network work', () async {
    final pending = Completer<RuleSourceHttpResponse>();
    final raw = Transport((_) => pending.future);
    final http = HuanmengHttpTransport(
      transport: raw,
      spacing: Duration.zero,
      requestBudget: const Duration(milliseconds: 40),
    );
    final wait = Future.wait([http.read(target('1')), http.read(target('2'))]);
    await expectLater(wait, throwsA(isA<TimeoutException>()));
    pending.complete(response(200));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(raw.calls, 1);
  });

  test('429 stops queued and new requests without another channel', () async {
    final raw = Transport(
      (_) async => response(429, headers: {'retry-after': '120'}),
    );
    final http = HuanmengHttpTransport(transport: raw, spacing: Duration.zero);
    await expectLater(
      http.read(target('1')),
      throwsA(isA<HuanmengSourceException>()),
    );
    await expectLater(
      http.read(target('2')),
      throwsA(isA<HuanmengSourceException>()),
    );
    expect(raw.calls, 1);
  });

  test(
    'foreign origins and non-API routes never reach the transport',
    () async {
      final raw = Transport((_) async => response(200));
      final http = HuanmengHttpTransport(transport: raw);
      for (final uri in [
        Uri.parse('https://example.com/index.php/bookapi/detail'),
        Uri.parse('https://www.huanmengacg.com/index.php/bookapi/other'),
        Uri.parse('http://www.huanmengacg.com/index.php/bookapi/search'),
      ]) {
        await expectLater(http.read(uri), throwsFormatException);
      }
      expect(raw.calls, 0);
    },
  );

  test(
    'HTML challenge and HTTP failures never become empty JSON success',
    () async {
      for (final result in [
        response(403),
        response(200, body: '<title>Just a moment...</title>'),
      ]) {
        final raw = Transport((_) async => result);
        final http = HuanmengHttpTransport(transport: raw);
        await expectLater(
          http.read(target('1')),
          throwsA(isA<HuanmengSourceException>()),
        );
        expect(raw.calls, 1);
      }
    },
  );
}
