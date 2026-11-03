import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/reader_cover_view.dart';

void main() {
  testWidgets(
    'background EPUB append does not interrupt an active cover turn',
    (tester) async {
      final c = ReaderCoverController();
      final changes = <int>[];
      var leaves = 3;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ReaderCoverView(
                controller: c,
                index: 0,
                pageCount: (leaves + 1) ~/ 2,
                leafCount: leaves,
                isSpread: true,
                revision: 'same-book-window',
                paperDecoration: const BoxDecoration(color: Colors.white),
                onPageChanged: changes.add,
                pageBuilder: (_, i) => Text('spread-$i/$leaves'),
              );
            },
          ),
        ),
      );
      final turn = c.turn(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      update(() => leaves = 6);
      await tester.pump();
      expect(c.isTurning, isTrue);
      await tester.pumpAndSettle();
      await turn;
      expect(changes, [1]);
    },
  );
  Future<void> mount(
    WidgetTester tester,
    ReaderCoverController controller,
    ValueChanged<int> changed, {
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: SizedBox(
          width: 800,
          height: 600,
          child: ReaderCoverView(
            controller: controller,
            index: 1,
            pageCount: 4,
            paperDecoration: const BoxDecoration(color: Colors.white),
            onPageChanged: changed,
            pageBuilder: (_, i) => Center(child: Text('paper-$i')),
          ),
        ),
      ),
    ),
  );
  testWidgets('tap slides both adjacent sheets, commits once after settling', (
    tester,
  ) async {
    final controller = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, controller, changes.add);
    final turn = controller.turn(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.isTurning, isTrue);
    expect(changes, isEmpty);
    final current = tester.widget<Transform>(
      find.byKey(const ValueKey('cover-position-1')),
    );
    final next = tester.widget<Transform>(
      find.byKey(const ValueKey('cover-position-2')),
    );
    expect(current.transform.storage[12], lessThan(0));
    expect(next.transform.storage[12], greaterThan(0));
    expect(next.transform.storage[12] - current.transform.storage[12], 800);
    // Unlike the old strong ease-out, the beginning must remain readable.
    expect(current.transform.storage[12].abs(), lessThan(160));
    await tester.pump(const Duration(milliseconds: 120));
    final halfway = tester.widget<Transform>(
      find.byKey(const ValueKey('cover-position-1')),
    );
    expect(halfway.transform.storage[12].abs(), inExclusiveRange(280, 520));
    await tester.pumpAndSettle();
    await turn;
    expect(changes, [2]);
    expect(controller.isTurning, isFalse);
  });
  testWidgets('previous slides both sheets right, symmetrically to next', (
    tester,
  ) async {
    final c = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, c, changes.add);
    final turn = c.turn(-1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester
          .widget<Transform>(find.byKey(const ValueKey('cover-position-0')))
          .transform
          .storage[12],
      lessThan(0),
    );
    expect(
      tester
          .widget<Transform>(find.byKey(const ValueKey('cover-position-1')))
          .transform
          .storage[12],
      greaterThan(0),
    );
    await tester.pumpAndSettle();
    await turn;
    expect(changes, [0]);
  });
  testWidgets(
    'reduced motion commits without waiting and no animation remains',
    (tester) async {
      final c = ReaderCoverController();
      final changes = <int>[];
      await mount(tester, c, changes.add, reduced: true);
      await c.turn(1);
      await tester.pump();
      expect(changes, [2]);
      expect(c.isTurning, isFalse);
    },
  );
  testWidgets('short cancelled drag preserves position and history', (
    tester,
  ) async {
    final c = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, c, changes.add);
    final gesture = await tester.startGesture(const Offset(500, 300));
    await gesture.moveBy(const Offset(-50, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(c.isTurning, isFalse);
  });
  testWidgets('removing the reader cancels an unfinished commit', (
    tester,
  ) async {
    final c = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, c, changes.add);
    final turn = c.turn(1);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await turn;
    expect(changes, isEmpty);
    expect(c.isTurning, isFalse);
  });
  testWidgets('moving pages have no seam at a fractional device pixel ratio', (
    tester,
  ) async {
    const ratio = 1.25;
    tester.view.physicalSize = const Size(500, 750);
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    final c = ReaderCoverController();
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFFFF00FF),
          body: RepaintBoundary(
            key: boundary,
            child: ReaderCoverView(
              controller: c,
              index: 1,
              pageCount: 3,
              paperDecoration: const BoxDecoration(color: Colors.white),
              onPageChanged: (_) {},
              pageBuilder: (_, i) => const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final turn = c.turn(1);
    await tester.pump();
    for (final ms in [17, 33, 49, 71, 83, 107]) {
      await tester.pump(Duration(milliseconds: ms));
      final transform = tester.widget<Transform>(
        find.byKey(const ValueKey('cover-position-1')),
      );
      final dx = transform.transform.storage[12] * ratio;
      expect(dx, closeTo(dx.roundToDouble(), .00001));
      final image =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final frame = await image.toImage(pixelRatio: ratio);
        final pixels = await frame.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        // Magenta behind the papers exposes cracks; any painted shadow or
        // separator also makes this otherwise plain white scanline fail.
        final row = pixels!.buffer.asUint8List(
          frame.width * (frame.height ~/ 2) * 4,
          frame.width * 4,
        );
        expect(row.every((component) => component == 255), isTrue);
        frame.dispose();
      });
    }
    await tester.pumpAndSettle();
    await turn;
  });
  testWidgets('a finger can take over a tap settle and cancel without a jump', (
    tester,
  ) async {
    final c = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, c, changes.add);
    final turn = c.turn(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    double x() =>
        tester
            .widget<Transform>(find.byKey(const ValueKey('cover-position-1')))
            .transform
            .storage[12];
    final before = x();
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect((x() - before).abs(), lessThan(25));
    // Hold the page still; the cancelled ticker must not commit behind it.
    await tester.pump(const Duration(milliseconds: 500));
    expect(changes, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    await turn;
    expect(changes, isEmpty);
    expect(c.isTurning, isFalse);
  });

  testWidgets('first accepted drag includes movement before touch slop', (
    tester,
  ) async {
    final c = ReaderCoverController();
    await mount(tester, c, (_) {});
    final gesture = await tester.startGesture(const Offset(500, 300));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    final dx =
        tester
            .widget<Transform>(find.byKey(const ValueKey('cover-position-1')))
            .transform
            .storage[12];
    expect(dx, closeTo(-40, 1));
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  for (final interrupted in [false, true]) {
    testWidgets(
      'first swipe after resume works without a tap (drag=$interrupted)',
      (tester) async {
        final c = ReaderCoverController();
        final changes = <int>[];
        await mount(tester, c, changes.add);
        TestGesture? old;
        if (interrupted) {
          old = await tester.startGesture(const Offset(600, 300));
          await old.moveBy(const Offset(-160, 0));
          await tester.pump();
        }
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }
        await old?.cancel();
        expect(changes, isEmpty);
        expect(c.isTurning, isFalse);
        await tester.timedDragFrom(
          const Offset(600, 300),
          const Offset(-280, 0),
          const Duration(milliseconds: 240),
        );
        await tester.pumpAndSettle();
        expect(changes, [2]);
      },
    );
  }

  testWidgets(
    'drag release continues with the finger velocity without braking',
    (tester) async {
      final c = ReaderCoverController();
      final changes = <int>[];
      await mount(tester, c, changes.add);
      final gesture = await tester.startGesture(const Offset(650, 300));
      double x() =>
          tester
              .widget<Transform>(find.byKey(const ValueKey('cover-position-1')))
              .transform
              .storage[12];
      var lastDelta = 0.0;
      for (var i = 1; i <= 6; i++) {
        final before = x();
        await gesture.moveBy(
          const Offset(-40, 0),
          timeStamp: Duration(milliseconds: i * 20),
        );
        await tester.pump(const Duration(milliseconds: 20));
        lastDelta = before - x();
      }
      final releaseX = x();
      await gesture.up(timeStamp: const Duration(milliseconds: 120));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final firstDelta = releaseX - x();
      expect(firstDelta, greaterThan(lastDelta * .3));
      expect(firstDelta, lessThan(lastDelta * 2));
      await tester.pumpAndSettle();
      expect(changes, [2]);
    },
  );

  testWidgets('a reader mounted before resume accepts its very first swipe', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final c = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, c, changes.add);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.timedDragFrom(
      const Offset(600, 300),
      const Offset(-280, 0),
      const Duration(milliseconds: 240),
    );
    await tester.pumpAndSettle();
    expect(changes, [2]);
  });

  testWidgets('fast drag releases input when the target edge is reached', (
    tester,
  ) async {
    final c = ReaderCoverController();
    final changes = <int>[];
    await mount(tester, c, changes.add);
    final gesture = await tester.startGesture(const Offset(780, 300));
    for (var i = 1; i <= 5; i++) {
      await gesture.moveBy(
        const Offset(-150, 0),
        timeStamp: Duration(milliseconds: i * 20),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(changes, [2]);
    expect(c.isTurning, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(changes, [2]);
  });
}
