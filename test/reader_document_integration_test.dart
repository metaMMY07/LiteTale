import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/pages/novel/html_reader_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/sources/book_source.dart';

import 'paginated_reader_requests_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ReaderDocument story() => ReaderDocument([
    ReaderBlock(
      runs: const [
        ReaderRun(
          'A centered title',
          style: ReaderInlineStyle(bold: true, scale: 1.5),
        ),
      ],
      style: const ReaderBlockStyle(align: 'center'),
    ),
    ReaderBlock(
      runs: [
        ReaderRun(
          '正文与 styles. ' * 100,
          style: const ReaderInlineStyle(italic: true, underline: true),
        ),
      ],
      style: const ReaderBlockStyle(indent: ReaderLength(em: 2)),
    ),
  ]);

  testWidgets(
    'native reader retains paired styles during cached reflow without another request',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final doc = story();
      var requests = 0;
      final queue = ReadingProgressQueue(write: (_) async {});
      final cubit = fixture.reader(({required aid, required cid}) async {
        requests++;
        return SourceChapter(doc.content, document: doc);
      }, queue);
      await cubit.loadChapter();
      final first = cubit.state as ReaderLoaded;
      expect(first.pages.first.fragments!.first.block.style.align, 'center');
      cubit.onPageChanged(1);
      tester.view.physicalSize = const Size(600, 800);
      await cubit.reloadCurrentPage();
      final reflowed = cubit.state as ReaderLoaded;
      expect(requests, 1);
      expect(
        reflowed.pages.expand((p) => p.fragments!).map((f) => f.text).join(),
        doc.blocks.map((b) => b.text).join(),
      );
      expect(
        reflowed.pages.last.fragments!.last.block.runs.single.style.italic,
        isTrue,
      );
      await cubit.close();
    },
  );

  test(
    'scroll reader receives original style blocks instead of flattened text',
    () async {
      final doc = story();
      final queue = ReadingProgressQueue(write: (_) async {});
      final cubit = HtmlReaderCubit(
        novelInfo: fixture.info,
        initialAid: 'lns:1',
        initialCid: 'a',
        initialVolumes: fixture.volumes,
        read:
            ({required aid, required cid}) async =>
                SourceChapter(doc.content, document: doc),
        sessionGeneration: (_) => 0,
        progress: queue,
      );
      await cubit.loadChapter();
      final loaded = cubit.state as HtmlReaderLoaded;
      final blocks =
          loaded.parsedContent.whereType<ParsedStyledText>().toList();
      expect(blocks.length, 2);
      expect(blocks.first.block.style.align, 'center');
      expect(blocks.last.block.runs.single.style.underline, isTrue);
      expect(blocks.last.block.text, doc.blocks.last.text);
      await cubit.close();
    },
  );

  testWidgets(
    'reopening a consecutive illustration restores its ordinal after reflow',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final doc = ReaderDocument([
        ReaderBlock(runs: [ReaderRun('文本 before the illustration. ' * 120)]),
        ReaderBlock(imageUrl: 'image-1'),
        ReaderBlock(imageUrl: 'image-2'),
        ReaderBlock(runs: const [ReaderRun('After the two images.')]),
      ]);
      final saved = <ReadingProgress>[];
      final firstQueue = ReadingProgressQueue(write: (p) async => saved.add(p));
      Future<SourceChapter> read({
        required String aid,
        required String cid,
      }) async => SourceChapter(doc.content, document: doc);
      final first = fixture.reader(read, firstQueue);
      await first.loadChapter();
      final oldPages = (first.state as ReaderLoaded).pages;
      final imageIndex = oldPages.indexWhere(
        (p) => p.isImage && p.content == 'image-2',
      );
      first.onPageChanged(imageIndex);
      await firstQueue.flush();
      final anchor = saved.last.position!;
      expect(anchor.onImage, isTrue);
      expect(anchor.precedingImages, 1);
      await first.close();
      tester.view.physicalSize = const Size(500, 900);
      final reopened = fixture.reader(
        read,
        ReadingProgressQueue(write: (_) async {}),
        loadPosition: (_, _) async => anchor,
      );
      await reopened.loadChapter(
        initialPage: imageIndex,
        initialTextOffset: anchor.textOffset,
      );
      final loaded = reopened.state as ReaderLoaded;
      expect(loaded.pages[loaded.currentPageIndex].content, 'image-2');
      expect(
        ReaderPosition.at(
          loaded.pages,
          loaded.currentPageIndex,
        ).precedingImages,
        1,
      );
      await reopened.close();
    },
  );
}
