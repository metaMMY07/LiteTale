import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/reader_chapter_sheet.dart';
import 'package:wild/widgets/reader_draggable_sheet.dart';
import 'package:wild/widgets/reader_settings_panel.dart';
import 'reader_controls_test.dart' show providers;

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
    'Android directory is a complete page with current chapter and return value',
    (tester) async {
      Chapter? selection;
      final volumes = [
        Volume(
          id: 'main',
          title: '正文',
          chapters: List.generate(
            100,
            (i) => Chapter(aid: 'bili:1', cid: '$i', title: '章节 $i', url: ''),
          ),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: materialYouTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () async {
                      selection = await showReaderChapterSheet(
                        context,
                        volumes: volumes,
                        currentAid: 'bili:1',
                        currentCid: '80',
                      );
                    },
                    child: const Text('open'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-chapter-page')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(ReaderDraggableSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-chapter-drag-handle')),
        findsNothing,
      );
      expect(find.text('章节 80'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(selection, null);
      expect(find.text('open'), findsOneWidget);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('章节 80'));
      await tester.pumpAndSettle();
      expect(selection?.cid, '80');
      expect(find.byKey(const ValueKey('reader-chapter-page')), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  Future<void> openSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      providers(
        MaterialApp(
          theme: materialYouTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () => showReaderSettingsPanel(context),
                    child: const Text('open'),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android settings keeps a fixed handle while scrolling and reverses snaps',
    (tester) async {
      await openSettings(tester);
      final panel = find.byType(ReaderSettingsPanel);
      final handle = find.byKey(const ValueKey('reader-settings-drag-handle'));
      final region = find.byKey(const ValueKey('reader-sheet-handle-region'));
      final half = tester.getSize(panel).height;
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
        false,
      );
      expect(tester.getSize(region).height, 48);
      final headerBefore = tester.getRect(region);
      final controller =
          tester.widget<ListView>(find.byType(ListView)).controller!;
      controller.jumpTo(500);
      await tester.pumpAndSettle();
      expect(tester.getRect(region), headerBefore);
      expect(handle.hitTestable(), findsOneWidget);
      await tester.fling(handle, const Offset(0, -40), 400);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, closeTo(half * 2, 1));
      expect(controller.offset, closeTo(500, .01));
      await tester.fling(handle, const Offset(0, 40), 400);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, closeTo(half, 1));
      await tester.fling(handle, const Offset(0, -40), 400);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.fling(handle, const Offset(0, 40), 400);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, closeTo(half, 1));
      await tester.fling(handle, const Offset(0, 40), 400);
      for (var i = 0; i < 8; i++) {
        if (panel.evaluate().isNotEmpty) {
          expect(tester.getSize(panel).height, closeTo(half, 1));
        }
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'Android settings body returns to half and dismisses without a smaller stop',
    (tester) async {
      await openSettings(tester);
      final panel = find.byType(ReaderSettingsPanel);
      final half = tester.getSize(panel).height;
      final list = find.byType(ListView);
      final controller = tester.widget<ListView>(list).controller!;
      controller.jumpTo(400);
      await tester.pumpAndSettle();
      await tester.flingFrom(
        tester.getTopLeft(list) + const Offset(60, 30),
        const Offset(0, 40),
        400,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.getSize(panel).height, closeTo(half, 1));
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.fling(
        find.byKey(const ValueKey('reader-settings-drag-handle')),
        const Offset(0, -40),
        400,
      );
      await tester.pumpAndSettle();
      await tester.flingFrom(
        tester.getTopLeft(list) + const Offset(60, 30),
        const Offset(0, 80),
        600,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.getSize(panel).height, closeTo(half, 1));
      await tester.flingFrom(
        tester.getTopLeft(list) + const Offset(60, 30),
        const Offset(0, 60),
        400,
      );
      for (var i = 0; i < 8; i++) {
        if (panel.evaluate().isNotEmpty) {
          expect(tester.getSize(panel).height, closeTo(half, 1));
        }
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
