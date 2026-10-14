import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/rule_book_source.dart';
import 'package:wild/sources/rules/rule_source.dart';

RuleSourceDefinition definition() => RuleSourceDefinition.fromJson({
  'schema': 'litetale-rule-source',
  'schemaVersion': 1,
  'source': {
    'id': 'pages',
    'name': '分页',
    'baseUrl': 'https://example.org',
    'version': '1',
  },
  'rules': {
    'discover': {
      'url': '/list',
      'items': {
        'selector': 'css:a.book',
        'fields': {
          'title': {'selector': 'css::scope', 'value': 'text'},
          'detailUrl': {
            'selector': 'css::scope',
            'value': 'attr',
            'attribute': 'href',
          },
        },
      },
      'pagination': {
        'next': {
          'selector': 'css:a.next',
          'value': 'attr',
          'attribute': 'href',
        },
      },
    },
    'content': {
      'url': '{{chapterUrl}}',
      'fields': {
        'content': {'selector': 'css:#body', 'value': 'html'},
      },
      'pagination': {
        'next': {
          'selector': 'css:nav a',
          'value': 'attr',
          'attribute': 'href',
          'matchText': '下一页',
        },
      },
    },
  },
});

class Transport implements RuleSourceTransport {
  Transport(this.load);
  final Future<String> Function(Uri) load;
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
      headers: const {},
      bytes: Uint8List.fromList(utf8.encode(await load(uri))),
    );
  }
}

void main() {
  test(
    'text matched pagination combines all parts and stops on final previous link',
    () async {
      final transport = Transport(
        (uri) async => switch (uri.queryParameters['page']) {
          '2' =>
            '<div id="body"><p>中段</p></div><nav><a href="?page=1">上一页</a><a href="?page=3">下一页</a></nav>',
          '3' =>
            '<div id="body"><p>末段</p></div><nav><a href="?page=1">首页</a><a href="?page=2">上一页</a></nav>',
          _ =>
            '<div id="body"><p>开篇</p></div><nav><a href="?page=2"> 下一页 </a></nav>',
        },
      );
      final source = RuleSourceDefinition.fromJson(definition().toJson());
      final result = await RuleSourceEngine(
        source,
        transport: transport,
      ).chapter('https://example.org/chapter');
      expect(result.pagesFetched, 3);
      expect(readerTextFromHtml(result.contentHtml), '开篇\n中段\n末段');
      expect(transport.visited.length, 3);
    },
  );

  test(
    'secure source upgrades its own legacy HTTP links and supports self fields',
    () async {
      final transport = Transport(
        (_) async => '<a class="book" href="http://example.org/book/1">书籍</a>',
      );
      final result =
          await RuleSourceEngine(definition(), transport: transport).discover();
      expect(result.single.title, '书籍');
      expect(result.single.detailUrl, 'https://example.org/book/1');
    },
  );

  test(
    'late same-query response cannot poison the current next-page cache',
    () async {
      final first = Completer<String>();
      var calls = 0;
      final transport = Transport((_) {
        calls++;
        return calls == 1
            ? first.future
            : Future.value(
              '<a class="book" href="/book/new">新书</a><a class="next" href="/list?page=2">下一页</a>',
            );
      });
      final source = RuleBookSource(
        definition(),
        engine: RuleSourceEngine(definition(), transport: transport),
      );
      final old = source.search('书', 'articlename', 1);
      await Future<void>.delayed(Duration.zero);
      final current = await source.search('书', 'articlename', 1);
      first.complete(
        '<a class="book" href="/book/old">旧书</a><a class="next" href="/list?page=2">下一页</a>',
      );
      await old;
      expect(current.records.single.title, '新书');
    },
  );
}
