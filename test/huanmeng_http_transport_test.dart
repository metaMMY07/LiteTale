import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/huanmeng_http_transport.dart';
import 'package:wild/sources/huanmeng_source.dart';
import 'package:wild/sources/rules/rule_source_engine.dart';

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
