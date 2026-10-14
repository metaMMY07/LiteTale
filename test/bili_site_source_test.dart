import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/sources/bili_site_source.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

const _detail = '''
<div class="book-html-box">
  <h1 class="book-name">SeaBed</h1>
  <div class="book-info">
    <div class="book-label">
      <a href="javascript:">连载</a>
      <a href="/wenku/dengeki/1.html">电击文库</a>
    </div>
    <span>最后更新：2026-10-01</span>
    <div class="book-dec">公开简介</div>
  </div>
  <div class="book-img"><img src="https://www.linovelib.com/cover.jpg"></div>
  <div class="book-side"><div class="book-author">
    作者 <a href="/authorarticle/example.html">作者甲</a>
  </div></div>
</div>
''';

String _catalog({int? foreignBookId}) => '''
<h1>SeaBed</h1>
<div id="volume-list" class="volume-list">
  <div class="volume clearfix">
    <div class="volume-info"><a href="/novel/2844/vol_100.html">卷一</a></div>
    <h2 class="v-line">SeaBed 序章</h2>
    <ul class="chapter-list clearfix">
      <li class="col-4"><a href="/novel/2844/278138.html">序章『开始的余温』</a></li>
      <li class="col-4"><a href="/novel/${foreignBookId ?? 2844}/278139.html">第一章</a></li>
    </ul>
  </div>
  <div class="volume clearfix">
    <div class="volume-info">
      <a href="/novel/2844/vol_101.html"><img src="/vol.png"></a>
      <a href="/novel/2844/vol_101.html">SeaBed 1 森林里的疗养院</a>
    </div>
    <h2 class="v-line">SeaBed 1 森林里的疗养院</h2>
    <ul class="chapter-list clearfix">
      <li class="col-4"><a href="/novel/2844/278140.html">第一话</a></li>
    </ul>
  </div>
</div>
''';

const _mobileDetail = '''
<div class="book-layout">
  <div class="module-book-cover"><img class="book-cover" src="/cover-mobile.jpg" alt="SeaBed"></div>
  <div class="book-cell">
    <h1 class="book-title">SeaBed</h1>
    <div class="book-rand-a"><span class="authorname"><a href="/authorarticle/Paleontology.html">Paleontology</a></span> 著</div>
    <p class="book-meta book-layout-inline">34.9 万字 | 完结</p>
    <p class="book-meta"><span class="tag-small-group"><em class="tag-small"><a href="/wenku/game/1.html">游戏剧本</a></em></span></p>
  </div>
</div>
<a class="book-status" href="/novel/2844/catalog"><span class="book-meta-l">最后更新·2025-06-07</span></a>
<section id="bookSummary"><content>测试用移动版简介</content></section>
<div class="module-content page-fans"><div class="book-layout">
  <p class="book-title" title="粉丝榜第1位">不要当成作品标题</p>
</div></div>
''';

String _mobileCatalog({int? foreignBookId}) => '''
<h1 class="book-title">SeaBed</h1>
<div id="volumes" class="chapter-ol chapter-ol-catalog">
  <div class="catalog-volume">
    <a href="/novel/2844/vol_278372.html"><h3>SeaBed 序章 四叶草设计事务所</h3></a>
    <ul class="volume-chapters">
      <li class="chapter-li jsChapter"><a class="chapter-li-a" href="/novel/2844/278138.html">第1话 贵呼视点</a></li>
      <li class="chapter-li jsChapter"><a class="chapter-li-a" href="/novel/${foreignBookId ?? 2844}/278139.html">第2话</a></li>
    </ul>
  </div>
  <div class="catalog-volume">
    <a href="/novel/2844/vol_278373.html"><h3>SeaBed 1 森林里的疗养院</h3></a>
    <ul class="volume-chapters">
      <li class="chapter-li jsChapter"><a class="chapter-li-a" href="/novel/2844/278140.html">第1话</a></li>
    </ul>
  </div>
</div>
''';

String _mobileLibraryPage() => '''
<div class="page page-category-detail">
  <div class="module module-merge">
    <ol class="book-ol book-ol-normal cover-mode">
      <li class="book-li"><a class="book-layout" href="/novel/2844.html">
        <div class="book-cover"><img class="lazyload" data-src="/cover-mobile.jpg"></div>
        <div class="book-cell"><h4 class="book-title">SeaBed</h4>
          <p class="book-desc">测试简介</p><div class="book-meta"><span class="book-author">作者</span></div>
        </div>
      </a></li>
      <li class="book-li"><a class="book-layout" href="https://example.org/novel/9999.html">
        <div class="book-cell"><h4 class="book-title">外站作品</h4></div>
      </a></li>
    </ol>
    <div id="pagelink" class="pagelink">
      <a class="first" href="/wenku/lastupdate_0_0_0_0_0_0_0_1_0.html">1</a>
      <a href="/wenku/lastupdate_0_0_0_0_0_0_0_2_0.html">2</a>
      <a class="last" href="/wenku/lastupdate_0_0_0_0_0_0_0_180_0.html">180</a>
    </div>
  </div>
</div>
''';

String _rankPage({int page = 2}) => '''
<div class="rank_d_list">
  <div class="rank_d_book_img"><a href="/novel/2844.html"><img src="/cover.jpg"></a></div>
  <div class="rank_d_b_name"><a href="/novel/2844.html">SeaBed</a></div>
</div>
<div class="pagebar"><div class="pages">
  <a href="/top/monthvisit/1.html">1</a>
  <a href="/top/monthvisit/$page.html">$page</a>
  <a href="/top/monthvisit/3.html">3</a>
</div></div>
''';

http.Response _html(String body, {int status = 200}) => http.Response(
  body,
  status,
  headers: {'content-type': 'text/html; charset=UTF-8'},
);

BiliSiteSource _source({
  required http.Client client,
  BiliSiteBudget budget = const BiliSiteBudget(),
  BiliSiteSearcher? searcher,
  BiliSiteChapterLoader? chapterLoader,
}) => BiliSiteSource(
  client: client,
  budget: budget,
  searcher:
      searcher ??
      ((_, _) async =>
          const PageStatsNovelCover(currentPage: 1, maxPage: 1, records: [])),
  chapterLoader: chapterLoader ?? ((_, _) async => const SourceChapter('正文')),
);

void main() {
  group('BiliSiteSource', () {
    test(
      'desktop homepage cover belongs to its own sibling book link',
      () async {
        final source = _source(
          client: MockClient(
            (_) async => _html('''
        <a href="/novel/2013.html"><img src="/wrong.jpg"></a>
        <a href="/novel/2844.html"><img src="/seabed.jpg"></a>
        <div class="index_tpic_info"><a href="/novel/2844.html">SeaBed</a></div>
      '''),
          ),
        );
        expect(
          (await source.discover()).single.list.single.img,
          'https://www.bilinovel.net/seabed.jpg',
        );
      },
    );
    test(
      'browser document loader replaces native HTTP and still uses two pages',
      () async {
        final pages = <Uri>[];
        final source = BiliSiteSource(
          client: MockClient(
            (_) => throw StateError('native HTTP must not run'),
          ),
          searcher:
              (_, __) async => const PageStatsNovelCover(
                currentPage: 1,
                maxPage: 1,
                records: [],
              ),
          chapterLoader: (_, __) async => const SourceChapter('正文'),
          documentLoader: (uri) async {
            pages.add(uri);
            return uri.path.endsWith('/catalog') ? _catalog() : _detail;
          },
        );
        final detail = await source.detail('bili:2844');
        expect(detail.info.title, 'SeaBed');
        expect(pages.map((u) => u.path).toSet(), {
          '/novel/2844.html',
          '/novel/2844/catalog',
        });
        expect(pages.length, 2);
      },
    );

    test(
      'keeps stable Bili IDs and parses catalog in DOM order with two GETs',
      () async {
        final calls = <Uri>[];
        final source = _source(
          client: MockClient((request) async {
            calls.add(request.url);
            if (request.url.path == '/novel/2844.html') {
              return _html(_detail);
            }
            if (request.url.path == '/novel/2844/catalog') {
              return _html(_catalog());
            }
            return _html('', status: 404);
          }),
        );

        final result = await source.detail('bili:2844');

        expect(calls, hasLength(2));
        expect(calls.map((uri) => uri.path).toSet(), {
          '/novel/2844.html',
          '/novel/2844/catalog',
        });
        expect(source.id, SourceId.bili);
        expect(result.info.title, 'SeaBed');
        expect(result.info.author, '作者甲');
        expect(result.info.status, '连载');
        expect(result.info.tags, ['电击文库']);
        expect(result.info.finUpdate, '2026-10-01');
        expect(result.info.imgUrl, 'https://www.linovelib.com/cover.jpg');
        expect(result.volumes.map((volume) => volume.id), [
          'bili:2844:vol:100',
          'bili:2844:vol:101',
        ]);
        expect(result.volumes.map((volume) => volume.title), [
          'SeaBed 序章',
          'SeaBed 1 森林里的疗养院',
        ]);
        expect(result.volumes.first.chapters.map((chapter) => chapter.cid), [
          'bili:2844:278138',
          'bili:2844:278139',
        ]);
        expect(result.volumes.first.chapters.first.aid, 'bili:2844');
      },
    );

    test(
      'parses mobile detail and catalog DOM while keeping stable book and chapter IDs',
      () async {
        final calls = <Uri>[];
        final source = _source(
          client: MockClient((request) async {
            calls.add(request.url);
            return request.url.path.endsWith('/catalog')
                ? _html(_mobileCatalog())
                : _html(_mobileDetail);
          }),
        );

        final result = await source.detail('bili:2844');

        expect(calls, hasLength(2));
        expect(calls.map((uri) => uri.host).toSet(), {'www.bilinovel.net'});
        expect(result.info.title, 'SeaBed');
        expect(result.info.author, 'Paleontology');
        expect(result.info.status, '完结');
        expect(result.info.finUpdate, '2025-06-07');
        expect(result.info.tags, ['游戏剧本']);
        expect(
          result.info.imgUrl,
          'https://www.bilinovel.net/cover-mobile.jpg',
        );
        expect(result.info.introduce, '测试用移动版简介');
        expect(result.volumes.map((volume) => volume.id), [
          'bili:2844:vol:278372',
          'bili:2844:vol:278373',
        ]);
        expect(result.volumes.map((volume) => volume.title), [
          'SeaBed 序章 四叶草设计事务所',
          'SeaBed 1 森林里的疗养院',
        ]);
        expect(result.volumes.first.chapters.map((chapter) => chapter.cid), [
          'bili:2844:278138',
          'bili:2844:278139',
        ]);
        expect(result.volumes.last.chapters.single.cid, 'bili:2844:278140');
      },
    );

    test('rejects a mobile catalog chapter from a different book', () async {
      final source = _source(
        client: MockClient(
          (request) async =>
              request.url.path.endsWith('/catalog')
                  ? _html(_mobileCatalog(foreignBookId: 2139))
                  : _html(_mobileDetail),
        ),
      );

      await expectLater(source.detail('bili:2844'), throwsFormatException);
    });

    test(
      'validates the observed Re chapter number 76673 as a stable ID',
      () async {
        var loaded = false;
        final source = _source(
          client: MockClient((_) async => _html('')),
          chapterLoader: (bookId, chapterId) async {
            loaded = true;
            expect(bookId, 'bili:2139');
            expect(chapterId, 'bili:2139:76673');
            return const SourceChapter('loaded');
          },
        );

        expect(
          (await source.chapter('bili:2139', 'bili:2139:76673')).content,
          'loaded',
        );
        expect(loaded, isTrue);
      },
    );

    test(
      'rejects a wrong-book catalog chapter before returning mixed ownership',
      () async {
        final source = _source(
          client: MockClient(
            (request) async =>
                request.url.path.endsWith('.html')
                    ? _html(_detail)
                    : _html(_catalog(foreignBookId: 2139)),
          ),
        );

        await expectLater(source.detail('bili:2844'), throwsFormatException);
      },
    );

    test(
      'rejects a chapter ID belonging to another book before browser callback',
      () async {
        var calls = 0;
        final source = _source(
          client: MockClient((_) async => _html('')),
          chapterLoader: (_, _) async {
            calls++;
            return const SourceChapter('');
          },
        );

        await expectLater(
          source.chapter('bili:2844', 'bili:2139:76673'),
          throwsFormatException,
        );
        expect(calls, 0);
      },
    );

    test(
      'uses the supplied site searcher without fetching a ranking page',
      () async {
        var requests = 0;
        var delegatedKeyword = '';
        var delegatedPage = 0;
        final expected = PageStatsNovelCover(
          currentPage: 2,
          maxPage: 4,
          records: const [
            NovelCover(
              aid: 'bili:2844',
              title: 'SeaBed',
              img: '',
              detailUrl: 'bili:2844',
            ),
          ],
        );
        final source = _source(
          client: MockClient((_) async {
            requests++;
            return _html(_rankPage());
          }),
          searcher: (keyword, page) async {
            delegatedKeyword = keyword;
            delegatedPage = page;
            return expected;
          },
        );

        final result = await source.search('  seabed  ', 'articlename', 2);

        expect(result, expected);
        expect(delegatedKeyword, 'seabed');
        expect(delegatedPage, 2);
        expect(requests, 0);
      },
    );

    test('rejects author search and does not try a local fallback', () async {
      var requests = 0;
      var searches = 0;
      final source = _source(
        client: MockClient((_) async {
          requests++;
          return _html(_rankPage());
        }),
        searcher: (_, _) async {
          searches++;
          return const PageStatsNovelCover(
            currentPage: 1,
            maxPage: 1,
            records: [],
          );
        },
      );

      await expectLater(
        source.search('writer', 'author', 1),
        throwsUnsupportedError,
      );
      expect(searches, 0);
      expect(requests, 0);
    });

    test(
      'requests real page 2 and derives available pages from site pagination links',
      () async {
        Uri? requested;
        final source = _source(
          client: MockClient((request) async {
            requested = request.url;
            return _html(_rankPage());
          }),
        );

        final result = await source.listPage(2, rank: 'monthvisit');

        expect(requested?.path, '/top/monthvisit/2.html');
        expect(result.currentPage, 2);
        expect(result.maxPage, 3);
        expect(result.records.single.aid, 'bili:2844');
      },
    );

    test(
      'publisher categories expose observed routes and category mode uses that route',
      () async {
        Uri? requested;
        final source = _source(
          client: MockClient((request) async {
            requested = request.url;
            return _html(_rankPage());
          }),
        );

        expect(source.categories().length, 14);
        expect(
          source.categories().where((item) => item.name == '讲谈社').single.slug,
          'kodansha',
        );
        await source.listPage(2, mode: 'category', category: 11);
        expect(requested?.path, '/wenku/kodansha/2.html');
        await expectLater(
          source.listPage(1, mode: 'unknown'),
          throwsUnsupportedError,
        );
      },
    );

    test('parses homepage cards from the observed selector', () async {
      final source = _source(
        client: MockClient((request) async {
          expect(request.url.path, '/');
          return _html('''
            <div class="index_tpic_info">
              <a href="/novel/2844.html">SeaBed</a>
              <a class="latest-chapter" href="/novel/2844/278138.html">latest</a>
              <img src="/cover.jpg">
            </div>
          ''');
        }),
      );

      final blocks = await source.discover();
      expect(blocks.single.list.single.aid, 'bili:2844');
      expect(blocks.single.list.single.title, 'SeaBed');
    });

    test(
      'parses mobile homepage cards without appending nearby author text',
      () async {
        final source = _source(
          client: MockClient((request) async {
            expect(request.url.host, 'www.bilinovel.net');
            return _html('''
            <ul>
              <li class="module-slide-li">
                <a class="module-slide-a" href="/novel/2844.html">
                  <img data-src="/cover-mobile.jpg">
                  <h3 class="module-slide-caption">SeaBed</h3>
                </a>
                <span class="module-slide-author">不要拼到标题</span>
              </li>
            </ul>
          ''');
          }),
        );

        final blocks = await source.discover();
        expect(blocks.single.list.single.aid, 'bili:2844');
        expect(blocks.single.list.single.title, 'SeaBed');
        expect(
          blocks.single.list.single.img,
          'https://www.bilinovel.net/cover-mobile.jpg',
        );
      },
    );

    test(
      'caps parsed mobile home records at the configured book limit',
      () async {
        final source = _source(
          budget: const BiliSiteBudget(maxBooks: 1),
          client: MockClient(
            (_) async => _html('''
          <li class="module-slide-li"><a class="module-slide-a" href="/novel/2844.html">
            <img data-src="/one.jpg"><h3 class="module-slide-caption">SeaBed</h3>
          </a></li>
          <li class="module-slide-li"><a class="module-slide-a" href="/novel/2139.html">
            <img data-src="/two.jpg"><h3 class="module-slide-caption">Re:Zero</h3>
          </a></li>
        '''),
          ),
        );

        final blocks = await source.discover();

        expect(blocks.single.list, hasLength(1));
        expect(blocks.single.list.single.aid, 'bili:2844');
      },
    );

    test(
      'parses mobile list cards and follows observed all-library pagination',
      () async {
        final paths = <String>[];
        final source = _source(
          budget: const BiliSiteBudget(maxPage: 200),
          client: MockClient((request) async {
            paths.add(request.url.path);
            return _html(_mobileLibraryPage());
          }),
        );

        final first = await source.listPage(1, mode: 'all');
        final second = await source.listPage(2, mode: 'all');

        expect(paths, ['/wenku/', '/wenku/lastupdate_0_0_0_0_0_0_0_2_0.html']);
        expect(first.currentPage, 1);
        expect(first.maxPage, 180);
        expect(first.records.single.aid, 'bili:2844');
        expect(first.records.single.title, 'SeaBed');
        expect(
          first.records.single.img,
          'https://www.bilinovel.net/cover-mobile.jpg',
        );
        expect(second.currentPage, 2);
        expect(second.maxPage, 180);
      },
    );

    test('rejects non-success HTTP responses without retrying', () async {
      var requests = 0;
      final source = _source(
        client: MockClient((_) async {
          requests++;
          return _html('unavailable', status: 503);
        }),
      );

      await expectLater(source.listPage(1), throwsA(isA<BiliSiteException>()));
      expect(requests, 1);
    });

    test('enforces byte caps even when content-length is absent', () async {
      final source = _source(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('<html>${'x' * 128}</html>'),
            200,
            headers: {'content-type': 'text/html; charset=UTF-8'},
          ),
        ),
        budget: const BiliSiteBudget(maxResponseBytes: 32),
      );

      await expectLater(source.listPage(1), throwsA(isA<BiliSiteException>()));
    });

    test(
      'rejects cross-origin redirects and enforces redirect count',
      () async {
        final crossOrigin = _source(
          client: MockClient(
            (_) async => http.Response(
              '',
              302,
              headers: {'location': 'https://example.org/novel/2844.html'},
            ),
          ),
        );
        await expectLater(
          crossOrigin.listPage(1),
          throwsA(isA<BiliSiteException>()),
        );

        final canonicalCrossOrigin = _source(
          client: MockClient(
            (_) async => http.Response(
              '',
              302,
              headers: {
                'location': 'https://www.linovelib.com/top/monthvisit/1.html',
              },
            ),
          ),
        );
        await expectLater(
          canonicalCrossOrigin.listPage(1),
          throwsA(isA<BiliSiteException>()),
        );

        var hops = 0;
        final tooMany = _source(
          client: MockClient((request) async {
            hops++;
            final page =
                int.tryParse(
                  request.url.path.split('/').last.split('.').first,
                ) ??
                1;
            return http.Response(
              '',
              302,
              headers: {'location': '/top/monthvisit/${page + 1}.html'},
            );
          }),
        );
        await expectLater(
          tooMany.listPage(1),
          throwsA(isA<BiliSiteException>()),
        );
        expect(hops, 3);
      },
    );

    test('enforces request and whole-detail timeouts', () async {
      final slowRequest = _source(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return _html(_rankPage());
        }),
        budget: const BiliSiteBudget(
          requestTimeout: Duration(milliseconds: 20),
        ),
      );
      await expectLater(
        slowRequest.listPage(1),
        throwsA(isA<BiliSiteException>()),
      );

      final slowDetail = _source(
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return request.url.path.endsWith('.html')
              ? _html(_detail)
              : _html(_catalog());
        }),
        budget: const BiliSiteBudget(
          requestTimeout: Duration(seconds: 1),
          detailTimeout: Duration(milliseconds: 20),
        ),
      );
      await expectLater(
        slowDetail.detail('bili:2844'),
        throwsA(isA<BiliSiteException>()),
      );
    });

    test(
      'preserves the default page cap and rejects unsupported ranking slugs',
      () async {
        final source = _source(
          client: MockClient((_) async => _html(_rankPage())),
        );
        await expectLater(
          source.listPage(101),
          throwsA(isA<BiliSiteException>()),
        );
        await expectLater(
          source.listPage(1, rank: 'not-a-real-rank'),
          throwsUnsupportedError,
        );
      },
    );
  });
}
