import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/rules/rule_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rule source definition and batch validation', () {
    test('rejects unknown schema versions and invalid JSON explicitly', () {
      final unknownVersion = _source(rules: _searchRules())
        ..['schemaVersion'] = 99;
      final versionResult = validateRuleSourceBatch(jsonEncode(unknownVersion));
      expect(versionResult.single.isSuccess, isFalse);
      expect(versionResult.single.error, contains('schemaVersion=99'));

      final unknownSchema = _source(rules: _searchRules())
        ..['schema'] = 'other-rule-format';
      expect(
        () => RuleSourceDefinition.fromJson(unknownSchema),
        throwsA(isA<RuleSourceSchemaException>()),
      );

      final unknownField = _source(rules: _searchRules())
        ..['rules']['search']['surprise'] = true;
      expect(
        () => RuleSourceDefinition.fromJson(unknownField),
        throwsA(isA<RuleSourceSchemaException>()),
      );

      final badJson = validateRuleSourceBatch('{bad json');
      expect(badJson.single.isSuccess, isFalse);
      expect(badJson.single.error, contains('JSON 格式错误'));
    });

    test(
      'validates a batch independently and rejects duplicate stable ids',
      () {
        final source = _source(rules: _searchRules());
        final results = validateRuleSourceBatch(jsonEncode([source, source]));
        expect(results.map((r) => r.isSuccess), [true, false]);
        expect(results.last.error, contains('source.id 重复'));
      },
    );

    test(
      'serializes validated rules and supports a stable renamed identity',
      () {
        final original = RuleSourceDefinition.fromJson(
          _source(rules: _searchRules()),
        );
        final renamed = original.toJson(id: 'saved-copy', name: '保存副本');
        final restored = RuleSourceDefinition.fromJson(renamed);
        expect(restored.id, 'saved-copy');
        expect(restored.name, '保存副本');
        expect(
          restored.searchRule?.urlTemplate,
          original.searchRule?.urlTemplate,
        );
        expect(restored.capabilities.names, original.capabilities.names);
      },
    );

    test('refuses scripts, XPath, unknown selectors and local URLs', () {
      final scriptRules = _searchRules();
      scriptRules['search']['items']['fields']['title'] = {
        'selector': 'js:app.run()',
        'value': 'text',
      };
      final withScript = _source(rules: scriptRules);
      expect(
        () => RuleSourceDefinition.fromJson(withScript),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );

      final xpathRules = _searchRules();
      xpathRules['search']['items']['selector'] = 'xpath://div/book';
      final withXPath = _source(rules: xpathRules);
      expect(
        () => RuleSourceDefinition.fromJson(withXPath),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );

      final local = _source(rules: _searchRules())
        ..['source']['baseUrl'] = 'http://127.0.0.1:8080/';
      expect(
        () => RuleSourceDefinition.fromJson(local),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );

      final unsupportedJsonPath = _source(
        rules: {
          'search': {
            'url': '/search?q={{query}}',
            'items': {
              'selector': r'json:$.books[0]',
              'fields': {
                'title': {'selector': r'json:$.title', 'value': 'text'},
                'detailUrl': {'selector': r'json:$.url', 'value': 'text'},
              },
            },
          },
        },
      );
      expect(
        () => RuleSourceDefinition.fromJson(unsupportedJsonPath),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );
    });

    test('converts a declared Legado CSS subset and refuses JavaScript', () {
      final legado = <String, dynamic>{
        'bookSourceName': '中文测试源',
        'bookSourceUrl': 'https://fiction.example/',
        'bookSourceVersion': '2026.1',
        'searchUrl': '/search?q={{key}}&page={{page}}',
        'ruleSearch': {
          'bookList': '.book',
          'name': '.name@text',
          'author': '.author@text',
          'bookUrl': 'a@href',
          'coverUrl': 'img@src',
        },
        'ruleBookInfo': {'name': 'h1@text', 'tocUrl': 'a.toc@href'},
        'ruleToc': {
          'chapterList': '.chapter',
          'chapterName': '.name@text',
          'chapterUrl': 'a@href',
        },
        'ruleContent': {'content': '#content@html'},
      };
      final source = RuleSourceDefinition.fromLegadoJson(legado);
      expect(source.id, startsWith('legado_'));
      expect(source.name, '中文测试源');
      expect(source.capabilities.search, isTrue);
      expect(source.capabilities.detail, isTrue);
      expect(source.capabilities.catalog, isTrue);
      expect(source.capabilities.content, isTrue);
      expect(source.capabilities.cover, isTrue);
      expect(source.capabilities.images, isTrue);

      final discoveryOnly =
          Map<String, dynamic>.from(legado)
            ..remove('searchUrl')
            ..remove('ruleSearch')
            ..['exploreUrl'] = '/books';
      discoveryOnly['ruleExplore'] = Map<String, dynamic>.from(
        legado['ruleSearch'] as Map,
      );
      final noSearch = RuleSourceDefinition.fromLegadoJson(discoveryOnly);
      expect(noSearch.capabilities.discover, isTrue);
      expect(noSearch.capabilities.search, isFalse);

      legado['ruleContent'] = {'content': '@js:javaScript()'};
      expect(
        () => RuleSourceDefinition.fromLegadoJson(legado),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );
    });

    test(
      'Legado defaults distinguish same-host rule sets deterministically',
      () {
        final legado = <String, dynamic>{
          'bookSourceName': '同站书源',
          'bookSourceUrl': 'https://fiction.example/',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {
            'bookList': '.book',
            'name': '.name@text',
            'bookUrl': 'a@href',
          },
          'ruleBookInfo': {'name': 'h1@text'},
        };
        final original = RuleSourceDefinition.fromLegadoJson(legado);
        final reordered = <String, dynamic>{
          for (final entry in legado.entries.toList().reversed)
            entry.key: entry.value,
        };
        final sameRules = RuleSourceDefinition.fromLegadoJson(reordered);
        final otherRuleSet = Map<String, dynamic>.from(legado)
          ..['ruleSearch'] = {
            'bookList': '.book',
            'name': '.title@text',
            'bookUrl': 'a@href',
          };
        final changedRules = RuleSourceDefinition.fromLegadoJson(otherRuleSet);

        expect(sameRules.id, original.id);
        expect(changedRules.id, isNot(original.id));
      },
    );
  });

  group('offline rule execution', () {
    test(
      'extracts Chinese CSS fields and resolves relative URLs across pages',
      () async {
        final source = RuleSourceDefinition.fromJson(
          _source(rules: _searchRules()),
        );
        final transport = _FakeTransport((uri) async {
          if (uri.path == '/search' && uri.queryParameters['page'] == '1') {
            return _html('''
            <article class="book">
              <a class="detail" href="../detail/1"><b class="title">星海物语</b></a>
              <span class="author">作者甲</span>
              <img class="cover" src="../covers/1.jpg">
            </article>
            <a class="next" href="?page=2">下一页</a>
          ''');
          }
          if (uri.path == '/search' && uri.queryParameters['page'] == '2') {
            return _html('''
            <article class="book">
              <a class="detail" href="/detail/2"><b class="title">雨夜</b></a>
              <span class="author">作者乙</span>
            </article>
          ''');
          }
          return _notFound();
        });

        final engine = RuleSourceEngine(source, transport: transport);
        final first = await engine.search('星海');
        expect(first.pagesFetched, 1);
        expect(first.reachedEnd, isFalse);
        expect(first.nextPageUrl, endsWith('/search?page=2'));
        expect(first.items.single.title, '星海物语');
        expect(first.items.single.author, '作者甲');
        expect(
          first.items.single.detailUrl,
          'https://fiction.example/detail/1',
        );
        expect(
          first.items.single.coverUrl,
          'https://fiction.example/covers/1.jpg',
        );
        expect(first.items.single.id, first.items.single.detailUrl);
        final second = await engine.search(
          '星海',
          nextPageUrl: first.nextPageUrl,
        );
        expect(second.reachedEnd, isTrue);
        expect(second.items.single.title, '雨夜');
        expect(transport.visited, hasLength(2));
        expect(transport.visited.first.queryParameters['q'], '星海');
      },
    );

    test('allows public fc domain in schema and source requests', () async {
      final sourceJson = _source(rules: _searchRules())
        ..['source']['baseUrl'] = 'https://fc2.com/';
      final source = RuleSourceDefinition.fromJson(sourceJson);
      final transport = _FakeTransport(
        (uri) async => _html('''
          <article class="book">
            <a class="detail" href="/book/1"><b class="title">公开域名可用</b></a>
          </article>
        '''),
      );

      final result = await RuleSourceEngine(
        source,
        transport: transport,
      ).search('公开');

      expect(transport.visited.single.host, 'fc2.com');
      expect(result.items.single.title, '公开域名可用');
      expect(result.items.single.detailUrl, 'https://fc2.com/book/1');
    });

    test('extracts JSONPath fields and follows a JSON next link', () async {
      final rules = {
        'search': {
          'url': '/api/search?q={{query}}&page={{page}}',
          'items': {
            'selector': r'json:$.data.books[*]',
            'fields': {
              'title': {'selector': r'json:$.title', 'value': 'text'},
              'detailUrl': {'selector': r'json:$.url', 'value': 'text'},
              'author': {'selector': r'json:$.author', 'value': 'text'},
            },
          },
          'pagination': {
            'next': {'selector': r'json:$.data.next', 'value': 'text'},
          },
        },
      };
      final source = RuleSourceDefinition.fromJson(_source(rules: rules));
      final transport = _FakeTransport((uri) async {
        if (uri.queryParameters['page'] == '1') {
          return _json({
            'data': {
              'books': [
                {'title': 'JSON中文', 'url': '/book/j1', 'author': '甲'},
              ],
              'next': '?page=2',
            },
          });
        }
        return _json({
          'data': {
            'books': [
              {'title': '第二本', 'url': '/book/j2', 'author': '乙'},
            ],
            'next': '',
          },
        });
      });

      final engine = RuleSourceEngine(source, transport: transport);
      final first = await engine.search('中文');
      expect(first.pagesFetched, 1);
      expect(first.items.single.title, 'JSON中文');
      expect(first.nextPageUrl, endsWith('/api/search?page=2'));
      final second = await engine.search('中文', nextPageUrl: first.nextPageUrl);
      expect(second.items.single.title, '第二本');
      expect(second.items.single.detailUrl, 'https://fiction.example/book/j2');
    });

    test(
      'keeps chapter URLs and paginates catalog and sanitized chapter HTML',
      () async {
        final rules = {
          'detail': {
            'url': '{{bookUrl}}',
            'fields': {
              'title': {'selector': 'css:h1', 'value': 'text'},
              'coverUrl': {
                'selector': 'css:img.cover',
                'value': 'attr',
                'attribute': 'src',
              },
              'catalogUrl': {
                'selector': 'css:a.toc',
                'value': 'attr',
                'attribute': 'href',
              },
            },
          },
          'catalog': {
            'url': '{{tocUrl}}',
            'items': {
              'selector': 'css:.chapter',
              'fields': {
                'id': {
                  'selector': 'css:a',
                  'value': 'attr',
                  'attribute': 'href',
                },
                'title': {'selector': 'css:a', 'value': 'text'},
                'url': {
                  'selector': 'css:a',
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
              'content': {'selector': 'css:#reader', 'value': 'html'},
            },
            'pagination': {
              'next': {
                'selector': 'css:a.next',
                'value': 'attr',
                'attribute': 'href',
              },
            },
          },
        };
        final source = RuleSourceDefinition.fromJson(_source(rules: rules));
        final transport = _FakeTransport((uri) async {
          if (uri.path == '/detail/1') {
            return _html(
              '<h1>星海物语</h1><img class="cover" src="../covers/c.jpg"><a class="toc" href="../toc/1">目录</a>',
            );
          }
          if (uri.path == '/toc/1' && uri.queryParameters['page'] != '2') {
            return _html('''
            <li class="chapter"><a href="../chapter/a.html">第一章</a></li>
            <a class="next" href="?page=2">下一页</a>
          ''');
          }
          if (uri.path == '/toc/1' && uri.queryParameters['page'] == '2') {
            return _html(
              '<li class="chapter"><a href="/chapter/b.html">第二章</a></li>',
            );
          }
          if (uri.path == '/chapter/a.html' &&
              uri.queryParameters['p'] != '2') {
            return _html('''
            <div id="reader"><p>正文第一段</p><img src="../images/p1.jpg">
              <script>bad()</script><a class="next" href="?p=2">继续</a></div>
          ''');
          }
          if (uri.path == '/chapter/a.html' &&
              uri.queryParameters['p'] == '2') {
            return _html(
              '<div id="reader"><p>正文第二段</p><img src="javascript:alert(1)"></div>',
            );
          }
          return _notFound();
        });
        final engine = RuleSourceEngine(source, transport: transport);

        final detail = await engine.detail('https://fiction.example/detail/1');
        expect(detail.title, '星海物语');
        expect(detail.coverUrl, 'https://fiction.example/covers/c.jpg');
        expect(detail.catalogUrl, 'https://fiction.example/toc/1');
        final catalog = await engine.catalog(
          detail.catalogUrl,
          detailUrl: detail.detailUrl,
        );
        expect(catalog.pagesFetched, 2);
        expect(catalog.chapters.map((chapter) => chapter.title), [
          '第一章',
          '第二章',
        ]);
        expect(catalog.chapters.first.id, '../chapter/a.html');
        expect(
          catalog.chapters.first.url,
          'https://fiction.example/chapter/a.html',
        );

        final chapter = await engine.chapter(
          catalog.chapters.first.url,
          detailUrl: detail.detailUrl,
        );
        expect(chapter.pagesFetched, 2);
        expect(chapter.contentHtml, contains('正文第一段'));
        expect(chapter.contentHtml, contains('正文第二段'));
        expect(chapter.contentHtml, isNot(contains('<script')));
        expect(chapter.contentHtml, isNot(contains('javascript:')));
        expect(
          chapter.images.single.url,
          'https://fiction.example/images/p1.jpg',
        );
      },
    );

    test('detects circular catalog pagination URLs', () async {
      final source = RuleSourceDefinition.fromJson(
        _source(
          rules: {
            'catalog': {
              'url': '{{tocUrl}}',
              'items': {
                'selector': 'css:.chapter',
                'fields': {
                  'title': {'selector': 'css:a', 'value': 'text'},
                  'url': {
                    'selector': 'css:a',
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
          },
        ),
      );
      final transport = _FakeTransport(
        (uri) async => _html('''
        <li class="chapter"><a href="/chapter/a">第一章</a></li>
        <a class="next" href="?page=1">next</a>
      '''),
      );
      await expectLater(
        RuleSourceEngine(
          source,
          transport: transport,
        ).catalog('https://fiction.example/toc?page=1'),
        throwsA(isA<RuleSourcePaginationException>()),
      );
    });

    test('enforces the configured maximum catalog page count', () async {
      final source = RuleSourceDefinition.fromJson(
        _source(
          rules: {
            'catalog': {
              'url': '{{tocUrl}}',
              'items': {
                'selector': 'css:.chapter',
                'fields': {
                  'title': {'selector': 'css:a', 'value': 'text'},
                  'url': {
                    'selector': 'css:a',
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
          },
        ),
      );
      final transport = _FakeTransport(
        (uri) async => _html('''
        <li class="chapter"><a href="/chapter/a">第一章</a></li>
        <a class="next" href="?page=2">next</a>
      '''),
      );
      await expectLater(
        RuleSourceEngine(
          source,
          transport: transport,
          limits: const RuleSourceLimits(maxPages: 1),
        ).catalog('https://fiction.example/toc?page=1'),
        throwsA(isA<RuleSourceLimitException>()),
      );
    });

    test('enforces response size and timeout bounds', () async {
      final source = RuleSourceDefinition.fromJson(
        _source(rules: _searchRules()),
      );
      final largeTransport = _FakeTransport(
        (uri) async => RuleSourceHttpResponse(
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bytes: Uint8List(1024),
        ),
      );
      await expectLater(
        RuleSourceEngine(
          source,
          transport: largeTransport,
          limits: const RuleSourceLimits(maxResponseBytes: 64),
        ).search('x'),
        throwsA(isA<RuleSourceLimitException>()),
      );

      final slowTransport = _FakeTransport(
        (uri) => Future.delayed(
          const Duration(milliseconds: 100),
          () => _html('<div></div>'),
        ),
      );
      await expectLater(
        RuleSourceEngine(
          source,
          transport: slowTransport,
          limits: const RuleSourceLimits(
            requestTimeout: Duration(milliseconds: 10),
            operationTimeout: Duration(milliseconds: 50),
          ),
        ).search('x'),
        throwsA(isA<RuleSourceNetworkException>()),
      );
    });

    test('bounds redirects and rejects redirects to another origin', () async {
      final source = RuleSourceDefinition.fromJson(
        _source(
          rules: {
            'detail': {
              'url': '{{bookUrl}}',
              'fields': {
                'title': {'selector': 'css:h1', 'value': 'text'},
              },
            },
          },
        ),
      );
      final redirect = _FakeTransport(
        (uri) async => _redirect('https://other.example/detail'),
      );
      await expectLater(
        RuleSourceEngine(
          source,
          transport: redirect,
        ).detail('https://fiction.example/detail/1'),
        throwsA(isA<RuleSourceUnsupportedException>()),
      );

      final bounded = _FakeTransport((uri) async => _redirect('/detail/next'));
      await expectLater(
        RuleSourceEngine(
          source,
          transport: bounded,
          limits: const RuleSourceLimits(maxRedirects: 0),
        ).detail('https://fiction.example/detail/1'),
        throwsA(isA<RuleSourceLimitException>()),
      );
    });

    test(
      'refuses malformed JSON responses with a clear extraction error',
      () async {
        final source = RuleSourceDefinition.fromJson(
          _source(
            rules: {
              'search': {
                'url': '/api?q={{query}}',
                'items': {
                  'selector': r'json:$.books[*]',
                  'fields': {
                    'title': {'selector': r'json:$.title', 'value': 'text'},
                    'detailUrl': {'selector': r'json:$.url', 'value': 'text'},
                  },
                },
              },
            },
          ),
        );
        final transport = _FakeTransport(
          (uri) async => RuleSourceHttpResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bytes: Uint8List.fromList(utf8.encode('{broken')),
          ),
        );
        await expectLater(
          RuleSourceEngine(source, transport: transport).search('x'),
          throwsA(isA<RuleSourceExtractionException>()),
        );
      },
    );

    test('decodes GBK using the existing bundled character table', () async {
      final source = RuleSourceDefinition.fromJson(
        _source(rules: _searchRules()),
      );
      final before = ascii.encode(
        '<article class="book"><a class="detail" href="/b/1"><b class="title">',
      );
      final after = ascii.encode('</b></a></article>');
      final bytes = Uint8List.fromList([...before, 0xc7, 0xe1, ...after]);
      final transport = _FakeTransport(
        (uri) async => RuleSourceHttpResponse(
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=GBK'},
          bytes: bytes,
        ),
      );
      final result = await RuleSourceEngine(
        source,
        transport: transport,
      ).search('x');
      expect(result.items.single.title, '轻');
    });
  });
}

Map<String, dynamic> _source({required Map<String, dynamic> rules}) => {
  'schema': 'litetale-rule-source',
  'schemaVersion': 1,
  'source': {
    'id': 'demo-source',
    'name': '演示书源',
    'baseUrl': 'https://fiction.example/',
    'version': '1.0.0',
  },
  'rules': rules,
};

Map<String, dynamic> _searchRules() => {
  'search': {
    'url': '/search?q={{query}}&page={{page}}',
    'items': {
      'selector': 'css:article.book',
      'fields': {
        'title': {'selector': 'css:b.title', 'value': 'text'},
        'author': {'selector': 'css:.author', 'value': 'text'},
        'detailUrl': {
          'selector': 'css:a.detail',
          'value': 'attr',
          'attribute': 'href',
        },
        'coverUrl': {
          'selector': 'css:img.cover',
          'value': 'attr',
          'attribute': 'src',
        },
      },
    },
    'pagination': {
      'next': {'selector': 'css:a.next', 'value': 'attr', 'attribute': 'href'},
    },
  },
};

RuleSourceHttpResponse _html(String body) => RuleSourceHttpResponse(
  statusCode: 200,
  headers: const {'content-type': 'text/html; charset=utf-8'},
  bytes: Uint8List.fromList(utf8.encode(body)),
);

RuleSourceHttpResponse _json(Object body) => RuleSourceHttpResponse(
  statusCode: 200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
  bytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
);

RuleSourceHttpResponse _redirect(String location) => RuleSourceHttpResponse(
  statusCode: 302,
  headers: {'location': location},
  bytes: Uint8List(0),
);

RuleSourceHttpResponse _notFound() =>
    RuleSourceHttpResponse(statusCode: 404, headers: {}, bytes: Uint8List(0));

class _FakeTransport implements RuleSourceTransport {
  _FakeTransport(this.handler);

  final Future<RuleSourceHttpResponse> Function(Uri uri) handler;
  final visited = <Uri>[];

  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) {
    visited.add(uri);
    return handler(uri);
  }
}
