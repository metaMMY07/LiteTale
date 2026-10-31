import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/esj_source.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/rules/rule_source_engine.dart';

RuleSourceHttpResponse response(
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => RuleSourceHttpResponse(
  statusCode: status,
  headers: headers,
  bytes: Uint8List.fromList(utf8.encode(body)),
);
String page(String body) => '<title>测试 - ESJ Zone</title>$body';
String listing({
  int current = 1,
  int total = 2,
  int book = 123,
  bool empty = false,
}) => page(
  '''
  <div class="shop-toolbar"></div>
  ${empty ? '' : '<div class="card mb-30"><h5 class="card-title"><a href="/detail/$book.html">样例轻小说</a></h5><div class="lazyload" data-src="https://images.example.com/cover.jpg"></div></div>'}
  <div id="page-selection"></div><script>\$('#page-selection').bootpag({total:$total,page:$current,href:"/list-21/{{number}}.html"});</script>''',
);
String detail() => page('''
  <div class="product-gallery"><img src="https://images.example.com/a.jpg"></div>
  <div class="book-detail"><h2>样例轻小说</h2><ul class="book-detail"><li><strong>作者:</strong> 测试作者</li></ul></div>
  <div class="description">这是一部测试小说</div><div id="chapterList">
    <p>第一卷</p><a href="https://www.esjzone.cc/forum/123/456.html"><p>第一章</p></a>
    <a href="https://www.esjzone.cc/forum/123/456.html"><p>重复入口</p></a>
    <p>第二卷</p><a href="/forum/123/457.html">第二章</a>
    <details><summary>折叠分卷</summary><div><a href="/forum/123/460.html">第三章</a></div></details>
    <a href="https://other.example/forum/123/458.html">站外链接</a>
    <a href="/forum/999/459.html">其他书籍</a>
  </div>''');

class Transport implements RuleSourceTransport {
  Transport(this.read);
  final Future<RuleSourceHttpResponse> Function(Uri) read;
  final calls = <Uri>[];
  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) {
    calls.add(uri);
    return read(uri);
  }
}

EsjSource source(Transport transport) =>
    EsjSource(transport: transport, spacing: Duration.zero);

void main() {
  test(
    'ordinary original list and next page have distinct URLs and stable ids',
    () async {
      final transport = Transport(
        (u) async =>
            response(listing(current: u.path.endsWith('2.html') ? 2 : 1)),
      );
      final api = source(transport);
      final first = await api.list();
      final second = await api.list(page: 2);
      expect(first.records.single.aid, 'esj:123');
      expect(sourceOf(first.records.single.aid), SourceId.esj);
      expect(first.maxPage, 2);
      expect(second.currentPage, 2);
      expect(transport.calls.map((u) => u.path), [
        '/list-21/',
        '/list-21/2.html',
      ]);
    },
  );
  test(
    'search preserves a Unicode keyword as one native search path segment',
    () async {
      final t = Transport((_) async => response(listing()));
      await source(t).search('雨狐 / &', 'articlename', 1);
      expect(t.calls.single.pathSegments, ['tags-21', '雨狐 / &', '']);
      expect(t.calls.single.query, isEmpty);
    },
  );
  test('popularity uses the published list-24 route', () async {
    final t = Transport((_) async => response(listing()));
    await source(t).list(popular: true);
    expect(t.calls.single.path, '/list-24/');
  });
  test('empty native search is a valid terminal result', () async {
    final t = Transport((_) async => response(listing(empty: true, total: 0)));
    final result = await source(t).search('没有的测试书', 'articlename', 1);
    expect(result.records, isEmpty);
    expect(result.maxPage, 1);
  });
  test(
    'stale server page and fake HTTP 200 error cannot masquerade as books',
    () async {
      final stale = source(
        Transport((_) async => response(listing(current: 1))),
      );
      await expectLater(stale.list(page: 2), throwsFormatException);
      final fake = source(
        Transport((_) async => response(page('<h2>Not found</h2>'))),
      );
      await expectLater(fake.list(), throwsFormatException);
    },
  );
  test(
    'detail groups chapters and rejects cross-book and external links',
    () async {
      final t = Transport((_) async => response(detail()));
      final book = await source(t).detail('esj:123');
      expect(book.info.title, '样例轻小说');
      expect(book.info.author, '测试作者');
      expect(book.info.imgUrl, 'https://images.example.com/a.jpg');
      expect(book.volumes.map((v) => v.title), ['第一卷', '第二卷', '折叠分卷']);
      expect(book.volumes.expand((v) => v.chapters).map((c) => c.cid), [
        'esj:123:456',
        'esj:123:457',
        'esj:123:460',
      ]);
      expect(t.calls.length, 1);
    },
  );
  test(
    'chapter preserves paragraphs and safe illustrations, not scripts or forged image markers',
    () async {
      final t = Transport(
        (_) async => response(
          page('''<div class="forum-content">
      <p>第一段</p><p>第二段</p><script>danger()</script>
      &lt;!--image--&gt;http://127.0.0.1/x&lt;!--image--&gt;
      <img src="https://images.example.com/a.jpg"><img src="http://127.0.0.1/a">
      <img src="https://user:password@images.example.com/x"><img src="https://a.local/x">
      <iframe src="https://other.example"></iframe></div>'''),
        ),
      );
      final content =
          (await source(t).chapter('esj:123', 'esj:123:456')).content;
      expect(content, contains('第一段\n第二段'));
      expect(
        content,
        contains('<!--image-->https://images.example.com/a.jpg<!--image-->'),
      );
      expect(content, isNot(contains('danger')));
      expect(content, isNot(contains('<!--image-->http://127.0.0.1')));
      expect(content, isNot(contains('user:password')));
      expect(content, isNot(contains('a.local')));
    },
  );
  test('mismatched chapter is refused before any HTTP request', () async {
    final t = Transport((_) async => response(''));
    await expectLater(
      source(t).chapter('esj:123', 'esj:999:456'),
      throwsFormatException,
    );
    expect(t.calls, isEmpty);
  });
  test(
    'verification, restricted and empty content pages fail explicitly',
    () async {
      for (final body in [
        '<title>Just a moment...</title>',
        page('<h2>需要原站登录</h2>'),
        page('<div class="forum-content"></div>'),
      ]) {
        final api = source(Transport((_) async => response(body)));
        await expectLater(
          api.chapter('esj:123', 'esj:123:456'),
          throwsA(anyOf(isA<EsjSourceException>(), isA<FormatException>())),
        );
      }
    },
  );
  test('identical simultaneous reads share one transport operation', () async {
    final gate = Completer<RuleSourceHttpResponse>();
    final t = Transport((_) => gate.future);
    final api = source(t);
    final a = api.list();
    final b = api.list();
    await Future<void>.delayed(Duration.zero);
    expect(t.calls.length, 1);
    gate.complete(response(listing()));
    await Future.wait([a, b]);
  });
  test(
    '429 respects cooldown and queued reads do not retry on another channel',
    () async {
      final t = Transport(
        (_) async => response('', status: 429, headers: {'retry-after': '60'}),
      );
      final api = source(t);
      await expectLater(api.list(), throwsA(isA<EsjSourceException>()));
      await expectLater(
        api.detail('esj:123'),
        throwsA(isA<EsjSourceException>()),
      );
      expect(t.calls.length, 1);
    },
  );
  test('invalid ids and oversized response are rejected', () async {
    final t = Transport((_) async => response('x' * (2 * 1024 * 1024 + 1)));
    await expectLater(source(t).list(), throwsFormatException);
    await expectLater(source(t).detail('esj:0'), throwsFormatException);
  });
}
