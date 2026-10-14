import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/frame_auto_scroller.dart';

void main() {
  testWidgets('auto scroll speed is time based at 60 and 120 Hz', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: controller,
          child: const SizedBox(height: 10000),
        ),
      ),
    );
    final scroller = FrameAutoScroller(
      vsync: tester,
      controller: controller,
      pixelsPerSecond: () => 120,
      onEnd: () {},
    );
    scroller.start();
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(microseconds: 16667));
    }
    final sixty = controller.offset;
    scroller.stop();
    controller.jumpTo(0);
    scroller.start();
    await tester.pump();
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(microseconds: 8333));
    }
    expect(controller.offset, closeTo(sixty, 0.1));
    expect(controller.offset, closeTo(120, 1));
    scroller.dispose();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('stop freezes position and a stalled frame never leaps a page', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: controller,
          child: const SizedBox(height: 10000),
        ),
      ),
    );
    final scroller = FrameAutoScroller(
      vsync: tester,
      controller: controller,
      pixelsPerSecond: () => 100,
      onEnd: () {},
    );
    scroller.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(controller.offset, lessThan(7));
    scroller.stop();
    final stopped = controller.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.offset, stopped);
    scroller.dispose();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
