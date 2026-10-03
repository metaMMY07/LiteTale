import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/pages/home/font_settings_page.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/widgets/page_curl_view.dart';
import 'package:wild/widgets/reader_paper_view.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/methods.dart' show dataRoot;
import 'fixtures/tablet_reader_fixture.dart';

// Files are supplied on the test device, never bundled into the user APK:
// /sdcard/Android/data/io.github.metammy07.novels/files/font-qa/
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real CJK TTF and Latin OTF: live fonts, reflow, native curl, reset and reload',
    (tester) async {
      const folder =
          '/sdcard/Android/data/io.github.metammy07.novels/files/font-qa';
      String saved = '';
      XFile? picked = XFile('$folder/LiteTale-UI-Kai.ttf');
      final fonts = FontSettingsCubit(
        read: () async => saved,
        write: (value) async => saved = value,
        pick: () async => picked,
      );
      await fonts.initialize(await dataRoot());
      await tester.pumpWidget(await createTabletReaderFixture(fonts: fonts));
      Future<void> waitFor(bool Function() check) async {
        final watch = Stopwatch()..start();
        while (!check() && watch.elapsed.inSeconds < 40) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await tester.pump();
        expect(check(), isTrue);
      }

      await waitFor(() => find.byType(PageCurlView).evaluate().isNotEmpty);
      final context = tester.element(find.byType(PageCurlView));
      final reader = context.read<ReaderCubit>();
      final curl = context.read<ReaderCurlCubit>();
      ReaderLoaded loaded() => reader.state as ReaderLoaded;
      await curl.setEnabled(false);
      await tester.pump();
      final originalPages = loaded().pages;
      final physicalPage = loaded().currentPageIndex;
      // Finish an actual page-selection event, establishing the current text
      // anchor after the initial immersive-mode viewport reflow.
      reader.onPageChanged(physicalPage);
      final anchor = ReaderPosition.at(originalPages, physicalPage);
      final readerText = originalPages[physicalPage].content.substring(0, 16);

      Navigator.of(tester.element(find.byType(Navigator).first)).push(
        HorizontalCoverPageRoute(builder: (_) => const FontSettingsPage()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('font-import-app')));
      await waitFor(() => fonts.state.app != null && fonts.state.busy == null);
      expect(fonts.state.app!.name, 'LiteTale-UI-Kai.ttf');
      expect(
        Theme.of(
          tester.element(find.byType(FontSettingsPage)),
        ).textTheme.bodyMedium!.fontFamily,
        fonts.state.appFamily,
      );
      expect(
        loaded().pages,
        same(originalPages),
        reason: 'UI font must not repaginate the novel',
      );
      expect(loaded().fontFamily, appFontFamily);

      picked = XFile('$folder/LiteTale-Reader-Deng.ttf');
      await tester.ensureVisible(
        find.byKey(const ValueKey('font-import-reader')),
      );
      await tester.tap(find.byKey(const ValueKey('font-import-reader')));
      await waitFor(
        () =>
            fonts.state.reader != null &&
            loaded().fontFamily == fonts.state.readerFamily,
      );
      final reflowed = loaded();
      expect(reflowed.pages, isNot(same(originalPages)));
      expect(reflowed.currentPageIndex, anchor.pageIn(reflowed.pages));
      expect(
        reflowed.pages[reflowed.currentPageIndex].content,
        contains(readerText),
      );
      expect(
        reflowed.pages.map((p) => p.content).join(''),
        originalPages.map((p) => p.content).join(''),
      );
      expect(fonts.state.appFamily, isNot(fonts.state.readerFamily));
      debugPrint(
        'FONT_QA: separate UI and reader CJK fonts applied; anchor retained.',
      );

      final restored = FontSettingsCubit(
        read: () async => saved,
        write: (_) async {},
      );
      await restored.initialize(await dataRoot());
      expect(restored.state.appFamily, fonts.state.appFamily);
      expect(restored.state.readerFamily, fonts.state.readerFamily);
      expect(restored.state.restoreWarning, isNull);
      await restored.close();

      // The user's actual CJK font stays a device-only QA input. Test the
      // production import and reader reflow rather than just the preview.
      picked = XFile('$folder/YanZhenQingDuoBaoTaBei-2.ttf');
      await tester.tap(find.byKey(const ValueKey('font-import-reader')));
      await waitFor(
        () =>
            fonts.state.reader?.name == 'YanZhenQingDuoBaoTaBei-2.ttf' &&
            loaded().fontFamily == fonts.state.readerFamily,
      );
      expect(loaded().currentPageIndex, anchor.pageIn(loaded().pages));
      expect(
        loaded().pages.map((p) => p.content).join(''),
        originalPages.map((p) => p.content).join(''),
      );
      debugPrint(
        'FONT_QA: user YanZhenQing font applied to the actual reader.',
      );

      final beforeBad = fonts.state.readerFamily;
      picked = XFile('$folder/LiteTale-Broken.ttf');
      await tester.tap(find.byKey(const ValueKey('font-import-reader')));
      await waitFor(() => fonts.state.busy == null);
      expect(fonts.state.readerFamily, beforeBad);
      await waitFor(() => find.textContaining('字体文件已损坏').evaluate().isNotEmpty);
      expect(find.textContaining('字体文件已损坏'), findsOneWidget);
      picked = null;
      await tester.tap(find.byKey(const ValueKey('font-import-reader')));
      await waitFor(() => fonts.state.busy == null);
      expect(fonts.state.readerFamily, beforeBad);

      picked = XFile('$folder/LiteTale-Reader-Sans.otf');
      await tester.tap(find.byKey(const ValueKey('font-import-reader')));
      await waitFor(
        () =>
            fonts.state.reader?.extension == 'otf' &&
            loaded().fontFamily == fonts.state.readerFamily,
      );
      expect(fonts.state.reader!.name, 'LiteTale-Reader-Sans.otf');
      expect(loaded().currentPageIndex, anchor.pageIn(loaded().pages));
      Navigator.pop(tester.element(find.byType(FontSettingsPage)));
      await tester.pumpAndSettle();
      final body = find.descendant(
        of: find.byType(ReaderPaperLeaf),
        matching: find.byType(RichText),
      );
      for (final element in body.evaluate()) {
        final paragraph = element.renderObject! as RenderParagraph;
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(
          rect.bottom,
          lessThanOrEqualTo(
            loaded().layout.viewportSize.height -
                loaded().layout.insets.bottom +
                .01,
          ),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        final style = paragraph.text.style!;
        expect(
          style.fontFamily,
          paragraph.text.toPlainText() == loaded().title
              ? fonts.state.readerFamily
              : loaded().fontFamily,
        );
        expect(style.fontFamilyFallback, contains(appFontFamily));
      }
      await curl.setEnabled(true);
      await waitFor(
        () =>
            find.byType(PageCurlView).evaluate().isNotEmpty &&
            tester
                .state<PageCurlViewState>(find.byType(PageCurlView))
                .isNativeInteractive &&
            !tester
                .state<PageCurlViewState>(find.byType(PageCurlView))
                .isTurning,
      );
      final start = loaded().layout.firstPage(
        loaded().layout.viewIndex(loaded().currentPageIndex),
      );
      await tester.state<PageCurlViewState>(find.byType(PageCurlView)).turn(1);
      await waitFor(() => loaded().currentPageIndex == start + 2);
      await waitFor(
        () =>
            tester
                .state<PageCurlViewState>(find.byType(PageCurlView))
                .isNativeInteractive &&
            !tester
                .state<PageCurlViewState>(find.byType(PageCurlView))
                .isTurning,
      );
      await tester.state<PageCurlViewState>(find.byType(PageCurlView)).turn(-1);
      await waitFor(() => loaded().currentPageIndex == start);
      await fonts.reset(FontScope.reader);
      await waitFor(() => loaded().fontFamily == appFontFamily);
      expect(fonts.state.app, isNotNull);
      await fonts.reset(FontScope.app);
      await waitFor(() => fonts.state.busy == null);
      expect(fonts.state.appFamily, isNull);
      expect(fonts.state.readerFamily, appFontFamily);
      expect(tester.takeException(), isNull);
      debugPrint(
        'FONT_QA: real OTF, CJK fallback, bounds, curl and independent reset passed.',
      );
      await tester.pumpWidget(const SizedBox());
      await fonts.close();
      expect(await File('$folder/LiteTale-Reader-Sans.otf').exists(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
