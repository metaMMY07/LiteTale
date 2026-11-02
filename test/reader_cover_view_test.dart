import 'package:flutter/material.dart';
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
  testWidgets('tap turn moves only the cover, commits once after settling', (
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
    expect(next.transform.storage[12], 0);
    await tester.pumpAndSettle();
    await turn;
    expect(changes, [2]);
    expect(controller.isTurning, isFalse);
  });
  testWidgets('previous brings the preceding page over a stationary current', (
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
      0,
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
}
