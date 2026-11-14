import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/home/more_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/ios_page_arrival.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/app_launch_screen.dart';
import 'package:wild/widgets/ios_app_dock.dart';

void iosTest(String name, WidgetTesterCallback body) {
  testWidgets(
    name,
    body,
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

Widget _dockedApp(
  GlobalKey<NavigatorState> navigator,
  IosDockController dock, {
  String initialRoute = IosDockController.homeRouteName,
}) => MaterialApp(
  theme: iosGlassTheme(Brightness.light),
  navigatorKey: navigator,
  navigatorObservers: [dock],
  builder: (context, child) => IosAppDockHost(controller: dock, child: child!),
  initialRoute: initialRoute,
  onGenerateRoute:
      (settings) => switch (settings.name) {
        IosDockController.homeRouteName => HorizontalCoverPageRoute<void>(
          settings: settings,
          animateEntrance: false,
          builder:
              (_) => Scaffold(
                key: const ValueKey('home-fixture'),
                body: ValueListenableBuilder<int>(
                  valueListenable: dock.selection,
                  builder: (_, index, _) => Text('首页 $index'),
                ),
              ),
        ),
        '/init' => HorizontalCoverPageRoute<void>(
          settings: settings,
          builder: (_) => const Scaffold(body: Text('加载')),
        ),
        _ => null,
      },
);

void main() {
  test('iOS typography uses registered system fonts', () {
    expect(
      iosGlassTheme(Brightness.light).textTheme.bodyMedium!.fontFamily,
      'CupertinoSystemText',
    );
  });
  iosTest('iOS toolbar keeps source switching, theme and search accessible', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: iosGlassTheme(Brightness.light),
        home: Scaffold(
          body: AppleGlassToolbar(
            source: '哔哩轻小说',
            onSource: () => actions.add('source'),
            onSearch: () => actions.add('search'),
            onTheme: () => actions.add('theme'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ios-source-switch')));
    await tester.tap(find.byTooltip('搜索'));
    await tester.tap(find.byTooltip('切换深浅色模式'));
    expect(actions, ['source', 'search', 'theme']);
    expect(tester.takeException(), isNull);
  });
  iosTest('covered glass chrome stays mounted and cannot receive taps', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: iosGlassTheme(Brightness.dark),
        home: Scaffold(
          bottomNavigationBar: AppleGlassBottomBar(
            index: 0,
            onSelect: (_) => selections++,
          ),
        ),
      ),
    );
    final visible = find.byType(CupertinoTabBar);
    final retained = find.byType(CupertinoTabBar, skipOffstage: false);
    final element = tester.element(visible);
    final shelf = tester.getCenter(find.text('书架'));
    navigator.currentState!.push(
      HorizontalCoverPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('详情')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.element(visible), same(element));
    await tester.tapAt(tester.getCenter(find.text('书架')));
    expect(selections, 0);
    await tester.pumpAndSettle();
    expect(visible, findsNothing);
    expect(tester.element(retained), same(element));
    await tester.tapAt(shelf);
    expect(selections, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.element(visible), same(element));
    await tester.tapAt(shelf);
    expect(selections, 1);
  });

  iosTest(
    'dock stays fixed and tapping the active Discover returns to the same home',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final dock = IosDockController();
      addTearDown(dock.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _dockedApp(navigator, dock, initialRoute: '/init'),
      );
      final bar = find.byType(AppleGlassBottomBar);
      expect(bar, findsNothing);
      navigator.currentState!.pushReplacementNamed(
        IosDockController.homeRouteName,
      );
      await tester.pump();
      final home = find.byKey(const ValueKey('home-fixture'));
      expect(tester.getRect(home).left, 0);
      expect(find.text('加载'), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
      final homeElement = tester.element(home);
      final barElement = tester.element(bar);
      final rect = tester.getRect(bar);
      expect(rect, const Rect.fromLTWH(0, 734, 390, 110));

      final detail = HorizontalCoverPageRoute<void>(
        builder:
            (_) => const Scaffold(body: SizedBox.expand(key: ValueKey('详情'))),
      );
      navigator.currentState!.push(detail);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getRect(find.byKey(const ValueKey('详情'))).left / 390,
        closeTo(.49, .05),
      );
      expect(
        tester.getRect(home).left,
        closeTo(-390 * detail.animation!.value / 3, 1),
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(detail.animation!.value, inExclusiveRange(0, 1));
      expect(tester.element(bar), same(barElement));
      expect(tester.getRect(bar), rect);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('详情'))).bottom,
        rect.bottom,
      );
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      expect(tester.element(home), same(homeElement));
      expect(tester.element(bar), same(barElement));
      expect(find.byKey(const ValueKey('详情')), findsNothing);
      expect(find.text('首页 0'), findsOneWidget);
    },
  );

  iosTest('dock skips intervening pages and respects an open modal', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final dock = IosDockController();
    addTearDown(dock.dispose);
    await tester.pumpWidget(_dockedApp(navigator, dock));
    await tester.pumpAndSettle();
    final barElement = tester.element(find.byType(AppleGlassBottomBar));
    final book = HorizontalCoverPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('书籍详情')),
    );
    navigator.currentState!.push(book);
    await tester.pumpAndSettle();
    final source = HorizontalCoverPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('书源')),
    );
    navigator.currentState!.push(source);
    await tester.pumpAndSettle();
    final history = find.text('历史');
    final context = tester.element(find.text('书源'));
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('确认')),
      barrierDismissible: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(history, warnIfMissed: false);
    expect(find.text('确认'), findsOneWidget);
    expect(dock.selection.value, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tap(history);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(source.animation!.value, inExclusiveRange(0, 1));
    expect(book.isActive, false);
    expect(find.text('书籍详情', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(AppleGlassBottomBar)), same(barElement));
    expect(find.text('首页 2'), findsOneWidget);
  });

  iosTest('reader stays full screen through exit and restores the same dock', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final dock = IosDockController(fullscreenRoutes: const {'/reader'});
    addTearDown(dock.dispose);
    await tester.pumpWidget(_dockedApp(navigator, dock));
    await tester.pumpAndSettle();
    final bar = find.byType(AppleGlassBottomBar);
    final barElement = tester.element(bar);
    final home = find.byKey(const ValueKey('home-fixture'));
    final homeHeight = tester.getSize(home).height;
    final homeBottomInset =
        MediaQuery.paddingOf(tester.element(find.text('首页 0'))).bottom;
    expect(homeBottomInset, greaterThan(0));
    final reader = HorizontalCoverPageRoute<void>(
      settings: const RouteSettings(name: '/reader'),
      builder:
          (_) => const Scaffold(body: SizedBox.expand(key: ValueKey('正文'))),
    );
    navigator.currentState!.push(reader);
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    final coveredHome = find.byKey(
      const ValueKey('home-fixture'),
      skipOffstage: false,
    );
    expect(tester.getSize(coveredHome).height, homeHeight);
    expect(
      MediaQuery.paddingOf(
        tester.element(find.text('首页 0', skipOffstage: false)),
      ).bottom,
      homeBottomInset,
    );
    final rect = tester.getRect(find.byKey(const ValueKey('正文')));
    expect(
      MediaQuery.paddingOf(
        tester.element(find.byKey(const ValueKey('正文'))),
      ).bottom,
      tester.view.padding.bottom / tester.view.devicePixelRatio,
    );
    expect(
      rect.bottom,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(bar, findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('正文'))).height,
      rect.height,
    );
    await tester.pumpAndSettle();
    expect(tester.element(bar), same(barElement));
  });

  iosTest('first-frame work waits for arrival and cancels on early exit', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: iosGlassTheme(Brightness.light),
        home: const Scaffold(),
      ),
    );
    final outcomes = <bool>[];
    void open() => navigator.currentState!.push(
      HorizontalCoverPageRoute<void>(
        builder: (context) {
          final pending = IosPageArrival.pendingOf(context);
          expect(pending, isNotNull);
          pending!.then(outcomes.add);
          return const Scaffold(body: Text('下一页'));
        },
      ),
    );

    open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(outcomes, isEmpty);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(outcomes, [false]);

    open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(outcomes, [false]);
    await tester.pumpAndSettle();
    expect(outcomes, [false, true]);
  });
  iosTest('native chrome waits for both directions of a page slide', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final rest = <String, bool>{};
    Widget page(String name) => Builder(
      builder: (context) {
        rest[name] = IosPageArrival.chromeAtRestOf(context);
        return Scaffold(body: Text(name));
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: iosGlassTheme(Brightness.light),
        home: page('我的'),
      ),
    );
    expect(rest['我的'], true);
    navigator.currentState!.push(
      HorizontalCoverPageRoute<void>(builder: (_) => page('书源与账号')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(rest, {'我的': false, '书源与账号': false});
    await tester.pumpAndSettle();
    expect(rest['书源与账号'], true);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(rest, {'我的': false, '书源与账号': false});
    await tester.pumpAndSettle();
    expect(rest['我的'], true);
    expect(find.text('书源与账号'), findsNothing);
  });

  iosTest(
    'settings snapshot follows the departing page and releases on return',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final dock = IosDockController();
      addTearDown(dock.dispose);
      await tester.pumpWidget(_dockedApp(navigator, dock));
      void open(String title) => navigator.currentState!.push(
        HorizontalCoverPageRoute<void>(
          cachePageDuringTransition: true,
          builder: (_) => Scaffold(body: Text(title)),
        ),
      );
      SnapshotWidget snapshot(String title) => tester.widget<SnapshotWidget>(
        find.ancestor(
          of: find.text(title),
          matching: find.byType(SnapshotWidget),
        ),
      );

      open('外观');
      await tester.pumpAndSettle();
      final appearance = snapshot('外观');
      expect(appearance.mode, SnapshotMode.permissive);
      expect(appearance.controller.allowSnapshotting, isFalse);

      open('字体');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(appearance.controller.allowSnapshotting, isTrue);
      expect(snapshot('字体').controller.allowSnapshotting, isFalse);
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(appearance.controller.allowSnapshotting, isFalse);
      expect(snapshot('字体').controller.allowSnapshotting, isTrue);
      await tester.pumpAndSettle();
      expect(snapshot('外观').controller, same(appearance.controller));
      expect(find.text('字体'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  iosTest(
    'iOS route follows an edge drag and supports cancelling before returning',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      late HorizontalCoverPageRoute<void> route;
      var chromeAtRest = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () {
                      route = HorizontalCoverPageRoute<void>(
                        builder:
                            (context) => Builder(
                              builder: (context) {
                                chromeAtRest = IosPageArrival.chromeAtRestOf(
                                  context,
                                );
                                return const Scaffold(body: Text('详情'));
                              },
                            ),
                      );
                      Navigator.push(context, route);
                    },
                    child: const Text('打开'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(chromeAtRest, true);
      final gesture = await tester.startGesture(const Offset(2, 400));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(route.animation!.value, inExclusiveRange(0, 1));
      expect(chromeAtRest, false);
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('详情'), findsOneWidget);
      expect(route.animation!.value, 1);
      expect(chromeAtRest, true);
      await tester.flingFrom(const Offset(2, 400), const Offset(370, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('详情'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  iosTest('reduced motion skips route animation and keeps the edge gesture', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: iosGlassTheme(Brightness.dark),
        home: const Scaffold(body: Text('主页')),
      ),
    );
    final page = HorizontalCoverPageRoute<void>(
      cachePageDuringTransition: true,
      builder: (_) => const Scaffold(body: Text('设置')),
    );
    navigator.currentState!.push(page);
    await tester.pump();
    expect(page.animation!.value, 1);
    expect(find.byType(SnapshotWidget), findsNothing);
    await tester.flingFrom(const Offset(2, 200), const Offset(610, 0), 2400);
    await tester.pumpAndSettle();
    expect(find.text('主页'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
  });

  iosTest('launch artwork stays centred and follows the system appearance', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpWidget(
        MaterialApp(
          // The in-app setting is intentionally independent of the OS here.
          theme: iosGlassTheme(Brightness.light),
          home: const AppLaunchScreen(),
        ),
      );
      final artwork = find.byType(ClipRRect);
      expect(
        tester.widget<ClipRRect>(artwork).borderRadius,
        BorderRadius.circular(24),
      );
      expect(
        tester.getRect(artwork),
        Rect.fromCenter(
          center: const Offset(195, 422),
          width: 104,
          height: 104,
        ),
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        IosSystemColors.color('background', brightness),
      );
    }
  });
  for (final width in [320.0, 1024.0]) {
    iosTest('iOS 我的 exposes book sources at full width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.reset);
      final auth = AuthCubit();
      final updates = UpdateCubit();
      addTearDown(auth.close);
      addTearDown(updates.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: auth),
            BlocProvider<UpdateCubit>.value(value: updates),
          ],
          child: MaterialApp(
            theme: iosGlassTheme(Brightness.light),
            home: const Scaffold(body: MorePage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('more-entry-source')), findsOneWidget);
      final card = tester.getRect(
        find.byKey(const ValueKey('more-navigation-card')),
      );
      final padding = width < 600 ? 16.0 : 32.0;
      expect(card.left, padding);
      expect(card.width, width - 2 * padding);
      expect(find.text('我的'), findsOneWidget);
      expect(find.text('阅读'), findsOneWidget);
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('你的阅读空间'), findsNothing);
      expect(find.byType(AppleGlassCard), findsNothing);
      final group = find.descendant(
        of: find.byKey(const ValueKey('more-navigation-card')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.shape == iosGroupedCardShape,
        ),
      );
      expect(group, findsOneWidget);
      expect(tester.widget<Material>(group).clipBehavior, Clip.antiAlias);
      await tester.ensureVisible(find.text('应用相关'));
      await tester.pumpAndSettle();
      expect(find.text('应用相关').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
