import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:wild/sources/rules/legado_compatibility.dart';

Map<String, dynamic> _sample() => Map<String, dynamic>.from(
  (jsonDecode(File('test/fixtures/huanmeng-source.json').readAsStringSync())
              as List)
          .single
      as Map,
);

Map<String, dynamic> _rules(LegadoImportResult result) =>
    result.definition['rules'] as Map<String, dynamic>;

String _field(
  dynamic operation,
  String field,
  dynamic node, {
  bool items = false,
}) {
  final map =
      (items ? operation['items']['fields'] : operation['fields'])[field]
          as Map;
  return LegadoTextRule.parse(
    map['legado'] as String,
  ).extract(node, first: map['asUrl'] == true);
}

void main() {
  group('original Huanmeng source', () {
    test('fixture is the original file and converts with explicit notices', () {
      expect(
        sha256
            .convert(
              File('test/fixtures/huanmeng-source.json').readAsBytesSync(),
            )
            .toString(),
        'e89cd49af668a62c6ea76a7494b17f320a2fd2e380e874634a56d9fb9fa28a9b',
      );
      final result = convertLegadoSource(_sample());
      expect(result.definition['schemaVersion'], 1);
      expect(result.definition['source']['name'], '幻梦轻小说');
      expect(result.definition['source']['cookieJar'], true);
      expect(
        result.definition['source']['importKey'],
        'https://www.huanmengacg.com',
      );
      expect(
        result.definition['source']['userAgent'],
        contains('Chrome/124.0.0.0'),
      );
      final rules = _rules(result);
      expect(
        rules.keys,
        unorderedEquals(['search', 'detail', 'catalog', 'content']),
      );
      expect(rules['search']['url'], contains('{{query}}'));
      expect(
        rules['search']['items']['selector'],
        'legado:.boxbd@.common-list',
      );
      expect(rules['detail']['fields'].containsKey('status'), false);
      expect(rules['search']['items']['fields'].containsKey('status'), false);
      expect(result.notices.join('\n'), contains('List/String'));
      expect(result.notices.join('\n'), contains('不提供插图'));
      expect(result.notices.join('\n'), contains('checkKeyWord'));
      expect(result.notices.join('\n'), contains('搜索'));
      expect(result.notices.join('\n'), contains('respondTime'));
      expect(rules['catalog']['pagination']['next']['asUrl'], true);
      expect(rules['content']['pagination']['next']['legado'], 'text.下一页@href');
      for (final operation in rules.values) {
        final fields = operation['fields'] ?? operation['items']['fields'];
        for (final field in (fields as Map).values) {
          expect(field['selector'], 'css::scope');
          expect(['text', 'html'], contains(field['value']));
          expect(field['legado'], isA<String>());
        }
      }
    });

    test('search, detail and current-node catalog fields extract in order', () {
      final rules = _rules(convertLegadoSource(_sample()));
      final search = html.parse('''
        <div class="boxbd"><dl class="common-list">
          <dt>第一本书<img data-original="/covers/one.jpg"></dt>
          <dd><a href="/book/one">进入</a><a href="/unrelated">其他</a></dd>
          <dd class="book-module">作者甲··奇幻</dd>
          <dd class="book-profile">第一段简介</dd>
        </dl><dl class="common-list"><dt>第二本书</dt></dl></div>
      ''');
      final cards = LegadoSelector.parse('.boxbd@.common-list').select(search);
      expect(cards, hasLength(2));
      expect(
        _field(rules['search'], 'title', cards.first, items: true),
        '第一本书',
      );
      expect(
        _field(rules['search'], 'author', cards.first, items: true),
        '作者甲',
      );
      expect(
        _field(rules['search'], 'detailUrl', cards.first, items: true),
        '/book/one',
      );
      expect(
        _field(rules['search'], 'coverUrl', cards.first, items: true),
        '/covers/one.jpg',
      );
      final detail = html.parse('''
        <h1 class="book-title">第一本书</h1><dt><img src="/cover.jpg"></dt>
        <p class="book-metas">作者：作者甲</p><p class="book-metas">分类：奇幻</p>
        <div class="book-summary">完整简介</div><a href="/toc">章节列表</a>
      ''');
      expect(_field(rules['detail'], 'author', detail), '作者甲');
      expect(_field(rules['detail'], 'title', detail), '第一本书');
      expect(_field(rules['detail'], 'catalogUrl', detail), '/toc');
      final catalog = html.parse(
        '<ul id="chapterlist"><li><a href="/chapter/1">第一章</a></li><li><a href="/chapter/2">第二章</a></li></ul><a href="?page=2">下一页</a>',
      );
      final chapters = LegadoSelector.parse(
        '#chapterlist li a',
      ).select(catalog);
      expect(
        _field(rules['catalog'], 'title', chapters.last, items: true),
        '第二章',
      );
      expect(
        _field(rules['catalog'], 'url', chapters.last, items: true),
        '/chapter/2',
      );
      expect(
        LegadoTextRule.parse(
          rules['catalog']['pagination']['next']['legado'],
        ).extract(catalog, first: true),
        '?page=2',
      );
    });

    test(
      'all content paragraphs and repeated paragraphs survive watermark cleanup',
      () {
        final content = _rules(convertLegadoSource(_sample()))['content'];
        final document = html.parse('''
        <div id="BookText"><p>第一段 &lt;文字&gt;</p><p>重复段</p><p>重复段</p>
        <p><img src="/picture.jpg">第四段</p>
        <p>本文来自 幻梦轻小说</p><p>最新最全的日本动漫轻小说 幻梦轻小说</p>
        <p>更多轻小说与TXT下载，尽在幻梦轻小说网（www.huanmengacg.com）</p>
        <p>(http://www.huanmengacg.com)</p></div>
      ''');
        final value = _field(content, 'content', document);
        expect(value.trim(), '第一段 <文字>\n重复段\n重复段\n第四段');
        expect(value, isNot(contains('<img')));
        final longDocument = html.parse(
          '<div id="BookText"><p>${'原文' * 25000}</p></div>',
        );
        expect(_field(content, 'content', longDocument), '原文' * 25000);
      },
    );

    test(
      'identity follows the complete original URL across rule and name changes',
      () {
        final first = convertLegadoSource(_sample());
        final changed = _sample();
        changed['bookSourceName'] = '自定义名称';
        changed['ruleSearch']['name'] = 'dd@text';
        final second = convertLegadoSource(changed);
        expect(
          second.definition['source']['id'],
          first.definition['source']['id'],
        );
        expect(
          second.definition['source']['importKey'],
          first.definition['source']['importKey'],
        );
        expect(first.definition['source']['id'], startsWith('legado_ios_'));
        changed['bookSourceUrl'] = 'https://www.huanmengacg.com/another';
        expect(
          convertLegadoSource(changed).definition['source']['id'],
          isNot(first.definition['source']['id']),
        );
      },
    );
  });

  group('selector subset', () {
    final document = html.parse('''
      <section id="s" class="box"><p class="item" data-key="a@b">零</p>
      <p class="item">一<span>嵌套文字</span></p><p class="item">二</p>
      <a href="/next">转到下一页<span>附注</span></a>
      <a href="/nested"><span>下一页</span></a></section>
    ''');

    test(
      'chains, CSS, zero and negative indices, class/tag/id and children',
      () {
        expect(
          LegadoSelector.parse('.box@.item.0').select(document).single.text,
          '零',
        );
        expect(
          LegadoSelector.parse(
            'id.s@class.item.-1',
          ).select(document).single.text,
          '二',
        );
        expect(
          LegadoSelector.parse('id.s@tag.p.1').select(document).single.text,
          '一嵌套文字',
        );
        expect(
          LegadoSelector.parse('id.s@children.0').select(document).single.text,
          '零',
        );
        expect(LegadoSelector.parse('.item.-9').select(document), isEmpty);
        expect(
          LegadoSelector.parse(
            'section > p[data-key="a@b"]',
          ).select(document).single.text,
          '零',
        );
        expect(
          LegadoSelector.parse('@CSS:section > p').select(document),
          hasLength(3),
        );
        final current = document.querySelector('.box')!;
        expect(
          LegadoSelector.parse('.box').select(current).first,
          same(current),
        );
      },
    );

    test('text. contains only own text and does not promote a parent link', () {
      final selected = LegadoSelector.parse('text.下一页').select(document);
      expect(
        selected.where((element) => element.attributes['href'] == '/next'),
        hasLength(1),
      );
      expect(
        selected.where((element) => element.attributes['href'] == '/nested'),
        isEmpty,
      );
      expect(LegadoTextRule.parse('text.下一页@href').extract(document), '/next');
      expect(
        LegadoTextRule.parse(
          'ownText',
        ).extract(document.querySelectorAll('p')[1]),
        '一',
      );
      final split = html.parseFragment(
        '<a href="/split">下<span>忽略</span>一页<br>章节</a>',
      );
      expect(
        LegadoTextRule.parse('ownText').extract(split.querySelector('a')!),
        '下一页 章节',
      );
      expect(LegadoTextRule.parse('text.下一页@href').extract(split), '/split');
    });

    test(
      'clear failures for unsupported selector dialects and index forms',
      () {
        for (final expression in [
          '@XPath://a',
          r'$.books[*]',
          '.item.0:2',
          '.item.[0,1]',
          'a:has(span)',
          '@js:java.ajax("x")',
        ]) {
          expect(
            () => LegadoSelector.parse(expression),
            throwsFormatException,
            reason: expression,
          );
        }
      },
    );
  });

  group('text pipeline', () {
    final document = html.parse(
      '<div id="root"><a href="/one" data-original="/lazy.jpg">甲 乙 乙</a><a href="/two">二</a><a href="/two">二</a><p>作者：丙··分类</p><p>丁</p></div>',
    );
    test(
      'current attributes, first URLs, text duplicates and merge/fallback/interleave',
      () {
        final a = document.querySelector('a')!;
        expect(LegadoTextRule.parse('href').extract(a), '/one');
        expect(LegadoTextRule.parse('data-original').extract(a), '/lazy.jpg');
        expect(LegadoTextRule.parse('text').extract(a), '甲 乙 乙');
        expect(LegadoTextRule.parse('a@href').extract(document), '/one\n/two');
        expect(
          LegadoTextRule.parse('a@href').extract(document, first: true),
          '/one',
        );
        expect(LegadoTextRule.parse('a@text').extract(document), '甲 乙 乙\n二\n二');
        expect(
          LegadoTextRule.parse('p.1@text&&a.1@text').extract(document),
          '丁\n二',
        );
        expect(
          LegadoTextRule.parse('.missing@text||p.1@text').extract(document),
          '丁',
        );
        expect(
          LegadoTextRule.parse('p@text%%a.1@text').extract(document),
          '作者：丙··分类\n二\n丁',
        );
      },
    );

    test(
      'safe regex deletion, replacement groups, and single/global pure replaces',
      () {
        expect(
          LegadoTextRule.parse('p.0@text##作者：').extract(document),
          '丙··分类',
        );
        expect(
          LegadoTextRule.parse('p.0@text##··.*').extract(document),
          '作者：丙',
        );
        expect(LegadoTextRule.parse('p.0@text##.*··').extract(document), '分类');
        expect(
          LegadoTextRule.parse(r'p.0@text##(作者)：##$1=').extract(document),
          '作者=丙··分类',
        );
        expect(
          LegadoTextRule.parse(
            'a.0@text<js>result.replace(/ /,",")</js>',
          ).extract(document),
          '甲,乙 乙',
        );
        expect(
          LegadoTextRule.parse(
            'a.0@text<js>result.replace(/ /g,",")</js>',
          ).extract(document),
          '甲,乙,乙',
        );
        expect(
          LegadoTextRule.parse(
            "a.0@text @js: result.replace('乙', '丙');",
          ).extract(document),
          '甲 丙 乙',
        );
        expect(
          LegadoTextRule.parse(r'a.0@text##\s+##-').extract(document),
          '甲-乙-乙',
        );
        expect(LegadoTextRule.parse('p.1@text##不存在|').extract(document), '丁');
      },
    );

    test('HTML reads remove scripts without modifying the caller DOM', () {
      final node =
          html
              .parseFragment(
                '<div><p>原文</p><script>danger()</script><style>p{}</style></div>',
              )
              .querySelector('div')!;
      final rule = LegadoTextRule.parse('html');
      expect(rule.returnsHtml, true);
      expect(rule.extract(node), '<div><p>原文</p></div>');
      expect(node.querySelector('script'), isNotNull);
    });

    test(
      'rejects arbitrary scripts, bridge access, callbacks and extra statements',
      () {
        for (final expression in [
          'text<js>java.ajax("https://example.test")</js>',
          'text<js>while(true){}</js>',
          'text<js>result.replace(/a/g,java.getString("x"))</js>',
          'text<js>result.replace(/a/g,"b");java.ajax("x")</js>',
          'text<js>result.replace(/a/g,() => "b")</js>',
          'text<js>result.replace(/a/gi,"b")</js>',
          '<js>"constant"</js>',
        ]) {
          expect(
            () => LegadoTextRule.parse(expression),
            throwsFormatException,
            reason: expression,
          );
        }
      },
    );

    test(
      'rejects backtracking bombs and enforces pattern, DOM and output limits',
      () {
        for (final expression in [
          'text##(a+)+\$',
          'text##(a|aa)+',
          'text##a*a*',
          r'text##(a)\1',
          r'text##\Qliteral\E',
          r'text##x##$1',
          'text##(?=a)',
          'text##${'a' * 1025}',
        ]) {
          expect(
            () => LegadoTextRule.parse(expression),
            throwsFormatException,
            reason: expression,
          );
        }
        final deep = html.parse('${'<div>' * 135}x${'</div>' * 135}');
        expect(
          () => LegadoTextRule.parse('text').extract(deep),
          throwsFormatException,
        );
        final tooLarge = html.parseFragment(
          '<p>${'字' * (2 * 1024 * 1024 + 1)}</p>',
        );
        expect(
          () => LegadoTextRule.parse('text').extract(tooLarge),
          throwsFormatException,
        );
        final expands = LegadoTextRule.parse('text##a.*##${r'$&' * 2000}');
        expect(
          () => expands.extract(html.parseFragment('a' * 2048)),
          throwsFormatException,
        );
      },
    );
  });

  group('conversion capability boundaries', () {
    test('literal JSON.stringify must consume the complete expression', () {
      for (final header in [
        '@js:JSON.stringify({"User-Agent":"ok"});java.ajax("x")',
        '@js:JSON.stringify({"User-Agent":java.getString("x")})',
        '@js:JSON.stringify({"User-Agent":"ok"}) + "extra"',
        '@js:JSON.stringify({"Cookie":"secret"})',
        '{"Authorization":"secret"}',
      ]) {
        final source = _sample()..['header'] = header;
        expect(
          () => convertLegadoSource(source),
          throwsFormatException,
          reason: header,
        );
      }
    });

    test('optional metadata cannot carry executable code', () {
      final source = _sample();
      source['ruleBookInfo']['kind'] = 'text<js>java.ajax("x")</js>';
      expect(() => convertLegadoSource(source), throwsFormatException);
      source['ruleBookInfo']['kind'] = '';
      source['ruleSearch']['kind'] = 'text<js>java.ajax("x")</js>';
      expect(() => convertLegadoSource(source), throwsFormatException);
    });

    test(
      'required fields, unsupported operation fields and URL expressions fail clearly',
      () {
        final missing = _sample();
        missing['ruleSearch'].remove('name');
        expect(() => convertLegadoSource(missing), throwsFormatException);
        final content = _sample();
        content['ruleContent']['content'] = 'text<js>result.decrypt()</js>';
        expect(() => convertLegadoSource(content), throwsFormatException);
        final unknown = _sample();
        unknown['ruleToc']['preUpdateJs'] = 'java.ajax("x")';
        expect(() => convertLegadoSource(unknown), throwsFormatException);
        final scriptLibrary = _sample()..['jsLib'] = 'java.ajax("x")';
        expect(() => convertLegadoSource(scriptLibrary), throwsFormatException);
        final url = _sample()..['searchUrl'] = '/search?q={{java.ajax("x")}}';
        expect(() => convertLegadoSource(url), throwsFormatException);
      },
    );

    test(
      'empty explore rules reuse search only with an actual explore URL',
      () {
        final source = _sample()..['exploreUrl'] = '/latest';
        final result = convertLegadoSource(source);
        expect(_rules(result)['discover']['url'], '/latest');
        expect(
          _rules(result)['discover']['items']['selector'],
          'legado:.boxbd@.common-list',
        );
      },
    );
  });
}
