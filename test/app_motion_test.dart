import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/reader_page_controller.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/novel_cover_card.dart';

void main() {
  testWidgets(
    'explicit full-screen route slides even under a zoom host theme',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {TargetPlatform.android: ZoomPageTransitionsBuilder()},
            ),
          ),
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: FilledButton(
                    onPressed:
                        () => Navigator.push<void>(
                          context,
                          HorizontalCoverPageRoute<void>(
                            builder: (_) => const Scaffold(body: Text('目标页')),
                          ),
                        ),
                    child: const Text('打开'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump();
      final slide = find.ancestor(
        of: find.text('目标页'),
        matching: find.byType(SlideTransition),
      );
      expect(slide, findsOneWidget);
      expect(tester.widget<SlideTransition>(slide).position.value.dx, 1);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        inExclusiveRange(0.6, 0.8),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        inExclusiveRange(0.15, 0.35),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SlideTransition>(slide).position.value.dx, 0);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        inExclusiveRange(0.6, 0.9),
      );
      await tester.pumpAndSettle();
      expect(find.text('目标页'), findsNothing);
    },
  );

  testWidgets('book detail covers from right and uncovers to right', (
    tester,
  ) async {
    const book = NovelCover(aid: 'lns:1', title: '书籍', img: '', detailUrl: '');
    Object? arguments;
    await tester.pumpWidget(
      MaterialApp(
        theme: materialYouTheme(Brightness.light),
        routes: {
          '/novel/info': (context) {
            arguments = ModalRoute.of(context)!.settings.arguments;
            return const Scaffold(body: Text('详情'));
          },
        },
        home: const Scaffold(
          body: SizedBox(
            width: 160,
            height: 240,
            child: NovelCoverCard(novel: book),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byType(NovelCoverCard);
    expect(
      find.descendant(of: card, matching: find.byType(Hero)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byType(AnimatedOpacity)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byType(AnimatedScale)),
      findsNothing,
    );
    final homePosition = tester.getTopLeft(card);
    await tester.tap(card);
    await tester.pump();
    // The route may not have built its first frame until the next scheduler tick.
    await tester.pump();
    final slide = find.ancestor(
      of: find.text('详情'),
      matching: find.byType(SlideTransition),
    );
    expect(slide, findsOneWidget);
    expect(tester.widget<SlideTransition>(slide).position.value.dx, 1);
    expect(tester.getTopLeft(card), homePosition);
    expect(
      find.ancestor(of: find.text('详情'), matching: find.byType(FadeTransition)),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 120));
    final enteringX = tester.widget<SlideTransition>(slide).position.value.dx;
    expect(enteringX, greaterThan(0));
    expect(enteringX, lessThan(1));
    expect(tester.getTopLeft(card), homePosition);
    await tester.pumpAndSettle();
    expect(arguments, 'lns:1');
    expect(find.text('详情'), findsOneWidget);
    expect(tester.widget<SlideTransition>(slide).position.value.dx, 0);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester.widget<SlideTransition>(slide).position.value.dx,
      inExclusiveRange(0, 1),
    );
    expect(tester.getTopLeft(card), homePosition);
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsNothing);
    expect(find.byType(NovelCoverCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct MaterialPageRoute uses the same slide without fading', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: materialYouTheme(Brightness.dark),
        home: Builder(
          builder:
              (context) => Scaffold(
                body: FilledButton(
                  onPressed:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(body: Text('设置页')),
                        ),
                      ),
                  child: const Text('设置'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump();
    final slide = find.ancestor(
      of: find.text('设置页'),
      matching: find.byType(SlideTransition),
    );
    expect(slide, findsOneWidget);
    expect(tester.widget<SlideTransition>(slide).position.value.dx, 1);
    expect(find.byType(FadeTransition), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.widget<SlideTransition>(slide).position.value.dx, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape tablet transition travels the full viewport width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1358);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: materialYouTheme(Brightness.dark),
        home: Builder(
          builder:
              (context) => Scaffold(
                body: FilledButton(
                  onPressed:
                      () => Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(body: Text('平板详情')),
                        ),
                      ),
                  child: const Text('打开'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump();
    final destination = find.ancestor(
      of: find.text('平板详情'),
      matching: find.byType(Scaffold),
    );
    expect(tester.getTopLeft(destination).dx, closeTo(1920, 0.1));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getTopLeft(destination).dx, inExclusiveRange(0, 1920));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(destination).dx, closeTo(0, 0.1));
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getTopLeft(destination).dx, inExclusiveRange(0, 1920));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('tap and volume page turns jump directly', (tester) async {
    final controller = ReaderPageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PageView(
          controller: controller,
          children: const [Text('one'), Text('two'), Text('three')],
        ),
      ),
    );

    await controller.turn(1);
    await tester.pump();
    expect(controller.page, 1);
    expect(find.text('two'), findsOneWidget);

    await controller.turn(1);
    await tester.pump();
    expect(controller.page, 2);

    await controller.turn(-1);
    await tester.pump();
    expect(controller.page, 1);
    expect(tester.takeException(), isNull);
  });
}
