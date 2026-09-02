import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/book_grid_delegate.dart';

Widget buildGrid({required double width, int count = 6, bool section = true}) {
  return MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: GridView.builder(
          padding: EdgeInsets.zero,
          gridDelegate: BookGridDelegate(
            sectionItemCount: section ? count : null,
          ),
          itemCount: count,
          itemBuilder: (_, index) => SizedBox(key: ValueKey('book-$index')),
        ),
      ),
    ),
  );
}

void main() {
  for (final width in [1260.0, 1702.0, 1920.0, 2560.0]) {
    testWidgets('six-book section fills full width at $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(buildGrid(width: width));

      final first = tester.getRect(find.byKey(const ValueKey('book-0')));
      final last = tester.getRect(find.byKey(const ValueKey('book-5')));
      expect(first.left, 0);
      expect(last.right, closeTo(width, 0.01));
      expect(last.top, first.top);
      expect(last.width, closeTo(first.width, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a narrow window wraps covers without horizontal overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildGrid(width: 390));

    final first = tester.getRect(find.byKey(const ValueKey('book-0')));
    final second = tester.getRect(find.byKey(const ValueKey('book-1')));
    final third = tester.getRect(find.byKey(const ValueKey('book-2')));
    expect(first.width, lessThanOrEqualTo(220));
    expect(second.right, closeTo(390, 0.01));
    expect(third.top, greaterThan(first.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalogue cards stay compact and fill each full row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1702, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildGrid(width: 1702, count: 24, section: false));

    final first = tester.getRect(find.byKey(const ValueKey('book-0')));
    final lastInRow = tester.getRect(find.byKey(const ValueKey('book-7')));
    expect(first.width, lessThanOrEqualTo(220));
    expect(first.height, lessThan(330));
    expect(lastInRow.right, closeTo(1702, 0.01));
    expect(lastInRow.top, first.top);
  });

  testWidgets(
    'a shelf with only one book does not stretch it across the screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1702, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(buildGrid(width: 1702, count: 1, section: false));
      expect(
        tester.getSize(find.byKey(const ValueKey('book-0'))).width,
        lessThanOrEqualTo(220),
      );
    },
  );

  testWidgets(
    'resizing recomputes columns and removes the empty right column',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(buildGrid(width: 1000));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('book-5'))).dy,
        greaterThan(0),
      );

      await tester.binding.setSurfaceSize(const Size(1702, 1400));
      await tester.pumpWidget(buildGrid(width: 1702));
      final last = tester.getRect(find.byKey(const ValueKey('book-5')));
      expect(last.top, 0);
      expect(last.right, closeTo(1702, 0.01));
    },
  );

  test('changes to count and sizing require a relayout', () {
    const original = BookGridDelegate(sectionItemCount: 6);
    expect(original.shouldRelayout(original), isFalse);
    expect(
      const BookGridDelegate(sectionItemCount: 5).shouldRelayout(original),
      isTrue,
    );
    expect(
      const BookGridDelegate(preferredCardWidth: 200).shouldRelayout(original),
      isTrue,
    );
  });
}
