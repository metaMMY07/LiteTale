import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/rule_book_source.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/sources/rules/rule_source.dart';

import 'support/huanmeng_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  RuleSourceDefinition source() =>
      inspectSourceImport(
        huanmengSourceJson,
        platform: TargetPlatform.iOS,
      ).single.definition!;

  test(
    'the original rules parse search, details, two catalog pages and all chapter paragraphs',
    () async {
      final transport = _Pages((uri) {
        switch (uri.path) {
          case '/index.php/book/search':
            expect(uri.queryParameters['key'], 'SeaBed 中文');
            return '''<div class="boxbd"><dl class="common-list">
            <dt><a href="/book/794"><img data-original="/cover.jpg">SeaBed</a></dt>
            <dd class="book-module">作者甲··奇幻</dd><dd class="book-profile">简介</dd>
          </dl></div>''';
          case '/book/794':
            return '''<h1 class="book-title">SeaBed</h1>
            <p class="book-metas">作者：作者甲</p><p class="book-metas">分类：奇幻</p>
            <p class="book-metas">状态：完结</p><p class="book-metas">更新：今天</p>
            <dl><dt><img src="/cover.jpg"></dt></dl><div class="book-summary">完整简介</div>
            <a href="/catalog/1">章节列表</a>''';
          case '/catalog/1':
            return '<ul id="chapterlist"><li><a href="/chapter/1">第一章</a></li></ul><a href="/catalog/2">下一页</a>';
          case '/catalog/2':
            return '<ul id="chapterlist"><li><a href="/chapter/2">第二章</a></li></ul><a href="/book/other">下一本</a>';
          case '/chapter/1':
            return '''<div id="BookText"><p>第一段&lt;保留尖括号&gt;</p><p>第二段<strong>强调</strong></p>
            <p>本文来自 幻梦轻小说</p><p><img src="/illust.jpg"></p></div>
            <a href="/chapter/1-2">下一页</a>''';
          case '/chapter/1-2':
            return '<div id="BookText"><p>第三段</p><p>最后一段</p></div><a href="/chapter/2">下一章</a>';
          default:
            throw StateError('unexpected fixture request: $uri');
        }
      });
      final definition = source();
      final engine = RuleSourceEngine(definition, transport: transport);
      final result = await engine.search('SeaBed 中文');
      expect(result.items.single.title, 'SeaBed');
      expect(result.items.single.author, '作者甲');
      expect(
        result.items.single.coverUrl,
        'https://www.huanmengacg.com/cover.jpg',
      );
      final detail = await engine.detail(result.items.single.detailUrl);
      expect(detail.author, '作者甲');
      expect(detail.catalogUrl, 'https://www.huanmengacg.com/catalog/1');
      final catalog = await engine.catalog(
        detail.catalogUrl,
        detailUrl: detail.detailUrl,
      );
      expect(catalog.pagesFetched, 2);
      expect(catalog.chapters.map((c) => c.title), ['第一章', '第二章']);
      final content = await engine.chapter(catalog.chapters.first.url);
      expect(content.pagesFetched, 2);
      final text = readerTextFromHtml(content.contentHtml);
      expect(text, contains('第一段<保留尖括号>'));
      expect(text, contains('第二段强调'));
      expect(text, contains('第三段'));
      expect(text, contains('最后一段'));
      expect(text, isNot(contains('本文来自')));
      expect(
        content.images,
        isEmpty,
      ); // The supplied @text rule discards image markup.
      expect(
        transport.visited.map((uri) => uri.path),
        isNot(contains('/chapter/2')),
      );
      final adapter = RuleBookSource(definition, engine: engine);
      final chapter = await adapter.chapter(
        ruleBookId(definition.id, detail.detailUrl),
        ruleBookId(definition.id, catalog.chapters.first.url),
      );
      expect(chapter.content, text);
    },
  );

  test(
    'untrusted next-page origins and loops fail before visiting another site',
    () async {
      final foreign = _Pages(
        (_) =>
            '<div id="BookText"><p>正文</p></div><a href="https://elsewhere.example/page">下一页</a>',
      );
      await expectLater(
        RuleSourceEngine(
          source(),
          transport: foreign,
        ).chapter('https://www.huanmengacg.com/chapter/1'),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );
      expect(foreign.visited, hasLength(1));
      final loop = _Pages(
        (_) => '<div id="BookText"><p>正文</p></div><a href="/chapter/1">下一页</a>',
      );
      await expectLater(
        RuleSourceEngine(
          source(),
          transport: loop,
        ).chapter('https://www.huanmengacg.com/chapter/1'),
        throwsA(isA<RuleSourcePaginationException>()),
      );
      expect(loop.visited, hasLength(1));
    },
  );
}

class _Pages implements RuleSourceTransport {
  _Pages(this.html);
  final String Function(Uri) html;
  final visited = <Uri>[];
  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    visited.add(uri);
    return RuleSourceHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'text/html; charset=utf-8'},
      bytes: Uint8List.fromList(utf8.encode(html(uri))),
    );
  }
}
