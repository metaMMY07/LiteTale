import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/pages/novel/html_reader_page.dart';
import 'package:wild/pages/home/settings_page.dart';
import 'package:wild/pages/novel/novel_info_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/api/database.dart' as db;
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/widgets/novel_cover_card.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'third source public catalogue, isolated favorites and illustration',
    (tester) async {
      Future<void> waitFor(bool Function() ready, String label) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed.inSeconds < 50) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: label);
      }

      await app.main();
      await waitFor(
        () => find.byType(NavigationBar).evaluate().isNotEmpty,
        'app startup',
      );
      final originalSource = activeSource.value;
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      final readerType = nav.context.read<ReaderTypeCubit>();
      final originalType = readerType.state;
      final originalShelf = await db.loadProperty(
        key: 'litetale.lnovel.local_shelf',
      );
      final originalHistory = await db.loadProperty(
        key: 'litetale.lnovel.search_history',
      );
      addTearDown(() async {
        await api.selectSource(originalSource);
        await db.saveProperty(
          key: 'reader_type',
          value: originalType.toString(),
        );
        await db.saveProperty(
          key: 'litetale.lnovel.local_shelf',
          value: originalShelf,
        );
        await db.saveProperty(
          key: 'litetale.lnovel.search_history',
          value: originalHistory,
        );
      });
      await api.selectSource(SourceId.lnovel);
      await api.loadSourceSelection();
      expect(activeSource.value, SourceId.lnovel);
      final detail = await api.lnovelSource.detail('lnv:3638');
      expect(detail.volumes.expand((v) => v.chapters).length, greaterThan(20));
      final result = await api.search(
        searchType: 'articlename',
        searchKey: '義妹',
        page: 1,
      );
      expect(result.records.any((b) => b.title.contains('義妹')), isTrue);
      expect(result.records.every((b) => b.title.contains('義妹')), isTrue);
      final missing = await api.lnovelSource.search(
        'zzzz-no-such-title-9f4e',
        'articlename',
        1,
      );
      expect(missing.records, isEmpty);
      final shelfBefore = await db.loadProperty(
        key: 'litetale.lns.local_shelf',
      );
      await api.addBookshelf(aid: 'lnv:3638');
      expect(
        (await api.bookInCase(
          caseId: 'lnovel:local',
        )).items.any((b) => b.aid == 'lnv:3638'),
        isTrue,
      );
      expect(
        await db.loadProperty(key: 'litetale.lns.local_shelf'),
        shelfBefore,
      );
      final text = await api.lnovelSource.chapter('lnv:3638', 'lnv:138730');
      expect(text.content.length, greaterThan(1000));
      final illustrated = await api.lnovelSource.chapter(
        'lnv:3638',
        'lnv:138746',
      );
      expect(
        RegExp('<!--image-->').allMatches(illustrated.content).length,
        greaterThan(2),
      );
      await binding.convertFlutterSurfaceToImage();
      await waitFor(
        () => find.byType(NovelCoverCard).evaluate().isNotEmpty,
        'public discovery cards',
      );
      final firstCard = find.byType(NovelCoverCard).first;
      await waitFor(
        () => tester
            .widgetList<RawImage>(
              find.descendant(of: firstCard, matching: find.byType(RawImage)),
            )
            .any((i) => i.image != null),
        'first discovery cover decoded',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: firstCard, matching: find.byType(AnimatedOpacity)),
        findsNothing,
      );
      await binding.takeScreenshot('expressive-discovery');
      unawaited(
        nav.push(MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('书源与账号'), findsOneWidget);
      await binding.takeScreenshot('expressive-source-settings');
      nav.pop();
      await tester.pump(const Duration(milliseconds: 700));
      unawaited(nav.pushNamed('/novel/info', arguments: 'lnv:3638'));
      await waitFor(
        () => find.byType(NovelInfoPage).evaluate().isNotEmpty,
        'detail cover',
      );
      await waitFor(
        () => tester
            .widgetList<RawImage>(
              find.descendant(
                of: find.byType(NovelInfoPage),
                matching: find.byType(RawImage),
              ),
            )
            .any((i) => i.image != null),
        'cover decoded',
      );
      await tester.pumpAndSettle();
      await binding.takeScreenshot('expressive-source-detail');
      nav.pop();
      await tester.pump(const Duration(milliseconds: 700));
      // Open book keeps its own source even while discovery is switched away.
      activeSource.value = SourceId.lightNovelShelf;
      await readerType.updateType(ReaderType.html);
      unawaited(
        nav.pushNamed(
          '/novel/reader',
          arguments: {
            'novelId': 'lnv:3638',
            'chapterId': 'lnv:138746',
            'title': '插画',
            'initialPage': 0,
            'novelInfo': detail.info,
            'volumes': detail.volumes,
          },
        ),
      );
      final reader = find.byType(HtmlReaderPage);
      final frames = find.descendant(
        of: reader,
        matching: find.byType(RawImage),
      );
      await waitFor(
        () => tester
            .widgetList<RawImage>(frames)
            .take(1)
            .any((i) => i.image != null && i.image!.width > 200),
        'third source illustration decoded',
      );
      final images = tester.widgetList<Image>(
        find.descendant(of: reader, matching: find.byType(Image)),
      );
      expect(
        images
            .where((i) => i.image is CachedImageProvider)
            .every(
              (i) => (i.image as CachedImageProvider).source == SourceId.lnovel,
            ),
        isTrue,
      );
      await tester.pumpAndSettle();
      await binding.takeScreenshot('expressive-source-illustration');
      expect(tester.takeException(), isNull);
      debugPrint('LNOVEL_PUBLIC_CHAIN_AND_ISOLATION_OK');
    },
  );
}
