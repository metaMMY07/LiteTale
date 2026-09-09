import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/pages/search_page.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/src/rust/api/wenku8.dart' as w8;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/novel_cover_card.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android real search, illustration chapter, and color selection',
    (tester) async {
      Future<void> waitFor(
        bool Function() ready,
        String description, {
        int seconds = 45,
      }) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed.inSeconds < seconds) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(ready(), isTrue, reason: description);
      }

      await app.main();
      await waitFor(
        () => find.byTooltip('主题配色').evaluate().isNotEmpty,
        'login initialized',
      );
      await tester.tap(find.byTooltip('主题配色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('晴空蓝'));
      await tester.pumpAndSettle();
      expect(
        tester.element(find.text('主题配色')).read<AppAccentCubit>().state,
        'blue',
      );
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('theme-blue');
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pop();
      await tester.pumpAndSettle();
      unawaited(nav.pushNamed('/search'));
      await tester.pumpAndSettle();
      // Profile mode requires a real client id for platform text input.
      tester.testTextInput.register();
      await tester.enterText(find.byType(TextField), '魔女');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '魔女',
      );
      debugPrint('LIVE_SEARCH_SUBMIT: 魔女');
      await tester.tap(find.byTooltip('执行搜索'));
      await tester.pump();
      await waitFor(
        () => find.byType(NovelCoverCard).evaluate().isNotEmpty,
        'real Wenku8 results',
        seconds: 145,
      );
      final covers =
          tester
              .widgetList<NovelCoverCard>(find.byType(NovelCoverCard))
              .map((w) => w.novel)
              .toList();
      expect(covers.any((book) => book.title.contains('魔女')), isTrue);
      debugPrint(
        'LIVE_SEARCH: ${covers.map((book) => '${book.aid}:${book.title}').join(', ')}',
      );
      await tester.pump(const Duration(seconds: 2));
      await binding.takeScreenshot('search-results');
      final book = covers.firstWhere(
        (book) => book.title == '魔女之旅',
        orElse: () => covers.first,
      );
      final info = await w8
          .novelInfo(aid: book.aid)
          .timeout(const Duration(seconds: 40));
      final volumes = await w8
          .novelReader(aid: book.aid)
          .timeout(const Duration(seconds: 40));
      final chapters = volumes.expand((v) => v.chapters).toList();
      final Chapter illustration = chapters.firstWhere(
        (chapter) => chapter.title.contains('插图'),
      );
      debugPrint(
        'LIVE_ILLUSTRATION: ${book.aid}/${illustration.cid} ${illustration.title}',
      );
      await tester
          .element(find.byType(SearchPage))
          .read<ReaderTypeCubit>()
          .updateType(ReaderType.normal);
      unawaited(
        nav.pushNamed(
          '/novel/reader',
          arguments: {
            'novelId': book.aid,
            'chapterId': illustration.cid,
            'title': illustration.title,
            'novelInfo': info,
            'volumes': volumes,
          },
        ),
      );
      await tester.pump();
      await waitFor(
        () => find.byType(PageView).evaluate().isNotEmpty,
        'illustration reader opens',
        seconds: 50,
      );
      final cubit = tester.element(find.byType(PageView)).read<ReaderCubit>();
      expect(cubit.state, isA<ReaderLoaded>());
      expect((cubit.state as ReaderLoaded).pages.any((p) => p.isImage), isTrue);
      final wasVisible = cubit.state.showControls;
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(const Duration(seconds: 2));
      expect(cubit.state.showControls, !wasVisible);
      await binding.takeScreenshot('reader-illustration');
      nav.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
