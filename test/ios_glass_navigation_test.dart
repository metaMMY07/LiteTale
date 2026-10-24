import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/home/more_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

void iosTest(String name, WidgetTesterCallback body) {
  testWidgets(
    name,
    body,
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

void main() {
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
  iosTest(
    'iOS route follows an edge drag and supports cancelling before returning',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      late HorizontalCoverPageRoute<void> route;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () {
                      route = HorizontalCoverPageRoute<void>(
                        builder: (_) => const Scaffold(body: Text('详情')),
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
      final gesture = await tester.startGesture(const Offset(2, 400));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(route.animation!.value, inExclusiveRange(0, 1));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('详情'), findsOneWidget);
      expect(route.animation!.value, 1);
      await tester.flingFrom(const Offset(2, 400), const Offset(370, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('详情'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
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
      final padding = width < 600 ? 20.0 : 32.0;
      expect(card.left, padding);
      expect(card.width, width - 2 * padding);
      expect(tester.takeException(), isNull);
    });
  }
}
