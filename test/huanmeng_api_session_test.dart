import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/huanmeng_api_session.dart';
import 'package:wild/sources/book_source.dart';

// Artificial protocol responses only. These are not successful live API calls.
Uri target([int id = 7]) => Uri.https(
  'www.huanmengacg.com',
  '/index.php/bookapi/detail',
  {'password': 'bookapi', 'id': '$id'},
);
Map<String, dynamic> book([int id = 7]) => {
  'data': {'id': id, 'name': '夹具书籍 $id'},
};
Map<String, dynamic> probe(Uri uri, Map<String, dynamic> envelope) => {
  'url': uri.toString(),
  'ready': true,
  'challenge': false,
  'text': jsonEncode(envelope),
};

class Port implements HuanmengBrowserPort {
  Map<String, dynamic> document = {
    'url': 'https://www.huanmengacg.com/',
    'ready': true,
  };
  Map<String, dynamic> result = {};
  final starts = <DateTime>[];
  final urls = <Uri>[];
  final loads = <String>[];
  bool neverDone = false, wrongToken = false, early429 = false;
  Future<Map<String, dynamic>> Function(Uri)? response;
  void Function(Uri)? onLoad;
  @override
  Future<void> loadUrl(String url) async {
    loads.add(url);
    document = probe(Uri.parse(url), book());
    onLoad?.call(Uri.parse(url));
  }

  @override
  Future<dynamic> executeScript(String script) async {
    if (script == HuanmengApiSession.documentProbe) return jsonEncode(document);
    if (script == HuanmengApiSession.fetchProbe) return jsonEncode(result);
    final match = RegExp(r'const token=(.*), url=(.*);').firstMatch(script)!;
    final token = jsonDecode(match.group(1)!);
    final uri = Uri.parse(jsonDecode(match.group(2)!));
    starts.add(DateTime.now());
    urls.add(uri);
    result = {'token': token, 'done': false};
    if (early429) {
      result.addAll({'status': 429, 'retryAfter': '240'});
    }
    if (!neverDone) {
      unawaited(
        (response?.call(uri) ??
                Future.value({
                  'status': 200,
                  'text': jsonEncode(
                    book(int.parse(uri.queryParameters['id']!)),
                  ),
                }))
            .then((value) {
              result = {
                ...value,
                'token': wrongToken ? 'obsolete' : token,
                'done': true,
              };
            }),
      );
    }
    return true;
  }
}

HuanmengApiSession session() => HuanmengApiSession(
  pollInterval: const Duration(milliseconds: 3),
  challengeGrace: Duration.zero,
  operationTimeout: const Duration(milliseconds: 250),
  requestSpacing: Duration.zero,
);
void main() {
  late int savedRevision;
  setUp(() {
    savedRevision = sourceRevision.value;
  });
  tearDown(() {
    sourceRevision.value = savedRevision;
  });

  test('only fixed HTTPS origin and four API paths are usable', () {
    expect(HuanmengApiSession.isApiTarget(target()), isTrue);
    for (final url in [
      'http://www.huanmengacg.com/index.php/bookapi/detail',
      'https://www.huanmengacg.com:444/index.php/bookapi/detail',
      'https://user@www.huanmengacg.com/index.php/bookapi/detail',
      'https://127.0.0.1/index.php/bookapi/detail',
      'https://www.huanmengacg.com/index.php/bookapi/unknown',
      '${target()}#zhangjie',
      'about:blank',
    ]) {
      expect(
        HuanmengApiSession.isApiTarget(Uri.parse(url)),
        isFalse,
        reason: url,
      );
    }
  });
  test('existing ordinary browser document performs a bounded fetch', () async {
    final s = session(), p = Port();
    addTearDown(s.dispose);
    s.attach(p, 0);
    expect(await s.read(target()), book());
    expect(p.loads, isEmpty);
    expect(p.urls, [target()]);
  });
  test('concurrent identical requests share one API operation', () async {
    final s = session(), p = Port();
    addTearDown(s.dispose);
    s.attach(p, 0);
    final results = await Future.wait([s.read(target()), s.read(target())]);
    expect(results, [book(), book()]);
    expect(p.urls, [target()]);
  });
  test('blank browser first navigates exact API target', () async {
    final s = session(),
        p = Port()..document = {'url': 'about:blank', 'ready': true};
    addTearDown(s.dispose);
    s.attach(p, 0);
    expect(await s.read(target()), book());
    expect(p.loads, [target().toString()]);
    expect(p.urls, isEmpty);
  });
  test('challenge is explicit and stops the old renderer', () async {
    final s = session(),
        p = Port()..document = {'url': 'about:blank', 'ready': true};
    p.onLoad = (uri) {
      p.document = {
        'url': uri.toString(),
        'ready': true,
        'challenge': true,
        'text': 'Just a moment...',
      };
    };
    addTearDown(s.dispose);
    s.attach(p, 0);
    await expectLater(
      s.read(target()),
      throwsA(isA<HuanmengVerificationRequired>()),
    );
    expect(s.rendererGeneration, 1);
    expect(p.loads, hasLength(1));
  });
  test('HTML HTTP 403 requires a normal visible verification', () async {
    final s = session(),
        p =
            Port()
              ..response =
                  (_) async => {'status': 403, 'html': true, 'text': 'Blocked'};
    addTearDown(s.dispose);
    s.attach(p, 0);
    await expectLater(
      s.read(target()),
      throwsA(isA<HuanmengVerificationRequired>()),
    );
    expect(s.rendererGeneration, 1);
  });
  test(
    'JSON HTTP 403 is a server error rather than false verification',
    () async {
      final s = session(),
          p =
              Port()
                ..response =
                    (_) async => {
                      'status': 403,
                      'html': false,
                      'text': '{"message":"forbidden"}',
                    };
      addTearDown(s.dispose);
      s.attach(p, 0);
      await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
    },
  );
  for (final useDate in [false, true]) {
    test(
      '429 respects Retry-After ${useDate ? 'HTTP date' : 'seconds'} and sends no automatic retry',
      () async {
        final until = DateTime.now().add(const Duration(minutes: 4));
        final header = useDate ? HttpDate.format(until) : '240';
        final s = session(),
            p =
                Port()
                  ..response =
                      (_) async => {
                        'status': 429,
                        'retryAfter': header,
                        'text': 'limited',
                      };
        addTearDown(s.dispose);
        s.attach(p, 0);
        await expectLater(
          s.read(target()),
          throwsA(isA<HuanmengApiException>()),
        );
        expect(
          s.retryAt!.difference(DateTime.now()).inSeconds,
          inInclusiveRange(235, 241),
        );
        await expectLater(
          s.read(target(8)),
          throwsA(isA<HuanmengApiException>()),
        );
        expect(p.urls, hasLength(1));
      },
    );
  }
  test(
    'initial navigation rate-limit body has a finite cooldown without available headers',
    () async {
      final s = session(),
          p = Port()..document = {'url': 'about:blank', 'ready': true};
      addTearDown(s.dispose);
      s.attach(p, 0);
      p.onLoad = (uri) {
        p.document = {...probe(uri, book()), 'rateLimited': true};
      };
      await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
      expect(
        s.retryAt!.difference(DateTime.now()).inSeconds,
        inInclusiveRange(55, 60),
      );
      expect(s.rendererGeneration, 1);
    },
  );
  test('malformed Retry-After has a finite fallback', () async {
    final s = session(),
        p =
            Port()
              ..response =
                  (_) async => {
                    'status': 429,
                    'retryAfter': 'invalid',
                    'text': '',
                  };
    addTearDown(s.dispose);
    s.attach(p, 0);
    await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
    expect(
      s.retryAt!.difference(DateTime.now()).inSeconds,
      inInclusiveRange(55, 60),
    );
  });
  test(
    '429 headers establish cooldown before a stalled response body completes',
    () async {
      final s = session(),
          p =
              Port()
                ..neverDone = true
                ..early429 = true;
      addTearDown(s.dispose);
      s.attach(p, 0);
      await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
      expect(s.retryAt!.difference(DateTime.now()).inSeconds, greaterThan(230));
      await expectLater(
        s.read(target(8)),
        throwsA(isA<HuanmengApiException>()),
      );
      expect(p.urls, hasLength(1));
    },
  );
  test(
    'JSON code 429 with null data establishes the actual Retry-After cooldown',
    () async {
      final s = session(),
          p =
              Port()
                ..response =
                    (_) async => {
                      'status': 200,
                      'retryAfter': '240',
                      'text': '{"code":429,"message":"限流","data":null}',
                    };
      addTearDown(s.dispose);
      s.attach(p, 0);
      await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
      expect(s.retryAt!.difference(DateTime.now()).inSeconds, greaterThan(230));
      await expectLater(
        s.read(target(8)),
        throwsA(isA<HuanmengApiException>()),
      );
      expect(p.urls, hasLength(1));
    },
  );
  test(
    'renderer attachment has a finite deadline and stale attachment is ignored',
    () async {
      final s = session();
      addTearDown(s.dispose);
      await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
      final stale = Port(), fresh = Port();
      s.attach(stale, 0);
      s.attach(fresh, s.rendererGeneration);
      expect(await s.read(target()), book());
      expect(stale.urls, isEmpty);
      expect(fresh.urls, hasLength(1));
    },
  );
  test(
    'queue deadline prevents expired request from starting another network request',
    () async {
      final s = session(), p = Port()..neverDone = true;
      addTearDown(s.dispose);
      s.attach(p, 0);
      await Future.wait([
        expectLater(s.read(target()), throwsA(isA<HuanmengApiException>())),
        expectLater(s.read(target(8)), throwsA(isA<HuanmengApiException>())),
      ]);
      expect(p.urls, [target()]);
      expect(s.rendererGeneration, greaterThan(0));
    },
  );
  test('old token cannot complete a new operation', () async {
    final s = session(), p = Port()..wrongToken = true;
    addTearDown(s.dispose);
    s.attach(p, 0);
    await expectLater(s.read(target()), throwsA(isA<HuanmengApiException>()));
    expect(s.rendererGeneration, greaterThan(0));
  });
  test(
    'source revision change rejects in-flight response and cancels queued old work',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final s = session(), p = Port()..response = (_) => gate.future;
      addTearDown(s.dispose);
      s.attach(p, 0);
      final one = expectLater(
        s.read(target()),
        throwsA(isA<HuanmengApiException>()),
      );
      final two = expectLater(
        s.read(target(8)),
        throwsA(isA<HuanmengApiException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      sourceRevision.value++;
      gate.complete({'status': 200, 'text': jsonEncode(book())});
      await Future.wait([one, two]);
      expect(p.urls, [target()]);
      expect(s.rendererGeneration, 1);
    },
  );
  test(
    'verified JSON is target-bound, consumed once and cannot cross a source revision',
    () async {
      final s = session(), p = Port();
      addTearDown(s.dispose);
      s.attach(p, 0);
      final request = HuanmengVerificationRequired(
        target(),
        sourceRevision.value,
      );
      expect(s.acceptVerification(request, probe(target(8), book(8))), isFalse);
      expect(s.acceptVerification(request, probe(target(), book())), isTrue);
      expect(await s.read(target()), book());
      expect(p.urls, isEmpty);
      expect(await s.read(target()), book());
      expect(p.urls, [target()]);
      expect(s.acceptVerification(request, probe(target(), book())), isTrue);
      sourceRevision.value++;
      expect(s.acceptVerification(request, probe(target(), book())), isFalse);
      await s.read(target());
      expect(p.urls, hasLength(2));
    },
  );
  test('verification cache is capped at four entries', () async {
    final s = session(), p = Port();
    addTearDown(s.dispose);
    s.attach(p, 0);
    for (var i = 1; i <= 5; i++) {
      expect(
        s.acceptVerification(
          HuanmengVerificationRequired(target(i), sourceRevision.value),
          probe(target(i), book(i)),
        ),
        isTrue,
      );
    }
    await s.read(target(1));
    await s.read(target(5));
    expect(p.urls, [target(1)]);
  });
  test(
    'challenge, incomplete detail and mismatched book cannot be confirmed',
    () {
      final s = session();
      addTearDown(s.dispose);
      final request = HuanmengVerificationRequired(
        target(),
        sourceRevision.value,
      );
      for (final bad in [
        {...probe(target(), book()), 'challenge': true},
        probe(target(), {'data': {}}),
        probe(target(), book(8)),
      ]) {
        expect(s.acceptVerification(request, bad), isFalse);
      }
    },
  );
  test(
    'JSON and bridge envelopes have strict size bounds and typed decoding errors',
    () {
      expect(
        () => HuanmengApiSession.decodeEnvelope(
          jsonEncode({
            'data': {'content': '注' * 700000},
          }),
        ),
        throwsA(isA<HuanmengApiException>()),
      );
      expect(
        () => HuanmengApiSession.decodeProbe(
          'x' * (HuanmengApiSession.maxBytes * 8 + 1),
        ),
        throwsA(isA<HuanmengApiException>()),
      );
      expect(
        () => HuanmengApiSession.decodeProbe('not json'),
        throwsA(isA<HuanmengApiException>()),
      );
      expect(
        () => HuanmengApiSession.decodeEnvelope('<html>error</html>'),
        throwsA(isA<HuanmengApiException>()),
      );
      expect(
        HuanmengApiSession.decodeProbe(jsonEncode(jsonEncode({'done': true}))),
        {'done': true},
      );
    },
  );
  test('request starts respect serial source spacing', () async {
    final s = HuanmengApiSession(
          requestSpacing: const Duration(milliseconds: 55),
        ),
        p = Port();
    addTearDown(s.dispose);
    s.attach(p, 0);
    await Future.wait([s.read(target()), s.read(target(8))]);
    expect(
      p.starts[1].difference(p.starts[0]).inMilliseconds,
      greaterThanOrEqualTo(45),
    );
  });
}
