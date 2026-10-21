import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'paginated_reader_requests_test.dart' as fixture;

const bookId =
    'epub:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const volumes = [
  Volume(
    id: 'local',
    title: '本地书',
    chapters: [
      Chapter(title: '甲', url: '', aid: bookId, cid: 'a'),
      Chapter(title: '乙', url: '', aid: bookId, cid: 'b'),
      Chapter(title: '丙', url: '', aid: bookId, cid: 'c'),
      Chapter(title: '丁', url: '', aid: bookId, cid: 'd'),
    ],
  ),
];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final view = binding.platformDispatcher.views.first;
  test(
    'local turns cross chapters without Loading and save chapter-local progress',
    () async {
      view.physicalSize = const Size(1200, 800);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      final cubit = fixture.reader(
        ({required aid, required cid}) async {
          final doc = ReaderDocument([
            ReaderBlock(runs: [ReaderRun('正文$cid')]),
          ]);
          return SourceChapter(doc.content, document: doc);
        },
        queue,
        bookId: bookId,
        chapterVolumes: volumes,
      );
      final states = <ReaderState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.loadChapter();
      await Future<void>.delayed(Duration.zero);
      var state = cubit.state as ReaderLoaded;
      expect(state.pages.map((p) => p.chapterId), ['a', 'b', 'c', 'd']);
      expect(state.layout.isSpread, isTrue);
      final key = state.presentationKey;
      // A spread may contain the last page of one section and the next section.
      expect(state.pages[0].chapterId, 'a');
      expect(state.pages[1].chapterId, 'b');
      cubit.onPageChanged(2);
      await queue.flush();
      expect(saved.last.chapterId, 'c');
      expect(saved.last.page, 0);
      expect(saved.last.characters, 0);
      expect(saved.last.position!.textOffset, 0);
      state = cubit.state as ReaderLoaded;
      expect(state.presentationKey, same(key));
      view.physicalSize = const Size(800, 1200);
      await cubit.reloadCurrentPage();
      state = cubit.state as ReaderLoaded;
      expect(state.cid, 'c');
      expect(state.pages[state.currentPageIndex].chapterId, 'c');
      expect(states.whereType<ReaderLoading>(), hasLength(1));
      await sub.cancel();
      await cubit.close();
    },
  );

  test('paging during local reflow retains the latest text anchor', () async {
    view.physicalSize = const Size(400, 600);
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
    final gate = Completer<SourceChapter>();
    final reads = <String>[];
    final doc = ReaderDocument([
      for (var i = 0; i < 700; i++)
        ReaderBlock(runs: [ReaderRun('段落$i，沿着海岸向下一座城市出发。' * 3)]),
    ]);
    final queue = ReadingProgressQueue(write: (_) async {});
    final cubit = fixture.reader(
      ({required aid, required cid}) {
        reads.add(cid);
        return cid == 'a'
            ? Future.value(SourceChapter(doc.content, document: doc))
            : gate.future;
      },
      queue,
      bookId: bookId,
      chapterVolumes: volumes,
    );
    await cubit.loadChapter();
    var loaded = cubit.state as ReaderLoaded;
    expect(loaded.pages.length, 64);
    expect(reads, ['a']);
    cubit.onPageChanged(2);
    view.physicalSize = const Size(1000, 1200);
    final pending = cubit.reloadCurrentPage();
    // Reflow reshapes cached local content, then may wait for a new neighbour.
    await Future<void>.delayed(Duration.zero);
    cubit.onPageChanged(5);
    loaded = cubit.state as ReaderLoaded;
    final offset = loaded.pages[5].textStart!;
    gate.complete(const SourceChapter('邻章'));
    await pending;
    final after = cubit.state as ReaderLoaded;
    expect(after.cid, 'a');
    final page = after.pages[after.currentPageIndex];
    expect(page.textStart, lessThanOrEqualTo(offset));
    expect(page.textEnd, greaterThan(offset));
    await cubit.close();
  });
}
