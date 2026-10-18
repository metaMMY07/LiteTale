import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/local_epub_library_page.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/local_epub_source.dart';
import 'package:wild/sources/source_api.dart' as api;

import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalEpubLibrary library;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'litetale_epub_integration_',
    );
    library = LocalEpubLibrary(useIsolates: false);
    await library.initialize(directory.path);
  });
  tearDown(() async {
    library.dispose();
    final entries =
        await directory.list(recursive: true, followLinks: false).toList();
    for (final entity in entries.where((e) => e is File || e is Link)) {
      await entity.delete();
    }
    for (final folder
        in entries.whereType<Directory>().toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length))) {
      await folder.delete();
    }
    await directory.delete();
  });

  Future<LocalEpubBook> import({
    bool illustrated = false,
    String title = '远行日记',
  }) async {
    final bytes = buildEpubFixture(
      title: title,
      description: '这是 <本地> & 安静的故事。',
      chapters: [
        EpubFixtureChapter(
          path: 'Text/z.xhtml',
          title: '序章',
          body:
              '<h1>序章</h1><p>第一页正文。</p>${illustrated ? '<img src="../Images/light.png"/>' : ''}',
        ),
        const EpubFixtureChapter(
          path: 'Text/a.xhtml',
          title: '第二章',
          body: '<h1>第二章</h1><p>故事继续了。</p>',
        ),
      ],
      resources: illustrated ? {'Images/light.png': epubFixturePng()} : {},
    );
    return (await library.importFile(
      XFile.fromData(bytes, path: '$title.epub'),
    )).book;
  }

  test(
    'local IDs and adapter cannot change online source or reach search',
    () async {
      final book = await import();
      final previous = activeSource.value;
      final source = LocalEpubSource(library: library);
      final detail = await source.detail(book.id);
      expect(sourceOf(book.id), SourceId.localEpub);
      expect(api.availableSources, isNot(contains(SourceId.localEpub)));
      expect(activeSource.value, previous);
      expect(() => sourceOf('epub:not-a-digest'), throwsFormatException);
      expect(detail.info.introduce, contains('&lt;本地&gt; &amp;'));
      final chapters = detail.volumes.single.chapters;
      expect(chapters.map((c) => c.title), ['序章', '第二章']);
      expect(chapters.every((c) => c.aid == book.id), isTrue);
      expect(
        (await source.chapter(book.id, chapters[1].cid)).content,
        contains('故事继续了'),
      );
      await expectLater(
        source.search('test', 'articlename', 1),
        throwsA(isA<EpubImportException>()),
      );
    },
  );

  test(
    'EPUB illustration enters existing paginated reader as a local image page',
    () async {
      final book = await import(illustrated: true);
      final chapter = await LocalEpubSource(
        library: library,
      ).chapter(book.id, book.chapterId(0));
      final pages = paginateReaderContent(
        content: chapter.content,
        canvasWidth: 300,
        canvasHeight: 450,
        fontSize: 20,
        paragraphSpacing: 8,
        lineHeight: 1.5,
        fontFamily: 'LXGWNeoZhiSongPlus',
      );
      final image = pages.singleWhere((page) => page.isImage);
      expect(image.content, startsWith('epub-asset:${book.digest}/'));
      expect(await library.readAsset(image.content), epubFixturePng());
      expect(
        pages.where((p) => !p.isImage).map((p) => p.content).join(),
        contains('第一页正文'),
      );
    },
  );

  testWidgets('empty local library remains usable on a narrow short screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: LocalEpubLibraryPage(library: library)),
    );
    await tester.pumpAndSettle();
    expect(find.text('本地书籍'), findsOneWidget);
    expect(find.text('导入 EPUB'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'local search and open use imported metadata and stable book ID',
    (tester) async {
      final book = (await tester.runAsync(() => import()))!;
      await tester.runAsync(() => import(title: '海边来信'));
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: LocalEpubLibraryPage(library: library),
          onGenerateRoute: (settings) {
            if (settings.name == '/novel/info') {
              opened = settings.arguments as String;
              return MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('本地目录')),
              );
            }
            return null;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '远行');
      await tester.pumpAndSettle();
      expect(find.text('海边来信'), findsNothing);
      await tester.tap(find.text('远行日记'));
      await tester.pumpAndSettle();
      expect(opened, book.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
