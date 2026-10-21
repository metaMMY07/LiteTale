import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:wild/services/epub/epub_css_reader.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/epub_parser.dart';
import 'package:wild/services/epub/epub_publication_document.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/epub_reader_position.dart';
import 'package:wild/services/reader_position.dart';
import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'original CSS variables, nested imports, font URLs, SVG and ruby survive inert conversion',
    () {
      final files = <String, Uint8List>{
        'OPS/main.css': Uint8List.fromList(
          utf8.encode(
            '@import "nested.css" screen; :root{--ink:green}p{color:var(--ink)}',
          ),
        ),
        'OPS/nested.css': Uint8List.fromList(
          utf8.encode('@font-face{font-family:Book;src:url(font.ttf)}'),
        ),
        'OPS/font.ttf': Uint8List(32),
        'OPS/image.png': epubFixturePng(),
      };
      final builder = EpubPublicationBuilder(
        resolve: (base, href) => Uri.parse(base).resolve(href).path,
        read: (path) => files[path],
      );
      final result = builder.build(
        html.parse(
          '''<html class="hltr"><head><link rel="stylesheet" href="main.css"></head>
      <body onload="alert(1)"><script>bad()</script><iframe src="https://example.com"></iframe>
      <p><ruby>字<rt>zi</rt></ruby></p><svg viewBox="0 0 100 200" xmlns:xlink="http://www.w3.org/1999/xlink">
      <image xlink:href="image.png" onerror="bad()"/></svg></body></html>''',
        ),
        'OPS/chapter.xhtml',
        fixedLayout: true,
      );
      expect(result.html, contains('class="hltr"'));
      expect(result.html, contains('--ink:green'));
      expect(result.html, contains('var(--ink)'));
      expect(result.html, contains('@media screen'));
      expect(result.html, contains('<rt>zi</rt>'));
      expect(result.html, contains('viewBox="0 0 100 200"'));
      expect(result.resources.length, 2);
      final doc = html.parse(result.html);
      expect(
        doc.querySelector('image')!.attributes['href'],
        startsWith('https://litetale-epub.invalid/resource/'),
      );
      expect(
        doc.querySelector('style')!.text,
        contains('src:url("https://litetale-epub.invalid/resource/'),
      );
      expect(doc.querySelectorAll('script,iframe'), isEmpty);
      expect(result.html, isNot(contains('onload=')));
      expect(result.html, isNot(contains('onerror=')));
      expect(result.html, contains("script-src 'none'"));
    },
  );

  test(
    'shared XHTML TOC sections keep ancestor CSS and exclude adjacent text',
    () {
      final bytes = buildEpubFixture(
        chapters: const [
          EpubFixtureChapter(
            path: 'text.xhtml',
            title: '全文',
            body:
                '<article class="book"><p>前言</p><section><h2 id="a">甲章</h2><p>甲文</p><h2 id="b">乙章</h2><p>乙文</p></section></article>',
          ),
        ],
        toc: const [
          EpubFixtureToc('甲', 'text.xhtml#a'),
          EpubFixtureToc('乙', 'text.xhtml#b'),
        ],
      );
      final result = readEpubPublication(
        bytes,
        'OPS/text.xhtml#a',
        endHref: 'OPS/text.xhtml#b',
      );
      final doc = html.parse(result.html);
      expect(doc.querySelector('article.book'), isNotNull);
      expect(doc.body!.text, contains('甲文'));
      expect(doc.body!.text, isNot(contains('前言')));
      expect(doc.body!.text, isNot(contains('乙文')));
    },
  );

  test('remote resource references cannot enter the offline asset map', () {
    final bytes = buildEpubFixture(
      chapters: const [
        EpubFixtureChapter(
          path: 't.xhtml',
          title: '测试',
          body:
              '<style>p{background:url(https://example.com/p.png)}</style><p style="background:url(file:///secret)">文字</p><img src="https://example.com/x.jpg"/>',
        ),
      ],
    );
    final result = readEpubPublication(bytes, 'OPS/t.xhtml');
    expect(result.resources, isEmpty);
    expect(result.html, isNot(contains('example.com')));
    expect(result.html, isNot(contains('file:///secret')));
  });

  test(
    'schema3 owns the original archive after restart and rejects its tampering',
    () async {
      final root = await Directory.systemTemp.createTemp('epub_publication_');
      // Per-file cleanup only, as required by the workspace.
      final bytes = buildEpubFixture();
      final first = LocalEpubLibrary(useIsolates: false);
      await first.initialize(root.path);
      final imported = await first.importFile(
        XFile.fromData(bytes, path: 'local.epub'),
      );
      expect(imported.book.hasPublication, isTrue);
      final second = LocalEpubLibrary(useIsolates: false);
      await second.initialize(root.path);
      final doc = await second.publication(
        imported.book.id,
        imported.book.chapterId(0),
      );
      expect(doc.html, contains('这是自行编写的测试正文。'));
      final archive = File(
        '${root.path}/local_epub/${imported.book.digest}/publication.epub',
      );
      final damaged = Uint8List.fromList(bytes);
      damaged[0] ^= 1;
      await archive.writeAsBytes(damaged);
      final third = LocalEpubLibrary(useIsolates: false);
      await third.initialize(root.path);
      await expectLater(
        third.publication(imported.book.id, imported.book.chapterId(0)),
        throwsA(isA<EpubImportException>()),
      );
      await second.remove(imported.book.id);
      await Directory('${root.path}/local_epub').delete();
      await root.delete();
    },
  );

  test(
    'CSS pages capture lazily, coalesce bitmap reads and rebuild evicted native sessions once',
    () async {
      final root = await Directory.systemTemp.createTemp('epub_css_pages_');
      final library = LocalEpubLibrary(useIsolates: false);
      await library.initialize(root.path);
      final book =
          (await library.importFile(
            XFile.fromData(buildEpubFixture(), path: 'a.epub'),
          )).book;
      var prepares = 0, captures = 0;
      var evicted = false;
      const channel = MethodChannel('litetale/epub_pages');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepare') {
          prepares++;
          return {
            'count': 3,
            'textLength': 30,
            'text': '正文甲乙丙丁戊己庚辛壬癸一二三四五六七八九十阅读样式测试文本',
            'ranges': [
              {'start': 0, 'end': 12},
              {'start': 10, 'end': 23},
              {'start': 20, 'end': 30},
            ],
          };
        }
        if (call.method == 'capture') {
          captures++;
          if (evicted) {
            evicted = false;
            throw PlatformException(code: 'missing_session');
          }
          return epubFixturePng();
        }
        return null;
      });
      final reader = EpubCssReader(library: library);
      final pages = await reader.paginate(
        book: book.id,
        chapter: book.chapterId(0),
        content: '文本' * 15,
        options: const {'width': 640.0},
      );
      expect(prepares, 1);
      expect(captures, 0);
      expect(pages.first.cssPage!.semanticText, '正文甲乙丙丁戊己庚辛壬癸');
      await Future.wait([pages[0].cssPage!.read(), pages[0].cssPage!.read()]);
      expect(captures, 1);
      evicted = true;
      await pages[1].cssPage!.read();
      expect(prepares, 2);
      expect(captures, 3);
      expect(ReaderPosition.at(pages, 1).epubOffset, 10);
      expect(
        const ReaderPosition(0, 0, false, epubOffset: 10).pageIn(pages),
        1,
      );
      reader.close();
      await EpubCssReader.clearUnusedCache();
      await pumpEventQueue();
      await expectLater(
        Future.sync(() => pages[2].cssPage!.read()),
        throwsStateError,
      );
      messenger.setMockMethodCallHandler(channel, null);
      await library.remove(book.id);
      await Directory('${root.path}/local_epub').delete();
      await root.delete();
    },
  );

  test(
    'DOM anchor persists independently of legacy ruby/plaintext offsets',
    () async {
      var saved = '';
      final id = 'epub:${'a' * 64}';
      final store = EpubReaderPositionStore(
        readProperty: (_) async => saved,
        writeProperty: (_, value) async {
          saved = value;
        },
      );
      await store.write(
        id,
        '$id:c0',
        const ReaderPosition(17, 0, false, epubOffset: 25),
      );
      final restored = EpubReaderPositionStore(
        readProperty: (_) async => saved,
      );
      expect((await restored.read(id, '$id:c0'))!.epubOffset, 25);
      final bad = jsonDecode(saved) as Map;
      bad['epubOffset'] = -1;
      saved = jsonEncode(bad);
      expect(
        await EpubReaderPositionStore(
          readProperty: (_) async => saved,
        ).read(id, '$id:c0'),
        isNull,
      );
    },
  );
}
