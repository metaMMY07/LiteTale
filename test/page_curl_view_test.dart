import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/page_curl_view.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (Platform.environment['LITETALE_CURL_CAPTURE'] != '1') return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final directory = Directory('build/reader-curl');
  await directory.create(recursive: true);
  await File(
    '${directory.path}/$name.png',
  ).writeAsBytes(data!.buffer.asUint8List());
}

Widget _book(GlobalKey captureKey, ValueChanged<int> changed) {
  var index = 1;
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder:
            (context, refresh) => RepaintBoundary(
              key: captureKey,
              child: PageCurlView(
                pageCount: 3,
                index: index,
                paperDecoration: const BoxDecoration(color: Color(0xFFECE2CC)),
                paperColor: const Color(0xFFECE2CC),
                onPageChanged: (next) {
                  index = next;
                  changed(next);
                  refresh(() {});
                },
                pageBuilder:
                    (context, page) => Center(
                      child: Text(
                        'page $page',
                        style: TextStyle(
                          fontSize: 42,
                          color: [Colors.red, Colors.green, Colors.blue][page],
                        ),
                      ),
                    ),
              ),
            ),
      ),
    ),
  );
}

Future<TestGesture> _dragHalfPage(
  WidgetTester tester,
  Size size, {
  double startFraction = 0.5,
  double endFraction = 0.5,
}) async {
  final gesture = await tester.startGesture(
    Offset(size.width * 0.8, size.height * startFraction),
  );
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump();
  await gesture.moveBy(
    Offset(-size.width * 0.5, size.height * (endFraction - startFraction)),
  );
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('blank opaque fold hides all page text underneath', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: PageCurlView(
              pageCount: 3,
              index: 1,
              paperDecoration: const BoxDecoration(color: Colors.white),
              paperColor: Colors.white,
              onPageChanged: (_) {},
              pageBuilder:
                  (_, page) =>
                      page == 2
                          ? const ColoredBox(color: Colors.red)
                          : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final gesture = await _dragHalfPage(tester, const Size(400, 700));
    final channels = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixel = (350 * image.width + 210) * 4;
      final channels = [
        bytes!.getUint8(pixel),
        bytes.getUint8(pixel + 1),
        bytes.getUint8(pixel + 2),
      ];
      image.dispose();
      return channels;
    });
    final [red, green, blue] = channels!;
    // The reverse is solid white; red from the next page must not bleed through.
    expect(math.max((red - green).abs(), (red - blue).abs()), lessThan(12));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('portrait curl has a blank back and completes the turn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final changes = <int>[];
    await tester.pumpWidget(_book(key, changes.add));
    final gesture = await _dragHalfPage(tester, const Size(400, 700));
    expect(find.text('page 0'), findsNothing);
    expect(find.text('page 2'), findsOneWidget);
    await tester.runAsync(() => _capture(tester, key, 'dev13-portrait-middle'));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, [2]);
    expect(find.text('page 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape curl also has an opaque blank back', (tester) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(_book(key, (_) {}));
    final gesture = await _dragHalfPage(tester, const Size(700, 400));
    expect(find.text('page 0'), findsNothing);
    expect(find.text('page 2'), findsOneWidget);
    await tester.runAsync(
      () => _capture(tester, key, 'dev13-landscape-middle'),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-edge drags from top, middle and bottom bend differently', (
    tester,
  ) async {
    const size = Size(400, 700);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(_book(key, (_) {}));

    Future<Path> foldAt(double startFraction, String captureName) async {
      final gesture = await _dragHalfPage(
        tester,
        size,
        startFraction: startFraction,
        endFraction: startFraction,
      );
      final clip = tester.widget<ClipPath>(find.byType(ClipPath)).clipper!;
      final path = clip.getClip(size);
      await tester.runAsync(() => _capture(tester, key, captureName));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_book(key, (_) {}));
      return path;
    }

    final top = await foldAt(0.1, 'dev13-portrait-top');
    final middle = await foldAt(0.5, 'dev13-portrait-middle');
    final bottom = await foldAt(0.9, 'dev13-portrait-bottom');
    expect(top.contains(const Offset(205, 70)), isFalse);
    expect(middle.contains(const Offset(205, 70)), isFalse);
    expect(bottom.contains(const Offset(205, 70)), isTrue);
    expect(top.contains(const Offset(205, 630)), isTrue);
    expect(middle.contains(const Offset(205, 630)), isFalse);
    expect(bottom.contains(const Offset(205, 630)), isFalse);
  });

  testWidgets('changing finger height changes the fold during a drag', (
    tester,
  ) async {
    const size = Size(400, 700);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_book(GlobalKey(), (_) {}));
    final gesture = await _dragHalfPage(tester, size);
    final clip = tester.widget<ClipPath>(find.byType(ClipPath)).clipper!;
    final before = clip.getClip(size);
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    final after = clip.getClip(size);
    expect(
      before.contains(const Offset(180, 70)),
      isNot(after.contains(const Offset(180, 70))),
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('landscape top and bottom starts shape opposite corners', (
    tester,
  ) async {
    const size = Size(700, 400);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(_book(key, (_) {}));

    Future<Path> foldAt(double startFraction, String captureName) async {
      final gesture = await _dragHalfPage(
        tester,
        size,
        startFraction: startFraction,
        endFraction: startFraction,
      );
      final path = tester
          .widget<ClipPath>(find.byType(ClipPath))
          .clipper!
          .getClip(size);
      await tester.runAsync(() => _capture(tester, key, captureName));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_book(key, (_) {}));
      return path;
    }

    final top = await foldAt(0.1, 'dev13-landscape-top');
    final bottom = await foldAt(0.9, 'dev13-landscape-bottom');
    expect(top.contains(const Offset(318, 40)), isFalse);
    expect(bottom.contains(const Offset(318, 40)), isTrue);
    expect(top.contains(const Offset(318, 360)), isTrue);
    expect(bottom.contains(const Offset(318, 360)), isFalse);
  });

  testWidgets('short drag cancels without changing reading progress', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <int>[];
    await tester.pumpWidget(_book(GlobalKey(), changes.add));
    final gesture = await tester.startGesture(const Offset(320, 350));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.text('page 1'), findsOneWidget);
  });

  testWidgets('release past the screen midpoint commits the next page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <int>[];
    await tester.pumpWidget(_book(GlobalKey(), changes.add));
    final gesture = await tester.startGesture(const Offset(320, 350));
    await gesture.moveBy(const Offset(-35, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-95, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, [2]);
  });

  testWidgets('left-edge reverse drag returns to the previous page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <int>[];
    await tester.pumpWidget(_book(GlobalKey(), changes.add));
    final gesture = await tester.startGesture(const Offset(80, 350));
    await gesture.moveBy(const Offset(35, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, [0]);
  });

  testWidgets('page content is not rebuilt on every drag frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCurlView(
            pageCount: 3,
            index: 1,
            paperDecoration: const BoxDecoration(color: Colors.white),
            paperColor: Colors.white,
            onPageChanged: (_) {},
            pageBuilder: (_, page) {
              builds++;
              return Text('page $page');
            },
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(320, 350));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    final before = builds;
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    expect(builds, before);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('tap still reaches the reader tap zones', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onTapUp: (_) => taps++,
            child: PageCurlView(
              pageCount: 2,
              index: 0,
              paperDecoration: const BoxDecoration(color: Colors.white),
              paperColor: Colors.white,
              onPageChanged: (_) {},
              pageBuilder: (_, page) => Text('page $page'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('page 0'));
    await tester.pump();
    expect(taps, 1);
  });
}
