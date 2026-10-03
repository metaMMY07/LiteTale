import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('operation rows fill the width and either inset can scroll', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 600);
    addTearDown(tester.view.reset);

    final cases = <Widget Function()>[
      () => LeftAlignedScrollView(
        child: Container(
          key: const ValueKey('scroll-content'),
          width: double.infinity,
          height: 1400,
          color: Colors.blue,
        ),
      ),
      () => LeftAlignedListView.builder(
        itemCount: 20,
        itemBuilder:
            (context, index) => Container(
              key: index == 0 ? const ValueKey('scroll-content') : null,
              width: double.infinity,
              height: 100,
              color: Colors.green,
            ),
      ),
      () => LeftAlignedCustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              key: const ValueKey('scroll-content'),
              width: double.infinity,
              height: 1400,
              color: Colors.orange,
            ),
          ),
        ],
      ),
    ];

    for (final makeScrollable in cases) {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: makeScrollable())),
      );
      await tester.pumpAndSettle();

      final content = find.byKey(const ValueKey('scroll-content'));
      expect(tester.getRect(content).left, 32);
      expect(tester.getRect(content).width, 960);
      expect(tester.getRect(content).right, 992);

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final before = scrollable.position.pixels;
      await tester.dragFrom(const Offset(1010, 500), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(before));
      final afterRightDrag = scrollable.position.pixels;
      await tester.dragFrom(const Offset(10, 180), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, lessThan(afterRightDrag));
      expect(tester.takeException(), isNull);
    }
  });
}
