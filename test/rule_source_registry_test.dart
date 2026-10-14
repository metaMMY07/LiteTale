import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/rule_book_source.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/sources/rules/rule_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rule source registry persistence and import', () {
    test(
      'retires old bundled classics without losing source identity',
      () async {
        final wiki = _sourceJson(
          id: 'wikisource_zh',
          baseUrl: 'https://zh.wikisource.org',
        );
        final classics = _sourceJson(
          id: 'dushuzhijia_classics',
          baseUrl: 'https://www.dushuzhijia.com',
        );
        final custom = _sourceJson(id: 'my-light-novels');
        var saved = jsonEncode({
          'version': 1,
          'entries': [
            for (final source in [wiki, classics])
              {'definition': source, 'enabled': true, 'builtIn': true},
            {'definition': custom, 'enabled': true, 'builtIn': false},
          ],
        });
        var writes = 0;
        final registry = RuleSourceRegistry(
          read: () async => saved,
          write: (raw) async {
            saved = raw;
            writes++;
          },
        );
        addTearDown(registry.dispose);
        await registry.load(builtIns: [wiki, classics]);
        expect(registry.entries.map((e) => e.definition.id), [
          'my-light-novels',
        ]);
        expect(writes, 0);
        expect(
          sourceOf(
            ruleBookId(
              'wikisource_zh',
              'https://zh.wikisource.org/wiki/example',
            ),
          ).ruleId,
          'wikisource_zh',
        );
        await expectLater(
          registry.install([
            RuleSourceDefinition.fromJson(
              _sourceJson(
                id: 'wikisource_zh',
                baseUrl: 'https://other.example',
              ),
            ),
          ]),
          throwsStateError,
        );
        // A deliberate later import of the same site is still a user decision.
        await registry.install([RuleSourceDefinition.fromJson(wiki)]);
        expect(registry['wikisource_zh']!.builtIn, isFalse);
        final restored = RuleSourceRegistry(
          read: () async => saved,
          write: (_) async {},
        );
        addTearDown(restored.dispose);
        await restored.load(builtIns: []);
        expect(restored['wikisource_zh']!.builtIn, isFalse);
        expect(restored['dushuzhijia_classics'], isNull);
      },
    );

    test(
      'keeps valid imports when a duplicate and unknown version are present',
      () async {
        final valid = _sourceJson(id: 'partial-import');
        final duplicate = _sourceJson(id: 'partial-import');
        final unknownVersion = _sourceJson(id: 'future-version')
          ..['schemaVersion'] = 27;
        final items = inspectSourceImport(
          jsonEncode([valid, duplicate, unknownVersion]),
        );

        expect(items, hasLength(3));
        expect(items[0].definition?.id, 'partial-import');
        expect(items[0].error, isNull);
        expect(items[1].definition, isNull);
        expect(items[1].error, contains('重复'));
        expect(items[2].definition, isNull);
        expect(items[2].error, contains('schemaVersion=27'));

        var persisted = '';
        final registry = RuleSourceRegistry(
          read: () async => '',
          write: (raw) async {
            persisted = raw;
          },
        );
        addTearDown(registry.dispose);
        await registry.load(builtIns: []);
        await registry.install(
          items
              .where((item) => item.definition != null)
              .map((item) => item.definition!)
              .toList(),
        );

        expect(registry.entries.map((entry) => entry.definition.id), [
          'partial-import',
        ]);
        expect(jsonDecode(persisted)['entries'], hasLength(1));
      },
    );

    test(
      'rejects same-id cross-origin replacement without changing config',
      () async {
        var persisted = '';
        var writes = 0;
        final registry = RuleSourceRegistry(
          read: () async => '',
          write: (raw) async {
            writes++;
            persisted = raw;
          },
        );
        addTearDown(registry.dispose);
        await registry.load(builtIns: []);
        final original = RuleSourceDefinition.fromJson(
          _sourceJson(id: 'stable-source', baseUrl: 'https://first.example/'),
        );
        await registry.install([original]);
        final before = persisted;
        final writesBeforeReplacement = writes;
        final replacement = RuleSourceDefinition.fromJson(
          _sourceJson(id: 'stable-source', baseUrl: 'https://second.example/'),
        );

        await expectLater(
          registry.install([replacement], replace: true),
          throwsA(isA<StateError>()),
        );

        expect(
          registry['stable-source']!.definition.baseUrl.host,
          'first.example',
        );
        expect(persisted, before);
        expect(writes, writesBeforeReplacement);

        // Removal retains book/history records outside this registry. Reusing
        // their stable source id for another origin would strand those records.
        await registry.remove('stable-source');
        expect(registry['stable-source'], isNull);
        final writesBeforeReinstall = writes;
        await expectLater(
          registry.install([replacement]),
          throwsA(isA<StateError>()),
        );
        expect(registry['stable-source'], isNull);
        expect(writes, writesBeforeReinstall);
      },
    );

    test(
      'a failed save leaves old rules installed and permits a later write',
      () async {
        var persisted = '';
        var failWrites = false;
        final registry = RuleSourceRegistry(
          read: () async => '',
          write: (raw) async {
            if (failWrites) throw StateError('fixture write failure');
            persisted = raw;
          },
        );
        addTearDown(registry.dispose);
        await registry.load(builtIns: []);
        final original = RuleSourceDefinition.fromJson(
          _sourceJson(id: 'atomic-source'),
        );
        await registry.install([original]);
        final savedBeforeFailure = persisted;
        failWrites = true;

        await expectLater(
          registry.install([
            original.withIdentity(name: '未保存的新名称'),
          ], replace: true),
          throwsA(isA<StateError>()),
        );

        expect(registry['atomic-source']!.definition.name, original.name);
        expect(persisted, savedBeforeFailure);
        failWrites = false;
        await registry.rename('atomic-source', '恢复写入');
        expect(registry['atomic-source']!.definition.name, '恢复写入');
        expect(
          jsonDecode(
            persisted,
          )['entries'].single['definition']['source']['name'],
          '恢复写入',
        );
      },
    );

    test(
      'serializes concurrent install, rename, and enable changes in call order',
      () async {
        final releaseFirstWrite = Completer<void>();
        final firstWriteStarted = Completer<void>();
        final snapshots = <Map<String, dynamic>>[];
        final registry = RuleSourceRegistry(
          read: () async => '',
          write: (raw) async {
            snapshots.add(Map<String, dynamic>.from(jsonDecode(raw) as Map));
            if (snapshots.length == 1) {
              firstWriteStarted.complete();
              await releaseFirstWrite.future;
            }
          },
        );
        addTearDown(registry.dispose);
        await registry.load(builtIns: []);

        final install = registry.install([
          RuleSourceDefinition.fromJson(_sourceJson(id: 'ordered-source')),
        ]);
        await firstWriteStarted.future.timeout(const Duration(seconds: 2));
        final rename = registry.rename('ordered-source', '已改名');
        final disable = registry.setEnabled('ordered-source', false);
        releaseFirstWrite.complete();
        await Future.wait([install, rename, disable]);

        Map<String, dynamic> persistedEntry(Map<String, dynamic> snapshot) =>
            Map<String, dynamic>.from(
              (snapshot['entries'] as List).single as Map,
            );
        final first = persistedEntry(snapshots[0]);
        final second = persistedEntry(snapshots[1]);
        final third = persistedEntry(snapshots[2]);
        expect(snapshots, hasLength(3));
        expect(first['definition']['source']['name'], 'ordered-source');
        expect(first['enabled'], isTrue);
        expect(second['definition']['source']['name'], '已改名');
        expect(second['enabled'], isTrue);
        expect(third['definition']['source']['name'], '已改名');
        expect(third['enabled'], isFalse);
      },
    );

    test(
      'disable and removal preserve deterministic book ids across reloads',
      () async {
        var persisted = '';
        final definition = RuleSourceDefinition.fromJson(
          _sourceJson(id: 'retained-source'),
        );
        final first = RuleSourceRegistry(
          read: () async => '',
          write: (raw) async {
            persisted = raw;
          },
        );
        addTearDown(first.dispose);
        await first.load(builtIns: []);
        await first.install([definition]);
        await first.setEnabled(definition.id, false);
        final originalBookUrl = 'https://fixture.example/book/42';
        final originalBookId = ruleBookId(definition.id, originalBookUrl);

        final reloaded = RuleSourceRegistry(
          read: () async => persisted,
          write: (raw) async {
            persisted = raw;
          },
        );
        addTearDown(reloaded.dispose);
        await reloaded.load(builtIns: []);
        expect(reloaded[definition.id]?.enabled, isFalse);
        expect(
          reloaded[definition.id]?.definition.toJson(),
          definition.toJson(),
        );
        expect(sourceOf(originalBookId).ruleId, definition.id);

        await reloaded.remove(definition.id);
        final afterRemoval = RuleSourceRegistry(
          read: () async => persisted,
          write: (_) async {},
        );
        addTearDown(afterRemoval.dispose);
        await afterRemoval.load(builtIns: []);
        expect(afterRemoval[definition.id], isNull);
        expect(ruleBookId(definition.id, originalBookUrl), originalBookId);
        expect(sourceOf(originalBookId).ruleId, definition.id);
      },
    );

    test('persists removal of a bundled rule over the next load', () async {
      var persisted = '';
      final builtIn = _sourceJson(id: 'bundled-source');
      final registry = RuleSourceRegistry(
        read: () async => '',
        write: (raw) async {
          persisted = raw;
        },
      );
      addTearDown(registry.dispose);
      await registry.load(builtIns: [builtIn]);
      expect(registry['bundled-source']?.builtIn, isTrue);
      await registry.remove('bundled-source');

      final reloaded = RuleSourceRegistry(
        read: () async => persisted,
        write: (_) async {},
      );
      addTearDown(reloaded.dispose);
      await reloaded.load(builtIns: [builtIn]);

      expect(reloaded['bundled-source'], isNull);
      expect(
        jsonDecode(persisted)['removedBuiltIns'],
        contains('bundled-source'),
      );
    });
  });

  group('rule book source integration', () {
    test(
      'isolates identical book URLs and refuses unsupported source prefixes',
      () {
        const url = 'https://fixture.example/books/shared';
        final first = ruleBookId('source-a', url);
        final second = ruleBookId('source-b', url);

        expect(first, isNot(second));
        expect(ruleBookUrl(first, 'source-a'), url);
        expect(ruleBookUrl(second, 'source-b'), url);
        expect(() => ruleBookUrl(first, 'source-b'), throwsFormatException);
        expect(() => sourceOf('unknown:42'), throwsFormatException);
        expect(sourceOf('legacy-number-42'), SourceId.wenku8);
      },
    );

    test(
      'maps fixture discovery, detail, catalog, images, and paragraph text',
      () async {
        final definition = RuleSourceDefinition.fromJson(
          _sourceJson(id: 'adapter-source'),
        );
        final transport = _FixtureTransport((uri) async {
          switch (uri.path) {
            case '/discover':
              return _html('''
              <article class="book">
                <a class="detail" href="/book/1"><b class="title">星海物语</b></a>
                <img class="cover" src="/images/cover.jpg">
                <span class="author">作者甲</span>
              </article>
            ''');
            case '/book/1':
              return _html('''
              <h1>星海物语</h1><span class="author">作者甲</span>
              <img class="cover" src="/images/cover.jpg">
              <p class="intro">跨页冒险</p><a class="toc" href="/toc/1">目录</a>
            ''');
            case '/toc/1':
              return _html('''
              <li class="chapter"><a href="/chapter/1">第一章</a></li>
            ''');
            case '/chapter/1':
              return _html('''
              <div id="reader"><p>第一段</p><p>第二段<img src="../images/page-1.jpg"></p>
                <script>ignored()</script></div>
            ''');
            default:
              return _notFound();
          }
        });
        final adapter = RuleBookSource(
          definition,
          engine: RuleSourceEngine(definition, transport: transport),
        );

        final home = await adapter.discover();
        expect(home.single.title, 'adapter-source');
        expect(home.single.list.single.title, '星海物语');
        expect(
          home.single.list.single.img,
          'https://fixture.example/images/cover.jpg',
        );
        final bookId = home.single.list.single.aid;
        expect(sourceOf(bookId).ruleId, 'adapter-source');

        final detail = await adapter.detail(bookId);
        expect(detail.info.title, '星海物语');
        expect(detail.info.author, '作者甲');
        expect(detail.info.imgUrl, 'https://fixture.example/images/cover.jpg');
        expect(detail.volumes.single.chapters.single.title, '第一章');
        final chapter = detail.volumes.single.chapters.single;
        expect(chapter.url, 'https://fixture.example/chapter/1');
        expect(chapter.cid, ruleBookId('adapter-source', chapter.url));

        final reader = await adapter.chapter(bookId, chapter.cid);
        expect(reader.content.split('\n').take(2), ['第一段', '第二段']);
        expect(
          reader.content,
          contains(
            '<!--image-->https://fixture.example/images/page-1.jpg<!--image-->',
          ),
        );
        expect(reader.content, isNot(contains('ignored')));
        expect(transport.visited.map((uri) => uri.path), [
          '/discover',
          '/book/1',
          '/toc/1',
          '/chapter/1',
        ]);
      },
    );

    test(
      'keeps search next-page cache separate for interleaved queries',
      () async {
        final definition = RuleSourceDefinition.fromJson(
          _sourceJson(id: 'paging-source'),
        );
        final transport = _FixtureTransport((uri) async {
          final query = uri.queryParameters['q']!;
          final page = uri.queryParameters['page']!;
          if (page == '1') {
            return _html('''
            <article class="book"><a class="detail" href="/book/$query">
              <b class="title">$query-第一页</b></a></article>
            <a class="next" href="/search?q=$query&amp;page=2">下一页</a>
          ''');
          }
          return _html('''
          <article class="book"><a class="detail" href="/book/$query">
            <b class="title">$query-第二页</b></a></article>
        ''');
        });
        final adapter = RuleBookSource(
          definition,
          engine: RuleSourceEngine(definition, transport: transport),
        );

        final alphaFirst = await adapter.search('alpha', 'title', 1);
        final betaFirst = await adapter.search('beta', 'title', 1);
        final alphaSecond = await adapter.search('alpha', 'title', 2);
        final betaSecond = await adapter.search('beta', 'title', 2);

        expect(alphaFirst.records.single.title, 'alpha-第一页');
        expect(betaFirst.records.single.title, 'beta-第一页');
        expect(alphaSecond.records.single.title, 'alpha-第二页');
        expect(betaSecond.records.single.title, 'beta-第二页');
        expect(transport.visited.map((uri) => uri.queryParameters['q']), [
          'alpha',
          'beta',
          'alpha',
          'beta',
        ]);
        expect(transport.visited.map((uri) => uri.queryParameters['page']), [
          '1',
          '1',
          '2',
          '2',
        ]);
      },
    );

    test('catalog pagination cycle is surfaced through the adapter', () async {
      final definition = RuleSourceDefinition.fromJson(
        _sourceJson(id: 'cycle-source'),
      );
      final transport = _FixtureTransport((uri) async {
        if (uri.path == '/book/1') {
          return _html('<h1>循环目录</h1><a class="toc" href="/toc/1">目录</a>');
        }
        if (uri.path == '/toc/1') {
          final page = uri.queryParameters['page'];
          final next = switch (page) {
            null => '?page=2',
            '2' => '?page=3',
            _ => '?page=2',
          };
          return _html('''
            <li class="chapter"><a href="/chapter/${page ?? '1'}">页$page</a></li>
            <a class="next" href="$next">下一页</a>
          ''');
        }
        return _notFound();
      });
      final adapter = RuleBookSource(
        definition,
        engine: RuleSourceEngine(definition, transport: transport),
      );

      await expectLater(
        adapter.detail(
          ruleBookId('cycle-source', 'https://fixture.example/book/1'),
        ),
        throwsA(isA<RuleSourcePaginationException>()),
      );
      expect(
        transport.visited.where((uri) => uri.path == '/toc/1'),
        hasLength(3),
      );
    });
  });
}

Map<String, dynamic> _sourceJson({
  required String id,
  String? name,
  String baseUrl = 'https://fixture.example/',
}) => {
  'schema': 'litetale-rule-source',
  'schemaVersion': 1,
  'source': {'id': id, 'name': name ?? id, 'baseUrl': baseUrl, 'version': '1'},
  'rules': {
    'discover': {
      'url': '/discover?page={{page}}',
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
    },
    'search': {
      'url': '/search?q={{query}}&page={{page}}',
      'items': {
        'selector': 'css:article.book',
        'fields': {
          'title': {'selector': 'css:b.title', 'value': 'text'},
          'detailUrl': {
            'selector': 'css:a.detail',
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
    'detail': {
      'url': '{{bookUrl}}',
      'fields': {
        'title': {'selector': 'css:h1', 'value': 'text'},
        'author': {'selector': 'css:.author', 'value': 'text'},
        'coverUrl': {
          'selector': 'css:img.cover',
          'value': 'attr',
          'attribute': 'src',
        },
        'description': {'selector': 'css:.intro', 'value': 'text'},
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
          'id': {'selector': 'css:a', 'value': 'attr', 'attribute': 'href'},
          'title': {'selector': 'css:a', 'value': 'text'},
          'url': {'selector': 'css:a', 'value': 'attr', 'attribute': 'href'},
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
    },
  },
};

RuleSourceHttpResponse _html(String body) => RuleSourceHttpResponse(
  statusCode: 200,
  headers: const {'content-type': 'text/html; charset=utf-8'},
  bytes: Uint8List.fromList(utf8.encode(body)),
);

RuleSourceHttpResponse _notFound() => RuleSourceHttpResponse(
  statusCode: 404,
  headers: const {},
  bytes: Uint8List(0),
);

class _FixtureTransport implements RuleSourceTransport {
  _FixtureTransport(this.handler);

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
