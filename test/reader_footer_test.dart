import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/reader_footer.dart';

import 'paginated_reader_requests_test.dart' as fixture;

ReaderViewportLayout layout(Size size, {double scale = 1}) =>
    ReaderViewportLayout(
      size: size,
      systemPadding: const EdgeInsets.only(bottom: 20),
      leftPadding: 16,
      rightPadding: 16,
      topBarHeight: 24,
      bottomBarHeight: 0,
      textScaler: TextScaler.linear(scale),
    );

void main() {
  testWidgets(
    'footer occupies a reserved band and follows minute/resume time',
    (tester) async {
      const size = Size(400, 700);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final book = layout(size);
      var now = DateTime(2026, 11, 3, 15, 21, 59);
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ReaderFooter(
                  layout: book,
                  pageLabel: '本章 3/38',
                  color: Colors.black,
                  now: () => now,
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.text('15:21'), findsOneWidget);
      final clock = tester.getRect(find.byKey(const ValueKey('reader-clock')));
      final count = tester.getRect(
        find.byKey(const ValueKey('reader-page-number')),
      );
      expect(clock.left, 16);
      expect(count.right, size.width - 16);
      expect(clock.bottom, lessThanOrEqualTo(size.height - 32));
      final contentBottom =
          book.insets.top + book.headerHeight + book.contentHeight;
      expect(contentBottom, lessThan(clock.top));
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('15:22'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = DateTime(2026, 11, 3, 16, 6);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('16:06'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'footer remains separate at large font scaling and narrow widths',
    (tester) async {
      const size = Size(320, 560);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final book = layout(size, scale: 2);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ReaderFooter(
                    layout: book,
                    pageLabel: '本章 12–13/388',
                    color: Colors.white,
                    now: () => DateTime(2026, 11, 3, 23, 59),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-page-number')),
      );
      expect(
        rect.top,
        greaterThanOrEqualTo(book.insets.top + book.contentHeight),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'online footer counts laid-out chapter leaves including spreads',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cubit = fixture.reader(
        ({required aid, required cid}) async => SourceChapter('正文。' * 6000),
        ReadingProgressQueue(write: (_) async {}),
      );
      await cubit.loadChapter();
      final state = cubit.state as ReaderLoaded;
      expect(cubit.footerPageLabel, '本章 1–2/${state.pages.length}');
      cubit.onPageChanged(state.pages.length - 1);
      final first = (state.pages.length - 1) ~/ 2 * 2 + 1;
      expect(
        cubit.footerPageLabel,
        state.pages.length.isOdd
            ? '本章 $first/${state.pages.length}'
            : '本章 $first–${state.pages.length}/${state.pages.length}',
      );
      await cubit.close();
    },
  );

  testWidgets(
    'local footer uses the whole chapter, not its truncated preload window',
    (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final id = 'epub:${'a' * 64}';
      final cubit = fixture.reader(
        ({required aid, required cid}) async =>
            SourceChapter(List.filled(200, '正文。' * 80).join('\n')),
        ReadingProgressQueue(write: (_) async {}),
        bookId: id,
        chapterVolumes: [
          Volume(
            id: 'v',
            title: '卷',
            chapters: [Chapter(aid: id, cid: 'a', title: '章', url: '')],
          ),
        ],
      );
      await cubit.loadChapter(initialPage: 40);
      final state = cubit.state as ReaderLoaded;
      expect(state.pages.length, lessThanOrEqualTo(64));
      final numbers =
          RegExp(r'本章 (\d+)/(\d+)').firstMatch(cubit.footerPageLabel)!;
      expect(numbers.group(1), '41');
      expect(int.parse(numbers.group(2)!), greaterThan(state.pages.length));
      cubit.onPageChanged(state.currentPageIndex + 1);
      expect(cubit.footerPageLabel, startsWith('本章 42/'));
      await cubit.close();
    },
  );
  test(
    'online chapter scrub seeks a spread without refetching the chapter',
    () async {
      final view =
          TestWidgetsFlutterBinding.ensureInitialized()
              .platformDispatcher
              .views
              .first;
      view.physicalSize = const Size(1200, 800);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
      var reads = 0;
      final cubit = fixture.reader(({required aid, required cid}) async {
        reads++;
        return SourceChapter(List.filled(300, '正文段落，保持位置并继续阅读。').join('\n'));
      }, ReadingProgressQueue(write: (_) async {}));
      addTearDown(cubit.close);
      await cubit.loadChapter();
      final before = reads;
      final progress = cubit.chapterProgress;
      expect(progress.count, greaterThan(2));
      await cubit.seekChapterPage(3);
      expect((cubit.state as ReaderLoaded).currentPageIndex, 2);
      expect(reads, before);
    },
  );
}
