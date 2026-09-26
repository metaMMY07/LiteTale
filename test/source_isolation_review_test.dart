import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wild/pages/search_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/lnovel_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/api/wenku8.dart' as w8;
import 'package:wild/src/rust/wenku8/models.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.pages);

  final Map<String, String> pages;
  final requests = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final body = pages[request.url.toString()];
    if (body == null) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('missing')),
        404,
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      request: request,
      headers: const {'content-type': 'text/html; charset=utf-8'},
    );
  }
}

class _SpySource implements BookSource {
  _SpySource(this.source);

  final SourceId source;
  var discoverCalls = 0;
  final searches = <(String, String, int)>[];

  @override
  SourceId get id => source;

  @override
  Future<List<HomeBlock>> discover() async {
    discoverCalls++;
    return [HomeBlock(title: source.label, list: const [])];
  }

  @override
  Future<w8.PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) async {
    searches.add((keyword, type, page));
    return w8.PageStatsNovelCover(
      currentPage: page,
      maxPage: page,
      records: const [],
    );
  }

  @override
  Future<SourceBookDetail> detail(String bookId) => throw UnimplementedError();

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    activeSource.value = SourceId.wenku8;
  });

  test('source prefixes keep identical remote numbers independent', () {
    expect(sourceOf('42'), SourceId.wenku8);
    expect(sourceOf('lns:42'), SourceId.lightNovelShelf);
    expect(sourceOf('lnv:42'), SourceId.lnovel);
  });

  test('local source bookcases use distinct IDs', () async {
    activeSource.value = SourceId.lnovel;
    expect((await api.bookcaseList()).single.id, 'lnovel:local');

    activeSource.value = SourceId.lightNovelShelf;
    expect((await api.bookcaseList()).single.id, 'lns:local');
  });

  test(
    'lnovel adapter stays on lnovel.tw for list, detail and chapter',
    () async {
      final client = _FakeClient({
        'https://lnovel.tw/books?page=1': '''
        <main>
          <a href="/books-7"><img src="/covers/7.jpg">书A</a>
          <a href="/books-7"><img src="/covers/duplicate.jpg">重复</a>
          <a rel="next" href="/books?page=2">下一页</a>
        </main>
      ''',
        'https://lnovel.tw/books-7': '''
        <main><article>
          <h1>书A</h1>
          <dl><dt>作者</dt><dd>作者A</dd></dl>
          <img src="/covers/7.jpg">
          <p class="my-2">介绍</p>
          <div class="accordion-item">
            <h3>第一卷</h3>
            <div class="list-group"><a href="/chapters-9">第一章</a></div>
          </div>
        </article></main>
      ''',
        'https://lnovel.tw/chapters-9': '''
        <main><div class="card-body">
          <p>正文<br>后</p><img data-src="/images/9.jpg"><script>bad()</script>
        </div></main>
      ''',
      });
      final source = LNovelSource(client: client);

      final page = await source.list();
      final detail = await source.detail('lnv:7');
      final chapter = await source.chapter('lnv:7', 'lnv:9');

      expect(page.records.single.aid, 'lnv:7');
      expect(detail.volumes.single.chapters.single.cid, 'lnv:9');
      expect(
        chapter.content,
        contains('<!--image-->https://lnovel.tw/images/9.jpg<!--image-->'),
      );
      expect(chapter.content, isNot(contains('bad')));
      expect(
        client.requests,
        everyElement(predicate<Uri>((uri) => uri.host == 'lnovel.tw')),
      );
      expect(
        client.requests,
        isNot(contains(Uri.parse('https://www.lightnovel.app/'))),
      );
      expect(
        client.requests,
        isNot(contains(Uri.parse('https://www.wenku8.net/'))),
      );
    },
  );

  test(
    'source API routes discovery and search through the selected source',
    () async {
      final original = api.bookSources[SourceId.lnovel]!;
      final spy = _SpySource(SourceId.lnovel);
      api.bookSources[SourceId.lnovel] = spy;
      addTearDown(() => api.bookSources[SourceId.lnovel] = original);

      activeSource.value = SourceId.lnovel;
      await api.index();
      await api.search(searchType: 'articlename', searchKey: '书', page: 2);

      expect(spy.discoverCalls, 1);
      expect(spy.searches, [('书', 'articlename', 2)]);
    },
  );

  testWidgets(
    'a pending search must not paint results after the source changes',
    (tester) async {
      final pending = Completer<w8.PageStatsNovelCover>();
      activeSource.value = SourceId.lnovel;

      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            initialSearchKey: '旧源关键词',
            historyLoader: () async => const [],
            searcher:
                ({required searchType, required searchKey, required page}) =>
                    pending.future,
          ),
        ),
      );
      await tester.pump();

      activeSource.value = SourceId.lightNovelShelf;
      pending.complete(
        w8.PageStatsNovelCover(
          currentPage: 1,
          maxPage: 1,
          records: [
            NovelCover(aid: 'lnv:7', title: '旧源结果', img: '', detailUrl: ''),
          ],
        ),
      );
      await tester.pump();

      expect(find.text('旧源结果'), findsNothing);
    },
  );
}
