import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/widgets/page_curl_view.dart';
import 'fixtures/tablet_reader_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real tablet reader pairs pages, curls both leaves, rotates and toggles curl',
    (tester) async {
      await tester.pumpWidget(await createTabletReaderFixture());
      Future<void> waitFor(bool Function() check) async {
        final watch = Stopwatch()..start();
        while (!check() && watch.elapsed.inSeconds < 35) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
        expect(check(), isTrue);
      }

      await waitFor(() => find.byType(PageCurlView).evaluate().isNotEmpty);
      final reader =
          tester.element(find.byType(PageCurlView)).read<ReaderCubit>();
      final curl =
          tester.element(find.byType(PageCurlView)).read<ReaderCurlCubit>();
      ReaderLoaded loaded() => reader.state as ReaderLoaded;
      PageCurlViewState native() =>
          tester.state<PageCurlViewState>(find.byType(PageCurlView));
      expect(loaded().layout.isSpread, isTrue);
      expect(
        loaded().layout.systemPadding.top,
        0,
        reason: 'the production reader must hide the status bar',
      );
      expect(loaded().layout.viewIndex(loaded().currentPageIndex), 1);
      final startPage = loaded().layout.firstPage(
        loaded().layout.viewIndex(loaded().currentPageIndex),
      );
      expect(
        tester.widget<PageCurlView>(find.byType(PageCurlView)).pageCount,
        (loaded().pages.length + 1) ~/ 2,
      );
      for (final y in [.18, .50, .82]) {
        await waitFor(
          () => native().isNativeInteractive && !native().isTurning,
        );
        await native().turn(1, startY: loaded().layout.viewportSize.height * y);
        await waitFor(
          () =>
              loaded().currentPageIndex == startPage + 2 && !native().isTurning,
        );
        await waitFor(() => native().isNativeInteractive);
        await native().turn(
          -1,
          startY: loaded().layout.viewportSize.height * y,
        );
        await waitFor(
          () => loaded().currentPageIndex == startPage && !native().isTurning,
        );
      }
      final anchor = loaded().pages[startPage].content.substring(0, 16);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await waitFor(
        () =>
            find.byType(PageCurlView).evaluate().isNotEmpty &&
            !loaded().layout.isSpread,
      );
      expect(
        loaded().pages[loaded().currentPageIndex].content,
        contains(anchor),
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      await waitFor(
        () =>
            find.byType(PageCurlView).evaluate().isNotEmpty &&
            loaded().layout.isSpread,
      );
      expect(
        loaded().pages[loaded().currentPageIndex].content,
        contains(anchor),
      );
      await curl.setEnabled(false);
      await tester.pump();
      expect(find.byType(PageCurlView), findsNothing);
      final before = loaded().currentPageIndex ~/ 2 * 2;
      final size = loaded().layout.viewportSize;
      await tester.tapAt(Offset(size.width * .9, size.height * .2));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, before + 2);
      final textBlocks = find.byType(RichText);
      expect(textBlocks, findsWidgets);
      for (final element in textBlocks.evaluate()) {
        final text = element.renderObject! as RenderParagraph;
        expect(
          text.text.toPlainText(),
          isNot(matches(RegExp(r'^(\d+/\d+|\d{2}:\d{2}|\d+(\.\d+)?%)$'))),
        );
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(
          rect.bottom,
          lessThanOrEqualTo(size.height - loaded().layout.insets.bottom + .01),
        );
        expect(text.textScaler, loaded().layout.textScaler);
      }
      await curl.setEnabled(true);
      await waitFor(
        () =>
            find.byType(PageCurlView).evaluate().isNotEmpty &&
            native().isNativeInteractive,
      );
      expect(tester.takeException(), isNull);
      debugPrint(
        'TABLET_READER_OK pages=${loaded().pages.length} viewport=${loaded().layout.viewportSize} scaledFont=${loaded().layout.textScaler.scale(18)} bars=${loaded().layout.systemPadding}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
