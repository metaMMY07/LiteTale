import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/widgets/reader_settings_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('ReaderUIQA')..addFont(
      rootBundle.load('lib/assets/fonts/LXGWNeoZhiSongPlus.ttf'),
    )).load();
    await (FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('scrub previews freely and commits exactly once on release', (
    tester,
  ) async {
    final seeks = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderPageScrubber(
            index: 3,
            count: 100,
            revision: 'chapter-a',
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    final slider = tester.widget<AppSlider>(
      find.byKey(const ValueKey('reader-page-scrubber')),
    );
    slider.onChangeStart!(3);
    slider.onChanged!(20);
    slider.onChanged!(55);
    await tester.pump();
    expect(seeks, isEmpty);
    expect(find.text('本章 56/100'), findsOneWidget);
    slider.onChangeEnd!(55);
    await tester.pump();
    expect(seeks, [55]);
  });
  testWidgets('a stale scrub cannot seek a different chapter', (tester) async {
    final seeks = <int>[];
    Widget app(String chapter) => MaterialApp(
      home: Scaffold(
        body: ReaderPageScrubber(
          index: 0,
          count: 30,
          revision: chapter,
          onSeek: seeks.add,
        ),
      ),
    );
    await tester.pumpWidget(app('a'));
    final old = tester.widget<AppSlider>(
      find.byKey(const ValueKey('reader-page-scrubber')),
    );
    old.onChangeStart!(0);
    old.onChanged!(20);
    await tester.pumpWidget(app('b'));
    old.onChangeEnd!(20);
    expect(seeks, isEmpty);
  });
  testWidgets('one-page chapters disable the scrub without invalid ranges', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderPageScrubber(
            index: 0,
            count: 1,
            revision: 'single',
            onSeek: (_) => fail('single page seek'),
          ),
        ),
      ),
    );
    expect(tester.widget<AppSlider>(find.byType(AppSlider)).onChanged, isNull);
    expect(find.text('本章 1/1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('typography saves only once after release', (tester) async {
    final saves = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderSettingSlider(
            icon: Icons.text_fields,
            title: '字号',
            description: '正文大小',
            value: 18,
            min: 10,
            max: 40,
            onSaved: (v) async => saves.add(v),
          ),
        ),
      ),
    );
    final slider = tester.widget<AppSlider>(find.byType(AppSlider));
    slider.onChanged!(20);
    slider.onChanged!(24);
    expect(saves, isEmpty);
    slider.onChangeEnd!(24);
    await tester.pumpAndSettle();
    expect(saves, [24]);
  });

  testWidgets(
    'iOS settings sheet expands with its list and keeps the reader below it',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(const Size(402, 874));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        providers(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder:
                    (context) => TextButton(
                      onPressed: () => showReaderSettingsPanel(context),
                      child: const Text('打开阅读设置'),
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开阅读设置'));
      await tester.pumpAndSettle();
      final before = tester.getRect(find.byType(ReaderSettingsPanel));
      expect(before.height, greaterThan(350));
      expect(before.height, lessThan(700));
      await tester.drag(
        find.byType(ReaderSettingsPanel),
        const Offset(0, -210),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(ReaderSettingsPanel)).height,
        greaterThan(before.height),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('native slider phases preview, commit and cancel separately', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppleGlassSlider(
            value: 18,
            min: 10,
            max: 40,
            divisions: 30,
            onChangeStart: (v) => events.add('start:$v'),
            onChanged: (v) => events.add('change:$v'),
            onChangeEnd: (v) => events.add('end:$v'),
            onChangeCancel: () => events.add('cancel'),
          ),
        ),
      ),
    );
    final dynamic bridge = tester.widget(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_AppleChrome'),
    );
    bridge.onAction('start', 18.0);
    bridge.onAction('change', 20.4);
    bridge.onAction('end', 20.4);
    bridge.onAction('cancel', null);
    expect(events, ['start:18.0', 'change:20.0', 'end:20.0', 'cancel']);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final size in [
      const Size(402, 874),
      const Size(1200, 800),
      const Size(320, 700),
    ]) {
      testWidgets(
        '$platform grouped settings fit $size and retain platform controls',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final boundary = GlobalKey();
          await tester.pumpWidget(
            providers(
              MaterialApp(
                theme: (platform == TargetPlatform.iOS
                        ? iosGlassTheme(Brightness.dark)
                        : ThemeData(
                          platform: platform,
                          brightness: Brightness.dark,
                          useMaterial3: true,
                          colorScheme: ColorScheme.fromSeed(
                            seedColor: Colors.pink,
                            brightness: Brightness.dark,
                          ),
                        ))
                    .copyWith(
                      textTheme:
                          ThemeData(
                            brightness: Brightness.dark,
                            fontFamily: 'ReaderUIQA',
                          ).textTheme,
                    ),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(size.width == 320 ? 1.8 : 1),
                  ),
                  child: Scaffold(
                    body: RepaintBoundary(
                      key: boundary,
                      child: const ReaderSettingsPanel(),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('排版'), findsOneWidget);
          expect(find.text('字号'), findsOneWidget);
          if (platform == TargetPlatform.iOS) {
            expect(find.byType(AppleGlassSlider), findsWidgets);
            // Desktop tests use the fallback; UIKit rendering is device-only.
            expect(find.byType(CupertinoSlider), findsWidgets);
          } else {
            expect(find.byType(Slider), findsWidgets);
          }
          expect(tester.takeException(), isNull);
          if (size.width == 402) {
            await tester.runAsync(() async {
              final image = await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/qa/reader-1.2.1-20261103/settings-${platform.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  }
}

Widget providers(Widget child) => MultiBlocProvider(
  providers: [
    BlocProvider(create: (_) => FontSizeCubit()),
    BlocProvider(create: (_) => LineHeightCubit()),
    BlocProvider(create: (_) => ParagraphSpacingCubit()),
    BlocProvider(create: (_) => TopBarHeightCubit()),
    BlocProvider(create: (_) => BottomBarHeightCubit()),
    BlocProvider(create: (_) => LeftPaddingCubit()),
    BlocProvider(create: (_) => RightPaddingCubit()),
    BlocProvider(create: (_) => ReaderTypeCubit()),
    BlocProvider(create: (_) => ThemeCubit()),
    BlocProvider(create: (_) => ReaderBackgroundCubit()),
    BlocProvider(
      create: (_) => ReaderCurlCubit(read: () async => '', write: (_) async {}),
    ),
    BlocProvider(
      create: (_) => VolumeControlCubit(supported: true, write: (_) async {}),
    ),
  ],
  child: child,
);
