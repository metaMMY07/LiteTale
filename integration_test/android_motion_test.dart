import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/novel_info_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/novel_cover_card.dart';
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'multi_source_test.dart' show FixtureSource;

class DelayedImageSource extends FixtureSource {
  DelayedImageSource(super.cover);
  final ready = Completer<void>();
  Completer<void>? chapterGate;
  bool shortChapter = false;
  @override
  Future<SourceChapter> chapter(String aid, String cid) async {
    await chapterGate?.future;
    return shortChapter
        ? const SourceChapter('重新分页后的短正文')
        : super.chapter(aid, cid);
  }

  @override
  NovelCover get book =>
      NovelCover(aid: 'lns:424243', title: '图文测试', img: cover, detailUrl: '');
  @override
  Future<SourceBookDetail> detail(String id) async {
    await ready.future;
    return super.detail(id);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'instant covers and page turns, reader controls, reflow and navigation',
    (tester) async {
      Future<void> waitFor(bool Function() ready, String label) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed.inSeconds < 30) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: label);
      }

      final imageReady = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final image = await rootBundle.load('lib/assets/startup.png');
      server.listen((request) async {
        await imageReady.future;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(image.buffer.asUint8List());
        await request.response.close();
      });
      final original = api.bookSources[SourceId.lightNovelShelf]!;
      final fixture = DelayedImageSource(
        'http://127.0.0.1:${server.port}/cover.png',
      );
      api.bookSources[SourceId.lightNovelShelf] = fixture;
      addTearDown(() async {
        api.bookSources[SourceId.lightNovelShelf] = original;
        await api.deleteHistoryByNovelId(novelId: fixture.book.aid);
        await server.close(force: true);
      });
      await app.main();
      await waitFor(
        () => find.byType(NavigationBar).evaluate().isNotEmpty,
        'home',
      );
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder:
                (_) => Scaffold(
                  appBar: AppBar(title: const Text('图文测试列表')),
                  body: Row(
                    children: [
                      SizedBox(
                        width: 160,
                        height: 250,
                        child: NovelCoverCard(novel: fixture.book),
                      ),
                      SizedBox(
                        width: 160,
                        height: 250,
                        child: NovelCoverCard(novel: fixture.book),
                      ),
                    ],
                  ),
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.image_outlined), findsWidgets);
      final before = tester.getSize(find.byType(CachedImage).first);
      imageReady.complete();
      await waitFor(
        () => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        'actual first decoded frame',
      );
      await tester.pump();
      expect(tester.getSize(find.byType(CachedImage).first), before);
      expect(
        find.descendant(
          of: find.byType(CachedImage),
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
      );
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await tester.tap(find.byType(NovelCoverCard).first);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final enteringDetail = find.ancestor(
        of: find.text('小说详情'),
        matching: find.byType(SlideTransition),
      );
      expect(enteringDetail, findsOneWidget);
      expect(
        tester.widget<SlideTransition>(enteringDetail).position.value.dx,
        inExclusiveRange(0, 1),
      );
      await tester.pump();
      await binding.takeScreenshot('detail-entering');
      // The destination exists before the deliberately delayed detail response.
      expect(find.text('小说详情'), findsOneWidget);
      expect(find.byType(Hero), findsNothing);
      fixture.ready.complete();
      await waitFor(
        () => find.text('图文正文').evaluate().isNotEmpty,
        'detail completes',
      );
      await tester.pumpAndSettle();
      await waitFor(
        () => tester
            .widgetList<RawImage>(
              find.descendant(
                of: find.byType(NovelInfoPage),
                matching: find.byType(RawImage),
              ),
            )
            .any((image) => image.image != null),
        'detail cover decoded',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(NovelInfoPage),
          matching: find.byIcon(Icons.image_outlined),
        ),
        findsNothing,
      );
      await binding.takeScreenshot('cover-detail');

      final info = await api.novelInfo(aid: fixture.book.aid);
      final volumes = await api.novelReader(aid: fixture.book.aid);
      unawaited(
        nav.pushNamed(
          '/novel/reader',
          arguments: {
            'novelId': fixture.book.aid,
            'chapterId': '${fixture.book.aid}:1',
            'title': '图文正文',
            'novelInfo': info,
            'volumes': volumes,
          },
        ),
      );
      await waitFor(
        () => find.byType(PageView).evaluate().isNotEmpty,
        'reader',
      );
      await tester.pumpAndSettle();
      final pages = find.byType(PageView);
      final cubit = tester.element(pages).read<ReaderCubit>();
      final rect = tester.getRect(pages);
      await tester.tapAt(Offset(rect.right - 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, 1);
      await waitFor(
        () => tester
            .widgetList<RawImage>(
              find.descendant(of: pages, matching: find.byType(RawImage)),
            )
            .any((image) => image.image != null && image.image!.width > 200),
        'reader illustration decoded',
      );
      expect(
        find.descendant(
          of: find.byType(CachedImage),
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
      );
      await binding.takeScreenshot('reader-illustration');
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(cubit.state.showControls, isTrue);
      await binding.takeScreenshot('reader-controls');
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(cubit.state.showControls, isFalse);
      await tester.tapAt(Offset(rect.left + 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, 0);

      // A delayed reflow must retain turns made while it was pending.
      fixture.chapterGate = Completer<void>();
      final reloading = cubit.reloadCurrentPage();
      await tester.pump();
      await tester.tapAt(Offset(rect.right - 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, 1);
      fixture.chapterGate!.complete();
      fixture.chapterGate = null;
      await reloading;
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, 1);
      expect(tester.widget<PageView>(pages).controller!.page, 1);

      // Shrinking the chapter must clamp both visible and persisted positions.
      await tester.tapAt(Offset(rect.right - 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, 2);
      fixture.shortChapter = true;
      await cubit.reloadCurrentPage();
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).pages, hasLength(1));
      expect((cubit.state as ReaderLoaded).currentPageIndex, 0);
      expect(tester.widget<PageView>(pages).controller!.page, 0);
      final history = await api.novelHistoryById(novelId: fixture.book.aid);
      expect(history!.progressPage, 0);

      nav.pop();
      await tester.pumpAndSettle();
      expect(find.text('小说详情'), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(NovelInfoPage))),
        isA<HorizontalCoverPageRoute<void>>(),
      );
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final leavingDetail = find.ancestor(
        of: find.text('小说详情'),
        matching: find.byType(SlideTransition),
      );
      expect(leavingDetail, findsOneWidget);
      expect(
        tester.widget<SlideTransition>(leavingDetail).position.value.dx,
        inExclusiveRange(0, 1),
      );
      await tester.pump();
      await binding.takeScreenshot('detail-returning');
      nav.popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
