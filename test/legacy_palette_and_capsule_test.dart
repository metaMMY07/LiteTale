import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/book_details_view.dart';
import 'package:wild/widgets/fluid_navigation_bar.dart';

void main() {
  testWidgets(
    'iOS detail tags open a compact sheet and return the selected label',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const info = NovelInfo(
        title: '标题',
        author: '',
        status: '',
        finUpdate: '',
        imgUrl: '',
        introduce: '',
        tags: ['校园', '科幻', '异能', '魔法', '黑暗', '女性视角'],
        heat: '',
        trending: '',
        isAnimated: false,
      );
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.dark),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                BookDetailTagsButton(
                  tags: info.tags,
                  onTag: (tag) => selected = tag,
                ),
              ],
            ),
            body: BookDetailsView(
              info: info,
              source: SourceId.wenku8,
              volumes: const [],
              onRead: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('校园'), findsNothing);
      await tester.tap(find.byType(BookDetailTagsButton));
      await tester.pumpAndSettle();
      expect(find.text('书籍标签'), findsOneWidget);
      expect(tester.getTopLeft(find.text('书籍标签')).dy, greaterThan(450));
      for (final tag in info.tags) {
        expect(find.text(tag), findsOneWidget);
      }
      await tester.tap(find.text('校园'));
      await tester.pumpAndSettle();
      expect(selected, '校园');
      expect(find.text('校园'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Android paints the tonal navigation indicator in both appearances',
    (tester) async {
      for (final brightness in Brightness.values) {
        final theme = materialYouTheme(
          brightness,
          seedColor: const Color(0xFF3864A0),
        );
        const boundaryKey = ValueKey('legacy-nav-pixels');
        await tester.pumpWidget(
          MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: theme,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: SizedBox(
                    width: 400,
                    child: FluidNavigationBar(
                      selectedIndex: 0,
                      onDestinationSelected: (_) {},
                      destinations: const [
                        FluidNavigationDestination(
                          icon: Icons.home,
                          selectedIcon: Icons.home,
                          label: '发现',
                        ),
                        FluidNavigationDestination(
                          icon: Icons.book,
                          selectedIcon: Icons.book,
                          label: '书架',
                        ),
                        FluidNavigationDestination(
                          icon: Icons.history,
                          selectedIcon: Icons.history,
                          label: '历史',
                        ),
                        FluidNavigationDestination(
                          icon: Icons.person,
                          selectedIcon: Icons.person,
                          label: '我的',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        late int argb;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final offset = (30 * image.width + 25) * 4;
          argb =
              (data.getUint8(offset + 3) << 24) |
              (data.getUint8(offset) << 16) |
              (data.getUint8(offset + 1) << 8) |
              data.getUint8(offset + 2);
          image.dispose();
        });
        final expected = theme.colorScheme.secondaryContainer;
        expect(argb, expected.toARGB32());
        expect(find.byType(BackdropFilter), findsNothing);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android keeps legacy presets, native dynamic roles and imported accent compatibility',
    (tester) async {
      final cubit = AppAccentCubit(
        read: () async => 'ios-blue',
        write: (_) async {},
      );
      await cubit.load();
      expect(cubit.state, 'blue');
      expect(appAccentSeed(cubit.state), const Color(0xFF3864A0));
      await cubit.select('system');
      expect(appAccentSeed(cubit.state), isNull);
      final dynamic = ColorScheme.fromSeed(
        seedColor: Colors.orange,
        brightness: Brightness.dark,
      ).copyWith(primary: const Color(0xFFCC8844));
      final theme = materialYouTheme(Brightness.dark, dynamicScheme: dynamic);
      expect(theme.colorScheme, same(dynamic));
      expect(
        theme.navigationBarTheme.indicatorColor,
        dynamic.secondaryContainer,
      );
      await cubit.close();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
