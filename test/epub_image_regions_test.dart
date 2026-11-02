import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/epub_css_reader.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('litetale/epub_pages');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'CSS illustration points to original asset, caches regions, rejects deleted book',
    () async {
      final root = await Directory.systemTemp.createTemp('image_regions_');
      final library = LocalEpubLibrary(useIsolates: false);
      await library.initialize(root.path);
      final book =
          (await library.importFile(
            XFile.fromData(
              buildEpubFixture(
                chapters: const [
                  EpubFixtureChapter(
                    path: 'Text/chapter.xhtml',
                    title: '图片',
                    body: '<p>A picture</p><img src="../Images/figure.png"/>',
                  ),
                ],
                resources: {'Images/figure.png': epubFixturePng()},
              ),
              path: 'images.epub',
            ),
          )).book;
      final doc = await library.publication(book.id, book.chapterId(0));
      final resource = doc.resources.keys.firstWhere((k) => k.endsWith('.png'));
      var queries = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepare') {
          return {
            'count': 1,
            'text': 'A picture',
            'textLength': 9,
            'ranges': [
              {'start': 0, 'end': 9},
            ],
            'imageCount': 1,
          };
        }
        if (call.method == 'images') {
          queries++;
          return [
            {
              'resource': resource,
              'rect': [.1, .2, .6, .8],
            },
          ];
        }
        return null;
      });
      final reader = EpubCssReader(library: library);
      try {
        final pages = await reader.paginate(
          book: book.id,
          chapter: book.chapterId(0),
          content: 'A picture',
          options: {'width': 640},
        );
        final first = await pages.first.cssPage!.readImages!();
        final again = await pages.first.cssPage!.readImages!();
        expect(queries, 1);
        expect(first, same(again));
        expect(first.single.rect.left, .1);
        expect(await first.single.read(), epubFixturePng());
        await library.remove(book.id);
        await expectLater(first.single.read(), throwsStateError);
      } finally {
        reader.close();
        await EpubCssReader.clearUnusedCache();
        messenger.setMockMethodCallHandler(channel, null);
        // Test artifacts are retained; no recursive filesystem deletion.
      }
    },
  );
  test('out-of-leaf regions and external resources are not accepted', () async {
    final root = await Directory.systemTemp.createTemp(
      'invalid_image_regions_',
    );
    final library = LocalEpubLibrary(useIsolates: false);
    await library.initialize(root.path);
    final book =
        (await library.importFile(
          XFile.fromData(buildEpubFixture(), path: 'test.epub'),
        )).book;
    var external = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'prepare') {
        return {
          'count': 1,
          'text': 'abc',
          'textLength': 3,
          'ranges': [
            {'start': 0, 'end': 3},
          ],
          'imageCount': 1,
        };
      }
      if (call.method == 'images') {
        return [
          {
            'resource':
                external ? 'https://example.org/x.png' : '${'a' * 64}.png',
            'rect': [-1, .2, .5, .5],
          },
        ];
      }
      return null;
    });
    final reader = EpubCssReader(library: library);
    try {
      final pages = await reader.paginate(
        book: book.id,
        chapter: book.chapterId(0),
        content: 'abc',
        options: {'width': 640},
      );
      await expectLater(pages.first.cssPage!.readImages!(), throwsStateError);
      external = false;
      await expectLater(pages.first.cssPage!.readImages!(), throwsStateError);
    } finally {
      reader.close();
      await EpubCssReader.clearUnusedCache();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
