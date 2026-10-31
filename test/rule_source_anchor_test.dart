import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/rules/legado_compatibility.dart';
import 'package:wild/sources/rules/rule_source.dart';

const _origin = 'https://www.huanmengacg.com';
const _bookUrl = '$_origin/index.php/book_info_794.html?from=search';

Map<String, dynamic> _originalDefinition() {
  final bytes = File('test/fixtures/huanmeng-source.json').readAsBytesSync();
  expect(
    sha256.convert(bytes).toString(),
    'e89cd49af668a62c6ea76a7494b17f320a2fd2e380e874634a56d9fb9fa28a9b',
  );
  final raw = Map<String, dynamic>.from(
    (jsonDecode(utf8.decode(bytes)) as List).single as Map,
  );
  return convertLegadoSource(raw).definition;
}

RuleSourceDefinition _source() =>
    RuleSourceDefinition.fromJson(_originalDefinition());

String _detail({
  String catalogHref = '#zhangjie',
  String cover = '/cover.jpg',
  String next = '',
}) => '''
  <h1 class="book-title">SeaBed</h1><p class="book-metas">作者：作者甲</p>
  <dl><dt><img src="$cover"></dt></dl><div class="book-summary">完整简介</div>
  <a href="$catalogHref">章节列表</a><div id="zhangjie">
  <ul id="chapterlist"><li><a href="/index.php/book_read_794_763.html">第一章</a></li></ul>
  </div>${next.isEmpty ? '' : '<a href="$next">下一页</a>'}
''';

void main() {
  group('catalog anchors from the unmodified Huanmeng source', () {
    test(
      'relative fragment uses the fetched detail document and leaves identities unchanged',
      () async {
        final definition = _source();
        final sourceId = definition.id;
        final importKey = definition.importKey;
        final transport = _Pages((_) => _html(_detail()));
        final engine = RuleSourceEngine(definition, transport: transport);
        final detail = await engine.detail(_bookUrl);
        expect(detail.title, 'SeaBed');
        expect(detail.catalogUrl, _bookUrl);
        expect(detail.detailUrl, _bookUrl);
        final catalog = await engine.catalog(
          detail.catalogUrl,
          detailUrl: detail.detailUrl,
        );
        expect(catalog.chapters.single.title, '第一章');
        expect(catalog.chapters.single.id, '/index.php/book_read_794_763.html');
        expect(
          catalog.chapters.single.url,
          '$_origin/index.php/book_read_794_763.html',
        );
        expect(catalog.pagesFetched, 1);
        expect(definition.id, sourceId);
        expect(definition.importKey, importKey);
        expect(transport.visited.map((uri) => uri.toString()), [
          _bookUrl,
          _bookUrl,
        ]);
        expect(transport.visited.every((uri) => !uri.hasFragment), true);
      },
    );

    test('absolute same-document anchors retain path and full query', () async {
      for (final target in [
        '$_bookUrl#zhangjie',
        '${_bookUrl.replaceFirst('https:', 'http:')}#zhangjie',
      ]) {
        final transport = _Pages((_) => _html(_detail(catalogHref: target)));
        final detail = await RuleSourceEngine(
          _source(),
          transport: transport,
        ).detail(_bookUrl);
        expect(detail.catalogUrl, _bookUrl);
        expect(detail.detailUrl, _bookUrl);
        expect(transport.visited, [Uri.parse(_bookUrl)]);
      }
    });

    test(
      'an anchor resolves against the final redirect URL without changing book identity',
      () async {
        const alias = '$_origin/book/794';
        final transport = _Pages(
          (uri) =>
              uri.toString() == alias
                  ? RuleSourceHttpResponse(
                    statusCode: 302,
                    headers: const {
                      'location': '/index.php/book_info_794.html?from=search',
                    },
                    bytes: utf8.encode(''),
                  )
                  : _html(_detail()),
        );
        final engine = RuleSourceEngine(_source(), transport: transport);
        final detail = await engine.detail(alias);
        expect(detail.detailUrl, alias);
        expect(detail.catalogUrl, _bookUrl);
        expect(
          (await engine.catalog(detail.catalogUrl, detailUrl: alias)).chapters,
          hasLength(1),
        );
        expect(transport.visited.map((uri) => uri.toString()), [
          alias,
          _bookUrl,
          _bookUrl,
        ]);
      },
    );

    test(
      'another same-origin catalog document loses only its fragment',
      () async {
        const catalogUrl = '$_origin/catalog/794?sort=asc';
        final transport = _Pages(
          (_) => _html(_detail(catalogHref: '$catalogUrl#chapterlist')),
        );
        final detail = await RuleSourceEngine(
          _source(),
          transport: transport,
        ).detail(_bookUrl);
        expect(detail.catalogUrl, catalogUrl);
      },
    );

    test(
      'cross-origin, credential, private and executable catalog links remain rejected',
      () async {
        for (final target in const [
          'https://foreign.example/book#zhangjie',
          'https://user:secret@www.huanmengacg.com/book#zhangjie',
          'http://127.0.0.1/book#zhangjie',
          '//192.168.0.1/book#zhangjie',
          'https://[::1]/book#zhangjie',
          'javascript:alert(1)#zhangjie',
          'data:text/plain,chapter#zhangjie',
        ]) {
          final transport = _Pages((_) => _html(_detail(catalogHref: target)));
          await expectLater(
            RuleSourceEngine(_source(), transport: transport).detail(_bookUrl),
            throwsA(isA<RuleSourceUnsupportedException>()),
            reason: target,
          );
          expect(transport.visited, [Uri.parse(_bookUrl)]);
        }
      },
    );

    test(
      'catalog opt-in does not allow fragments on cover or identity URLs',
      () async {
        for (final cover in [
          '#cover',
          '$_origin/cover.jpg#image',
          'https://cover.example/cover.jpg#image',
        ]) {
          final transport = _Pages((_) => _html(_detail(cover: cover)));
          await expectLater(
            RuleSourceEngine(_source(), transport: transport).detail(_bookUrl),
            throwsA(isA<RuleSourceUnsupportedException>()),
          );
          expect(transport.visited, hasLength(1));
        }
        final transport = _Pages(
          (_) => _html(_detail(cover: 'https://cover.example/cover.jpg')),
        );
        final engine = RuleSourceEngine(_source(), transport: transport);
        expect(
          (await engine.detail(_bookUrl)).coverUrl,
          'https://cover.example/cover.jpg',
        );
        await expectLater(
          engine.detail('$_bookUrl#book'),
          throwsA(isA<RuleSourceUnsupportedException>()),
        );
        expect(transport.visited, hasLength(1));
      },
    );
  });

  group('pagination anchors', () {
    test(
      'relative and absolute current-document catalog anchors end after one request',
      () async {
        for (final target in ['#zhangjie', '$_bookUrl#zhangjie']) {
          final transport = _Pages((_) => _html(_detail(next: target)));
          final catalog = await RuleSourceEngine(
            _source(),
            transport: transport,
            limits: const RuleSourceLimits(maxPages: 1),
          ).catalog(_bookUrl);
          expect(catalog.pagesFetched, 1);
          expect(catalog.chapters, hasLength(1));
          expect(transport.visited, [Uri.parse(_bookUrl)]);
        }
      },
    );

    test(
      'a chapter next link containing only its anchor does not duplicate paragraphs',
      () async {
        const chapterUrl = '$_origin/index.php/book_read_794_763.html';
        for (final target in ['#BookText', '$chapterUrl#BookText']) {
          final transport = _Pages(
            (_) => _html(
              '<div id="BookText"><p>第一段</p><p>第二段</p></div><a href="$target">下一页</a>',
            ),
          );
          final chapter = await RuleSourceEngine(
            _source(),
            transport: transport,
            limits: const RuleSourceLimits(maxPages: 1),
          ).chapter(chapterUrl);
          expect(chapter.pagesFetched, 1);
          expect(chapter.contentHtml, '<p>第一段</p><p>第二段</p>');
          expect(chapter.url, chapterUrl);
          expect(transport.visited, [Uri.parse(chapterUrl)]);
        }
      },
    );

    test(
      'a single search page exposes no next URL for a local fragment',
      () async {
        final json = _originalDefinition();
        json['rules']['search']['pagination'] =
            json['rules']['catalog']['pagination'];
        final transport = _Pages(
          (uri) => _html('''
        <div class="boxbd"><dl class="common-list"><dt><a href="/book/794">SeaBed</a></dt></dl></div>
        <a href="$uri#results">下一页</a>
      '''),
        );
        final result = await RuleSourceEngine(
          RuleSourceDefinition.fromJson(json),
          transport: transport,
        ).search('SeaBed');
        expect(result.items.single.id, '/book/794');
        expect(result.reachedEnd, true);
        expect(result.nextPageUrl, isNull);
        expect(transport.visited, hasLength(1));
      },
    );

    test(
      'another document with a fragment is fetched once without the fragment',
      () async {
        const secondPage = '$_origin/catalog/794?page=2&sort=asc';
        final transport = _Pages(
          (uri) =>
              uri.toString() == secondPage
                  ? _html(
                    '<ul id="chapterlist"><li><a href="/chapter/2">第二章</a></li></ul><a href="#chapterlist">下一页</a>',
                  )
                  : _html(_detail(next: '$secondPage#chapterlist')),
        );
        final result = await RuleSourceEngine(
          _source(),
          transport: transport,
          limits: const RuleSourceLimits(maxPages: 2),
        ).catalog(_bookUrl);
        expect(result.pagesFetched, 2);
        expect(result.chapters.map((chapter) => chapter.title), ['第一章', '第二章']);
        expect(transport.visited.map((uri) => uri.toString()), [
          _bookUrl,
          secondPage,
        ]);
      },
    );

    test(
      'an anchor targeting an earlier document still reports a pagination loop',
      () async {
        const secondPage = '$_origin/catalog/2';
        final transport = _Pages(
          (uri) => _html(
            _detail(
              next:
                  uri.toString() == secondPage
                      ? '$_bookUrl#zhangjie'
                      : '$secondPage#zhangjie',
            ),
          ),
        );
        await expectLater(
          RuleSourceEngine(_source(), transport: transport).catalog(_bookUrl),
          throwsA(isA<RuleSourcePaginationException>()),
        );
        expect(transport.visited.map((uri) => uri.toString()), [
          _bookUrl,
          secondPage,
        ]);
      },
    );

    test(
      'a plain self-link remains a typed loop error without another request',
      () async {
        final transport = _Pages((_) => _html(_detail(next: _bookUrl)));
        await expectLater(
          RuleSourceEngine(_source(), transport: transport).catalog(_bookUrl),
          throwsA(isA<RuleSourcePaginationException>()),
        );
        expect(transport.visited, hasLength(1));
      },
    );

    test('a fragment cannot hide an unsafe next-page destination', () async {
      for (final target in const [
        'https://foreign.example/page#next',
        'http://10.0.0.1/page#next',
        'javascript:alert(1)#next',
        'data:text/plain,page#next',
      ]) {
        final transport = _Pages((_) => _html(_detail(next: target)));
        await expectLater(
          RuleSourceEngine(_source(), transport: transport).catalog(_bookUrl),
          throwsA(isA<RuleSourceUnsupportedException>()),
          reason: target,
        );
        expect(transport.visited, [Uri.parse(_bookUrl)]);
      }
    });
  });
}

RuleSourceHttpResponse _html(String body) => RuleSourceHttpResponse(
  statusCode: 200,
  headers: const {'content-type': 'text/html; charset=utf-8'},
  bytes: utf8.encode(body),
);

class _Pages implements RuleSourceTransport {
  _Pages(this.response);
  final RuleSourceHttpResponse Function(Uri) response;
  final visited = <Uri>[];

  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    visited.add(uri);
    return response(uri);
  }
}
