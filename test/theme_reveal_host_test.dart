import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/theme_reveal_host.dart';

void main() {
  Future<void> pumpDemo(
    WidgetTester tester,
    ValueNotifier<ThemeMode> mode, {
    bool disableAnimations = false,
  }) async {
    final buttonKey = GlobalKey();
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder:
            (context, currentMode, _) => MaterialApp(
              theme: ThemeData.light(),
              darkTheme: ThemeData.dark(),
              themeMode: currentMode,
              themeAnimationDuration: Duration.zero,
              builder: (context, child) {
                final host = ThemeRevealHost(child: child!);
                if (!disableAnimations) return host;
                return MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: host,
                );
              },
              home: Builder(
                builder:
                    (context) => Scaffold(
                      appBar: AppBar(
                        actions: [
                          IconButton(
                            key: buttonKey,
                            tooltip: '切换主题',
                            onPressed:
                                () => ThemeRevealHost.maybeOf(
                                  context,
                                )!.revealFrom(
                                  triggerContext: buttonKey.currentContext!,
                                  changeTheme: () {
                                    mode.value =
                                        mode.value == ThemeMode.light
                                            ? ThemeMode.dark
                                            : ThemeMode.light;
                                  },
                                ),
                            icon: const Icon(Icons.dark_mode),
                          ),
                        ],
                      ),
                      body: Center(
                        child: Text(Theme.of(context).brightness.name),
                      ),
                    ),
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('theme reveal covers the old page and settles on the new theme', (
    tester,
  ) async {
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    await pumpDemo(tester, mode);
    expect(find.text('light'), findsOneWidget);

    await tester.tap(find.byTooltip('切换主题'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('theme-reveal-overlay')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 450));
    expect(
      find.byKey(const ValueKey('theme-reveal-overlay')),
      findsOneWidget,
      reason: 'The reveal should still be visible halfway across the screen.',
    );
    await tester.pumpAndSettle();

    expect(mode.value, ThemeMode.dark);
    expect(find.text('dark'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-reveal-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion switches theme without the circular overlay', (
    tester,
  ) async {
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    await pumpDemo(tester, mode, disableAnimations: true);

    await tester.tap(find.byTooltip('切换主题'));
    await tester.pumpAndSettle();

    expect(mode.value, ThemeMode.dark);
    expect(find.byKey(const ValueKey('theme-reveal-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('second toggle never flashes the new theme before the reveal', (
    tester,
  ) async {
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    await pumpDemo(tester, mode);

    await tester.tap(find.byTooltip('切换主题'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(mode.value, ThemeMode.dark);

    await tester.tap(find.byTooltip('切换主题'));
    double? firstFrameProgress;
    tester.binding.addPostFrameCallback((_) {
      final overlay = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('theme-reveal-overlay')),
      );
      final dynamic painter = overlay.painter;
      firstFrameProgress = painter.progress.value as double;
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('theme-reveal-overlay')), findsOneWidget);
    expect(firstFrameProgress, lessThan(0.01));

    await tester.pumpAndSettle();
    expect(mode.value, ThemeMode.light);
    expect(tester.takeException(), isNull);
  });
}
