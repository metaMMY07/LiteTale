import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/fluid_navigation_bar.dart';
import 'package:wild/widgets/fluid_navigation_glyph.dart';

Widget demo(ValueNotifier<bool> reducedMotion) {
  var selected = 0;
  return MaterialApp(
    theme: materialYouTheme(Brightness.light),
    home: ValueListenableBuilder<bool>(
      valueListenable: reducedMotion,
      builder:
          (context, reduced, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: StatefulBuilder(
              builder:
                  (_, setState) => Scaffold(
                    bottomNavigationBar: FluidNavigationBar(
                      destinations: const [
                        FluidNavigationDestination(
                          icon: Icons.explore_outlined,
                          selectedIcon: Icons.explore,
                          label: '发现',
                          symbol: FluidNavSymbol.compass,
                        ),
                        FluidNavigationDestination(
                          icon: Icons.book_outlined,
                          selectedIcon: Icons.book,
                          label: '书架',
                          symbol: FluidNavSymbol.ribbonBook,
                        ),
                        FluidNavigationDestination(
                          icon: Icons.history,
                          selectedIcon: Icons.history,
                          label: '历史',
                          symbol: FluidNavSymbol.history,
                        ),
                        FluidNavigationDestination(
                          icon: Icons.person_outline,
                          selectedIcon: Icons.person,
                          label: '我的',
                          symbol: FluidNavSymbol.person,
                        ),
                      ],
                      selectedIndex: selected,
                      onDestinationSelected:
                          (index) => setState(() => selected = index),
                    ),
                  ),
            ),
          ),
    ),
  );
}

List<Invocation> draw(WidgetTester tester, Finder finder) {
  final paint = tester.widget<CustomPaint>(finder);
  final canvas = TestRecordingCanvas();
  paint.painter!.paint(canvas, tester.getSize(finder));
  return canvas.invocations.map((record) => record.invocation).toList();
}

Finder glyph(FluidNavSymbol symbol) => find.descendant(
  of: find.byKey(ValueKey(symbol)),
  matching: find.byType(CustomPaint),
);

void main() {
  testWidgets('needle completes a turn and history draws counterclockwise', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await tester.pumpWidget(demo(reduced));
    Iterable<Invocation> arcs() => draw(
      tester,
      glyph(FluidNavSymbol.history),
    ).where((call) => call.memberName == #drawArc);
    double turn() =>
        draw(tester, glyph(FluidNavSymbol.compass))
                .singleWhere((call) => call.memberName == #rotate)
                .positionalArguments
                .single
            as double;
    RRect pill() =>
        draw(
                  tester,
                  find
                      .descendant(
                        of: find.byType(FluidNavigationBar),
                        matching: find.byWidgetPredicate(
                          (widget) =>
                              widget is CustomPaint && widget.painter != null,
                        ),
                      )
                      .first,
                )
                .singleWhere((call) => call.memberName == #drawRRect)
                .positionalArguments
                .first
            as RRect;

    expect(arcs(), isEmpty);
    await tester.tap(find.text('历史'));
    await tester.pump();
    expect(arcs(), isEmpty);
    await tester.pump(const Duration(milliseconds: 140));
    final firstSweep = arcs().single.positionalArguments[2] as double;
    expect(firstSweep, inExclusiveRange(-math.pi, 0));
    await tester.pump(const Duration(milliseconds: 85));
    final secondSweep = arcs().single.positionalArguments[2] as double;
    expect(secondSweep, lessThan(firstSweep));

    final before = pill();
    await tester.tap(find.text('书架'));
    await tester.pump();
    expect(pill().left, closeTo(before.left, .01));
    expect(pill().right, closeTo(before.right, .01));

    await tester.tap(find.text('发现'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(turn(), inExclusiveRange(0, 2 * math.pi));
    await tester.pumpAndSettle();
    expect(turn(), closeTo(2 * math.pi, .001));
    expect(arcs(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('book ribbon and person change shape inside fixed icon slots', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await tester.pumpWidget(demo(reduced));
    final book = glyph(FluidNavSymbol.ribbonBook);
    final person = glyph(FluidNavSymbol.person);
    final bookRect = tester.getRect(book), personRect = tester.getRect(person);
    Iterable<Path> bookPaths() => draw(tester, book)
        .where((call) => call.memberName == #drawPath)
        .map((call) => call.positionalArguments.first as Path);
    double headHeight() =>
        (draw(tester, person)
                    .firstWhere((call) => call.memberName == #drawOval)
                    .positionalArguments
                    .first
                as Rect)
            .height;

    final originalRibbon = bookPaths().single.getBounds().height;
    final originalHead = headHeight();
    await tester.tap(find.text('书架'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    final movingRibbon = bookPaths().firstWhere(
      (path) => path.fillType != PathFillType.evenOdd,
    );
    expect(movingRibbon.getBounds().height, greaterThan(originalRibbon));
    expect(tester.getRect(book), bookRect);
    await tester.pumpAndSettle();
    expect(bookPaths().single.fillType, PathFillType.evenOdd);

    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    expect(headHeight(), greaterThan(originalHead));
    expect(tester.getRect(person), personRect);

    reduced.value = true;
    await tester.pumpAndSettle();
    expect(headHeight(), lessThan(originalHead + 1));
    await tester.tap(find.text('历史'));
    await tester.pump();
    final arc = draw(
      tester,
      glyph(FluidNavSymbol.history),
    ).singleWhere((call) => call.memberName == #drawArc);
    expect(arc.positionalArguments[2] as double, lessThan(-5));
    expect(tester.takeException(), isNull);
  });
}
