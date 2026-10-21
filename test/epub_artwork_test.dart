import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:wild/models/reader_document.dart';
import 'package:wild/services/epub/epub_artwork_document.dart';
import 'package:wild/services/epub/epub_artwork_renderer.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/epub_parser.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/reader_rich_paginator.dart';
import 'support/epub_fixture.dart';

void main() {
  Uint8List bytes({
    String body = '<p class="rot">自行编写的彩色扉页</p>',
    String css = '.rot {transform:rotate(90deg);color:#55b482}',
    String title = '扉页',
    String file = 'title.xhtml',
    Map<String, Uint8List> resources = const {},
  }) => buildEpubFixture(
    chapters: [
      EpubFixtureChapter(
        path: file,
        title: title,
        body: '<style>$css</style>$body',
      ),
      const EpubFixtureChapter(
        path: 'prose.xhtml',
        title: '第一章',
        body: '<p>正文保持阅读器字体。</p>',
      ),
    ],
    resources: resources,
  );

  test('used floats, rotations, colors and local font survive sanitizing', () {
    final font = Uint8List.fromList([0, 1, 0, 0, ...List.filled(16, 0)]);
    final book = parseEpubBook(
      bytes(
        css:
            '@font-face{font-family:art;src:url("fonts/design.ttf")}'
            '.title{font-family:art}.left{float:left}.rot{transform:rotate(90deg)}',
        body:
            '<div class="title"><div class="left">标题</div>'
            '<p class="rot" style="color:#DCBE00;margin:1em -2em">作者</p></div>',
        resources: {'fonts/design.ttf': font},
      ),
    );
    final output = book.chapters.first.artwork!.html;
    for (final value in [
      'float:left',
      'rotate(90deg)',
      'margin:1em -2em',
      'data:font/ttf;base64,',
    ]) {
      expect(output, contains(value));
    }
    expect(book.chapters.last.artwork, isNull);
    expect(book.chapters.first.content, contains('标题'));
    expect(output, contains('li{line-height:1.55em!important;}'));
    expect(output, contains('data-litetale-title-typography="true"'));
    expect(output, contains('html{font-size:18px!important;}'));
    expect(
      output,
      contains('font-family:LiteTaleArtworkSerif,serif!important'),
    );
  });

  test('unused shared layout rules never rasterize ordinary prose', () {
    expect(
      parseEpubBook(
        bytes(
          title: '序章',
          file: 'one.xhtml',
          body: '<p>短序章还是正文。</p>',
          css:
              '.unused{float:left;transform:rotate(20deg)} p{font-family:serif}',
        ),
      ).chapters.first.artwork,
      isNull,
    );
  });

  test('used layout rules identify unnamed designed pages', () {
    expect(
      parseEpubBook(
        bytes(
          title: '角色',
          file: 'one.xhtml',
          body: '<p class="side">作者介绍</p>',
          css: '.side{float:right}',
        ),
      ).chapters.first.artwork,
      isNotNull,
    );
  });

  test('long prose and pure images retain native pagination', () {
    expect(
      parseEpubBook(
        bytes(body: '<p>${'正文' * 2000}</p>'),
      ).chapters.first.artwork,
      isNull,
    );
    final book = parseEpubBook(
      bytes(
        body: '<img src="cover.png" />',
        resources: {'cover.png': epubFixturePng()},
      ),
    );
    expect(book.chapters.first.artwork, isNull);
    expect(book.chapters.first.document!.blocks.single.imageUrl, isNotNull);
  });

  test('scripts, navigation, handlers, forms and remote resources are absent', () {
    final output =
        parseEpubBook(
          bytes(
            css:
                '@import "https://outside.invalid/a.css";'
                '.rot{background:url(https://outside.invalid/leak);float:left}',
            body:
                '<base href="https://outside.invalid/">'
                '<script>window.evil=1</script><iframe src="https://outside.invalid/"></iframe>'
                '<form action="https://outside.invalid/"><input value="secret"></form>'
                '<p class="rot" onclick="alert(1)">标题</p>'
                '<a href="javascript:alert(1)">说明</a>'
                '<img src="file:///sdcard/private.png" onerror="alert(2)">',
          ),
        ).chapters.first.artwork!.html;
    final doc = html.parse(output);
    expect(doc.querySelector('script,iframe,form,input,base'), isNull);
    expect(doc.querySelectorAll('[onclick],[onerror],[href],[src]'), isEmpty);
    expect(output, isNot(contains('outside.invalid')));
    expect(output, isNot(contains('file:///')));
    expect(output, contains("script-src 'none'"));
  });

  test(
    'missing local font is optional and local() never uses external fonts',
    () {
      final output =
          parseEpubBook(
            bytes(
              css:
                  '@font-face{font-family:x;src:local("External"),url(missing.ttf)}',
            ),
          ).chapters.first.artwork!.html;
      expect(output, isNot(contains('local(')));
      expect(output, isNot(contains('missing.ttf')));
    },
  );

  test('offline CSS imports are bounded, cyclic imports terminate', () {
    final builder = EpubArtworkBuilder(
      resolve: (base, href) => href.contains('://') ? null : href,
      readCss:
          (path) =>
              path == 'a.css'
                  ? '@import "b.css"; .left{float:left}'
                  : '@import "a.css"; .left{color:red}',
      readResource: (_) => null,
    );
    final output =
        builder
            .build(
              html.parse(
                '<title>扉页</title>'
                '<link rel="stylesheet" href="a.css"><div class="left">标题</div>',
              ),
              'one',
            )!
            .html;
    expect(output, contains('color:red'));
    expect(output, contains('float:left'));
    expect(output, isNot(contains('@import')));
    expect(output.length, lessThan(4000));
  });

  final digest = 'a' * 64;
  final image = epubFixturePng();
  final name = '${sha256.convert(image)}.png';
  final url = epubAssetUrl(digest, name);
  ParsedEpubBook parsed({int count = 1}) => ParsedEpubBook(
    digest: digest,
    title: '测试设计',
    author: '作者',
    description: '',
    language: 'zh',
    subjects: [],
    assets: {},
    chapters: List.generate(count, (index) {
      final doc = ReaderDocument([
        ReaderBlock(runs: [ReaderRun('第$index页的原始文本')]),
      ]);
      return EpubChapterData(
        title: '扉页$index',
        href: '$index.xhtml',
        content: doc.content,
        document: doc,
        artwork: const EpubArtworkPage('<html><body>inert</body></html>'),
      );
    }),
  );

  test(
    'raster retains source text and positions, transient HTML is discarded',
    () async {
      final before = parsed();
      final result = await renderEpubArtwork(before, (_) async => image);
      final chapter = result.chapters.single;
      expect(chapter.content, before.chapters.single.content);
      expect(chapter.document!.content, chapter.content);
      expect(chapter.document!.blocks.single.artworkUrl, url);
      expect(chapter.artwork, isNull);
      expect(result.assets[name], image);
      expect(result.warnings, isEmpty);
    },
  );

  test(
    'failure keeps styled text and plugin absence is attempted once',
    () async {
      var calls = 0;
      final before = parsed(count: 3);
      final result = await renderEpubArtwork(before, (_) async {
        calls++;
        throw MissingPluginException();
      });
      expect(calls, 1);
      expect(result.chapters.length, 3);
      expect(
        result.chapters.first.document,
        same(before.chapters.first.document),
      );
      expect(result.chapters.every((c) => c.artwork == null), isTrue);
      expect(result.warnings.length, 1);
      expect(result.artworkNeedsRetry, isTrue);
    },
  );

  test(
    'bad images and oversized canvas cannot replace readable text',
    () async {
      final huge = Uint8List.fromList(image);
      ByteData.sublistView(huge).setUint32(16, 999999);
      for (final invalid in [Uint8List(12), huge]) {
        final result = await renderEpubArtwork(parsed(), (_) async => invalid);
        expect(result.assets, isEmpty);
        expect(
          result.chapters.single.document!.blocks.single.artworkUrl,
          isNull,
        );
      }
    },
  );

  test(
    'serialization retains source text and partial slicing returns plain text',
    () {
      final doc = ReaderDocument([
        ReaderBlock(runs: const [ReaderRun('原始标题')], artworkUrl: url),
      ]);
      final decoded = ReaderDocument.fromJson(
        jsonDecode(jsonEncode(doc.toJson())),
      );
      expect(decoded.content, '原始标题');
      expect(decoded.blocks.single.artworkUrl, url);
      expect(decoded.slice(0, 4).blocks.single.artworkUrl, url);
      expect(decoded.slice(1, 3).content, '始标');
      expect(decoded.slice(1, 3).blocks.single.artworkUrl, isNull);
    },
  );

  test('artwork follows the owned image URL schema', () {
    final block =
        ReaderBlock(runs: const [ReaderRun('标题')], artworkUrl: url).toJson();
    for (final bad in [
      'file:///private/a.png',
      'https://example.org/a.png',
      'epub-asset:$digest/../b.png',
    ]) {
      expect(
        () => ReaderBlock.fromJson({...block, 'artwork': bad}),
        throwsFormatException,
      );
    }
    expect(
      () => ReaderBlock.fromJson({...block, 'image': url}),
      throwsFormatException,
    );
  });

  testWidgets('one artwork leaf retains next prose character offsets', (
    tester,
  ) async {
    final doc = ReaderDocument([
      ReaderBlock(runs: const [ReaderRun('原始标题')], artworkUrl: url),
      ReaderBlock(runs: const [ReaderRun('下一段正文')]),
    ]);
    final pages = paginateReaderDocument(
      document: doc,
      width: 300,
      height: 500,
      style: const TextStyle(fontSize: 18),
      textScaler: TextScaler.noScaling,
      paragraphSpacing: 10,
    );
    expect(pages.length, 2);
    expect(pages.first.isImage, isTrue);
    expect(pages.first.artworkText, '原始标题');
    expect(pages.first.textEnd, 4);
    expect(pages.last.textStart, 5);
  });

  test(
    'import persists artwork through normal ownership and restart',
    () async {
      final root = await Directory.systemTemp.createTemp('lt_artwork_');
      final library = LocalEpubLibrary(
        useIsolates: false,
        rasterizeArtwork: (_) async => image,
      );
      final input = bytes();
      try {
        await library.initialize(root.path);
        final book =
            (await library.importFile(
              XFile.fromData(input, path: 'art.epub'),
            )).book;
        final chapter = await library.chapterData(book.id, book.chapterId(0));
        expect(chapter.document!.content, chapter.content);
        expect(chapter.document!.blocks.single.artworkUrl, isNotNull);
        expect(book.styleRevision, currentEpubStyleRevision);
        final restarted = LocalEpubLibrary(useIsolates: false);
        await restarted.initialize(root.path);
        final restored = await restarted.chapterData(
          book.id,
          book.chapterId(0),
        );
        expect(restored.document!.toJson(), chapter.document!.toJson());
        expect(
          (await library.importFile(
            XFile.fromData(input, path: 'art.epub'),
          )).alreadyImported,
          isTrue,
        );
        await library.remove(book.id);
      } finally {
        final local = Directory('${root.path}/local_epub');
        if (await local.exists() && await local.list().isEmpty) {
          await local.delete();
        }
        if (await root.list().isEmpty) await root.delete();
      }
    },
  );
}
