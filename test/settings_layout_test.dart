import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
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
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/settings/reader_settings_page.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/settings/reading_statistics_page.dart';
import 'package:wild/settings/settings_page.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/theme_paper_page.dart';
import 'package:wild/pages/home/font_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    readerHanLocale = null;
  });

  testWidgets('直接显示外观选项，移除无关入口且字形选择持久化', (tester) async {
    final writtenPreferences = <String>[];
    final harness = _SettingsHarness(
      settingsRead: () async => '',
      settingsWrite: (value) async => writtenPreferences.add(value),
    );
    addTearDown(harness.close);
    await harness.preferences.initialize();
    _useViewport(tester, const Size(390, 844));

    await tester.pumpWidget(harness.app(const SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('显示'), findsOneWidget);
    for (final title in ['主题与纸张', '字体设置', '阅读显示', '汉字变体']) {
      expect(find.text(title), findsOneWidget);
    }
    for (final title in [
      '设置',
      '语言',
      '更新',
      '自动检查更新',
      '更新渠道',
      '分发平台',
      '立即检查更新',
      '数据',
      '快照数据',
      '关于',
      'GitHub',
    ]) {
      expect(find.text(title), findsNothing);
    }
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('汉字变体'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('汉字变体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('汉字变体'));
    await tester.pumpAndSettle();
    expect(find.text('繁体中文（台湾）'), findsOneWidget);
    await tester.tap(find.text('繁体中文（台湾）'));
    await tester.pumpAndSettle();

    expect(harness.preferences.state.hanVariant, 'zh-TW');
    expect(readerHanLocale?.languageCode, 'zh');
    expect(readerHanLocale?.countryCode, 'TW');
    expect(writtenPreferences, hasLength(1));
    expect(
      (jsonDecode(writtenPreferences.single)
          as Map<String, dynamic>)['hanVariant'],
      'zh-TW',
    );

    final restored = SettingsPreferencesCubit(
      read: () async => writtenPreferences.single,
      write: (_) async {},
    );
    addTearDown(restored.close);
    await restored.initialize();
    expect(restored.state.hanVariant, 'zh-TW');
    expect(readerHanLocale?.countryCode, 'TW');
  });

  testWidgets('主题三张预览、纸张预览和阅读显示在窄屏大字及平板可布局', (tester) async {
    final harness = _SettingsHarness();
    addTearDown(harness.close);

    _useViewport(tester, const Size(320, 800));
    await tester.pumpWidget(
      harness.app(const ThemePaperPage(), textScale: 1.6),
    );
    await tester.pumpAndSettle();
    expect(find.text('保持浅色'), findsOneWidget);
    expect(find.text('保持深色'), findsOneWidget);
    // The same label is also used by the independent app-accent setting.
    expect(find.text('跟随系统'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString().contains(
              'ThemePreviewPainter',
            ),
      ),
      findsNWidgets(3),
    );
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('深色纸张'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色纸张'));
    await tester.pumpAndSettle();
    final previewText = find.text(
      '在故事里，找到属于自己的片刻。\nEvery story begins with a page.',
    );
    await tester.scrollUntilVisible(
      previewText,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(previewText);
    final paperPreview = tester.widget<Text>(previewText);
    expect(paperPreview.style?.color, harness.theme.state.darkTextColor);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      harness.app(const ReaderSettingsPage(), textScale: 1.6),
    );
    await tester.pumpAndSettle();
    expect(find.text('阅读显示'), findsOneWidget);
    for (final title in [
      '字号',
      '行距',
      '段间距',
      '阅读模式',
      '仿真翻页',
      '上边距',
      '下边距',
      '左边距',
      '右边距',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    for (final title in ['点击翻页', '音量键翻页', '边界切换章节', '避免误触返回', '屏幕']) {
      expect(find.text(title), findsNothing);
    }
    expect(tester.takeException(), isNull);
    for (var page = 0; page < 5; page++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      final layoutException = tester.takeException();
      expect(layoutException, isNull, reason: '$layoutException');
    }

    _useViewport(tester, const Size(1024, 900));
    await tester.pumpWidget(harness.app(const ReaderSettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('阅读显示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统计总览和日周月详情在窄屏大字及平板无布局异常', (tester) async {
    final harness = _SettingsHarness();
    addTearDown(harness.close);

    for (final (size, scale) in <(Size, double)>[
      (const Size(320, 800), 1.7),
      (const Size(1024, 900), 1.0),
    ]) {
      _useViewport(tester, size);
      await tester.pumpWidget(
        harness.app(const ReadingStatisticsPage(), textScale: scale),
      );
      await tester.pumpAndSettle();
      expect(find.text('阅读统计'), findsOneWidget);
      final layoutException = tester.takeException();
      expect(layoutException, isNull, reason: '$layoutException');

      await tester.scrollUntilVisible(
        find.text('查看详情'),
        260,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('查看详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('阅读趋势'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('周'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('月'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      harness.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('阅读统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('显示入口打开独立子页并可正常返回', (tester) async {
    final harness = _SettingsHarness();
    addTearDown(harness.close);
    await harness.preferences.initialize();
    _useViewport(tester, const Size(390, 844));

    await tester.pumpWidget(harness.app(const SettingsPage()));
    await tester.pumpAndSettle();
    for (final (entry, pageTitle) in <(String, String)>[
      ('主题与纸张', '主题与纸张'),
      ('字体设置', '字体设置'),
      ('阅读显示', '阅读显示'),
    ]) {
      await tester.ensureVisible(find.text(entry));
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
      expect(find.text(pageTitle), findsOneWidget);
      expect(tester.takeException(), isNull);

      harness.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('字体页在放大字号窄屏和整行平板上可滚动且无溢出', (tester) async {
    final harness = _SettingsHarness();
    addTearDown(harness.close);

    _useViewport(tester, const Size(320, 640));
    await tester.pumpWidget(
      harness.app(const FontSettingsPage(), textScale: 1.8),
    );
    await tester.pumpAndSettle();
    expect(find.text('字体设置'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('font-reset-reader')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);

    _useViewport(tester, const Size(1024, 700));
    await tester.pumpWidget(harness.app(const FontSettingsPage()));
    await tester.pumpAndSettle();
    final readerPreview = find.byKey(const ValueKey('font-preview-reader'));
    final readerCard =
        find.ancestor(of: readerPreview, matching: find.byType(Card)).first;
    expect(tester.getRect(readerCard).left, 32);
    expect(tester.getRect(readerCard).right, 992);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(0);
    final before = scrollable.position.pixels;
    await tester.dragFrom(const Offset(990, 560), const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(before));
    expect(tester.takeException(), isNull);
  });
}

void _useViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

class _SettingsHarness {
  _SettingsHarness({
    Future<String> Function()? settingsRead,
    Future<void> Function(String)? settingsWrite,
  }) {
    preferences = SettingsPreferencesCubit(
      read: settingsRead ?? () async => '',
      write: settingsWrite ?? (_) async {},
    );
    update = UpdateCubit(
      client: MockClient((_) async => http.Response('[]', 200)),
      version: () => '0.0.0',
    );
    statistics = ReadingStatisticsCubit(
      read: () async => '',
      write: (_) async {},
    );
  }

  final navigatorKey = GlobalKey<NavigatorState>();
  late final SettingsPreferencesCubit preferences;
  late final UpdateCubit update;
  late final ReadingStatisticsCubit statistics;
  final theme = ThemeCubit();
  final accent = AppAccentCubit(
    read: () async => 'system',
    write: (_) async {},
  );
  final background = ReaderBackgroundCubit();
  final fonts = FontSettingsCubit();
  final readerCurl = ReaderCurlCubit(
    read: () async => 'false',
    write: (_) async {},
  );
  final volume = VolumeControlCubit();
  final fontSize = FontSizeCubit();
  final lineHeight = LineHeightCubit();
  final spacing = ParagraphSpacingCubit();
  final topBarHeight = TopBarHeightCubit();
  final bottomBarHeight = BottomBarHeightCubit();
  final leftPadding = LeftPaddingCubit();
  final rightPadding = RightPaddingCubit();
  final readerType = ReaderTypeCubit();

  Widget app(Widget home, {double textScale = 1}) => MultiBlocProvider(
    providers: [
      BlocProvider<SettingsPreferencesCubit>.value(value: preferences),
      BlocProvider<UpdateCubit>.value(value: update),
      BlocProvider<ReadingStatisticsCubit>.value(value: statistics),
      BlocProvider<ThemeCubit>.value(value: theme),
      BlocProvider<AppAccentCubit>.value(value: accent),
      BlocProvider<ReaderBackgroundCubit>.value(value: background),
      BlocProvider<FontSettingsCubit>.value(value: fonts),
      BlocProvider<ReaderCurlCubit>.value(value: readerCurl),
      BlocProvider<VolumeControlCubit>.value(value: volume),
      BlocProvider<FontSizeCubit>.value(value: fontSize),
      BlocProvider<LineHeightCubit>.value(value: lineHeight),
      BlocProvider<ParagraphSpacingCubit>.value(value: spacing),
      BlocProvider<TopBarHeightCubit>.value(value: topBarHeight),
      BlocProvider<BottomBarHeightCubit>.value(value: bottomBarHeight),
      BlocProvider<LeftPaddingCubit>.value(value: leftPadding),
      BlocProvider<RightPaddingCubit>.value(value: rightPadding),
      BlocProvider<ReaderTypeCubit>.value(value: readerType),
    ],
    child: MaterialApp(
      navigatorKey: navigatorKey,
      home: home,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    ),
  );

  Future<void> close() async {
    await Future.wait([
      preferences.close(),
      update.close(),
      statistics.close(),
      theme.close(),
      accent.close(),
      background.close(),
      fonts.close(),
      readerCurl.close(),
      volume.close(),
      fontSize.close(),
      lineHeight.close(),
      spacing.close(),
      topBarHeight.close(),
      bottomBarHeight.close(),
      leftPadding.close(),
      rightPadding.close(),
      readerType.close(),
    ]);
  }
}
