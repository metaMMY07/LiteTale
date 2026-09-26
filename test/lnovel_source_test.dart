import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/sources/lnovel_source.dart';

void main() {
  test(
    'search encodes queries, owns headers and keeps pagination and ids',
    () async {
      final source = LNovelSource(
        client: MockClient((request) async {
          expect(request.url.host, 'lnovel.tw');
          expect(request.url.queryParameters['page'], '2');
          expect(
            request.url.queryParameters.containsKey('q[name_cont]'),
            isFalse,
          );
          expect(request.headers['Referer'], 'https://lnovel.tw/');
          expect(request.headers.containsKey('Cookie'), isFalse);
          return http.Response(
            '<head><link rel="next" href="/books?page=3"></head><main>'
            '<a href="/books-42"><img src="/cover.webp">星 &amp; 月</a>'
            '<a href="/books-42"><img src="/cover.webp">重复</a></main>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );
      final page = await source.search('星 & 月', 'articlename', 2);
      expect(page.records.single.aid, 'lnv:42');
      expect(page.records.single.img, 'https://lnovel.tw/cover.webp');
      expect(page.maxPage, 3);
      expect(() => source.search('作者', 'author', 1), throwsUnsupportedError);
    },
  );

  test(
    'detail keeps volume ordering without duplicate header chapters',
    () async {
      final source = LNovelSource(
        client: MockClient(
          (_) async => http.Response(
            '''
      <main><article><h1>测试书</h1><img src="/cover.webp">
      <dl><dt>作者</dt><dd>测试作者</dd></dl><p class="my-2">简介</p>
      <div class="accordion-item"><h3><a href="/chapters-7">第一卷</a></h3>
      <div class="list-group"><a href="/chapters-7">序章</a><a href="/chapters-8">插图</a></div></div>
      </article></main>''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );
      final detail = await source.detail('lnv:42');
      expect(detail.info.author, '测试作者');
      expect(detail.volumes.single.chapters.map((c) => c.cid), [
        'lnv:7',
        'lnv:8',
      ]);
      expect(() => source.detail('lns:42'), throwsFormatException);
    },
  );

  test(
    'chapter retains ordered text and illustrations and excludes controls',
    () async {
      final source = LNovelSource(
        client: MockClient(
          (_) async => http.Response(
            '''
      <main><div class="card-body"><h1>标题</h1><p>开头</p>
      <img src="/image.webp"><p>结尾</p><script>bad()</script><nav>下一章</nav>
      <img src="javascript:bad()"></div></main>''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );
      final text = (await source.chapter('lnv:42', 'lnv:7')).content;
      expect(text.indexOf('开头'), lessThan(text.indexOf('<!--image-->')));
      expect(text.indexOf('<!--image-->'), lessThan(text.indexOf('结尾')));
      expect(text, isNot(contains('bad')));
      expect(text, isNot(contains('下一章')));
    },
  );

  test(
    'blocked and changed pages fail visibly instead of yielding false empty results',
    () async {
      final blocked = LNovelSource(
        client: MockClient((_) async => http.Response('denied', 403)),
      );
      expect(() => blocked.discover(), throwsStateError);
      final changed = LNovelSource(
        client: MockClient(
          (_) async => http.Response('<main>verification</main>', 200),
        ),
      );
      expect(() => changed.discover(), throwsFormatException);
    },
  );
}
