import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/home/more_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/theme/material_you.dart';

void main() {
  for (final (size, textScale) in <(Size, double)>[
    (const Size(320, 640), 1.8),
    (const Size(390, 844), 1.0),
    (const Size(1024, 700), 1.0),
  ]) {
    testWidgets('我的页条目间距适配 $size 与字号 $textScale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
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
            theme: materialYouTheme(Brightness.dark),
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
            home: const Scaffold(
              extendBody: true,
              body: MorePage(),
              bottomNavigationBar: SizedBox(
                key: ValueKey('home-navigation-bar'),
                height: 100,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final navigationCard = find.byKey(const ValueKey('more-navigation-card'));
      expect(navigationCard, findsOneWidget);
      expect(find.byType(Card), findsNWidgets(2));
      final expectedHorizontalPadding = size.width < 600 ? 20.0 : 32.0;
      final navigationRect = tester.getRect(navigationCard);
      expect(navigationRect.width, size.width - expectedHorizontalPadding * 2);
      expect(navigationRect.left, expectedHorizontalPadding);
      expect(navigationRect.right, size.width - expectedHorizontalPadding);

      final sourceRow = find.byKey(const ValueKey('more-entry-source'));
      final settingsRow = find.byKey(const ValueKey('more-entry-display'));
      final sourceRect = tester.getRect(sourceRow);
      final settingsRect = tester.getRect(settingsRow);
      expect(find.text('显示'), findsOneWidget);
      expect(find.text('设置'), findsNothing);
      expect(settingsRect.top - sourceRect.bottom, closeTo(1, 0.5));
      if (textScale == 1.0) {
        expect(sourceRect.height, settingsRect.height);
      }

      if (size.width >= 600) {
        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        final before = scrollable.position.pixels;
        await tester.dragFrom(
          Offset(size.width - 20, size.height * .75),
          const Offset(0, -220),
        );
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, greaterThan(before));
      }
      await tester.ensureVisible(find.text('关于 LiteTale'));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final aboutRect = tester.getRect(
        find.byKey(const ValueKey('more-entry-about')),
      );
      final barRect = tester.getRect(
        find.byKey(const ValueKey('home-navigation-bar')),
      );
      expect(aboutRect.bottom, lessThanOrEqualTo(barRect.top));
      expect(tester.takeException(), isNull);
    });
  }
}
