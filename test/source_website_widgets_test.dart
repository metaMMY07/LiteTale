// The launcher is replaced at the platform boundary; no real browser or HTTP.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/material_source_picker.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/source_settings.dart';
import 'package:wild/widgets/source_website.dart';

class _Launcher extends UrlLauncherPlatform {
  final launches = <(String, LaunchOptions)>[];
  bool success = true;
  bool fail = false;
  @override
  get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url, options));
    if (fail) throw PlatformException(code: 'no_browser');
    return success;
  }
}

class _ReadOnlyApi implements RustLibApi {
  final sourceSelections = <String>[];
  @override
  Future<String> crateApiDatabaseLoadProperty({required String key}) async =>
      '';
  @override
  Future<void> crateApiDatabaseSaveProperty({
    required String key,
    required String value,
  }) async {
    if (key != 'litetale.active_source') {
      throw StateError('Unexpected property write: $key');
    }
    sourceSelections.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected Rust call: ${invocation.memberName}');
}

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: materialYouTheme(brightness),
      home: Scaffold(body: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Launcher launcher;
  final rustApi = _ReadOnlyApi();
  setUpAll(() async {
    RustLib.initMock(api: rustApi);
    final builtIns =
        (jsonDecode(
                  await rootBundle.loadString(
                    'assets/book_sources/bundled.json',
                  ),
                )
                as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
    await RuleSourceRegistry.instance.load(builtIns: builtIns);
  });
  setUp(() {
    rustApi.sourceSelections.clear();
    final original = UrlLauncherPlatform.instance;
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
  });

  testWidgets(
    'slow hint appears at eight seconds and only user action opens the browser',
    (tester) async {
      await tester.pumpWidget(
        _app(const SourceLoadingIndicator(source: SourceId.bili)),
      );
      await tester.pump(const Duration(milliseconds: 7999));
      expect(find.text('打开原网站'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('打开原网站'), findsOneWidget);
      expect(launcher.launches, isEmpty);
      await tester.tap(find.text('打开原网站'));
      await tester.pump();
      expect(launcher.launches.single.$1, 'https://www.bilinovel.net/');
      expect(
        launcher.launches.single.$2.mode,
        PreferredLaunchMode.externalApplication,
      );
      expect(launcher.launches.single.$2.webViewConfiguration.headers, isEmpty);
      expect(find.byType(SourceLoadingIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('theme or parent rebuild does not restart a pending deadline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SourceLoadingIndicator(source: SourceId.huanmeng, requestKey: 1),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(
      _app(
        const SourceLoadingIndicator(source: SourceId.huanmeng, requestKey: 1),
        brightness: Brightness.dark,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('打开原网站'), findsOneWidget);
    expect(find.text('https://www.huanmengacg.com/'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a new load or source starts its own deadline and replaces old links',
    (tester) async {
      Future<void> load(SourceId source, int request) => tester.pumpWidget(
        _app(SourceLoadingIndicator(source: source, requestKey: request)),
      );
      await load(SourceId.bili, 1);
      await tester.pump(const Duration(seconds: 7));
      await load(SourceId.bili, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('打开原网站'), findsNothing);
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('https://www.bilinovel.net/'), findsOneWidget);
      await load(SourceId.lnovel, 2);
      expect(find.text('打开原网站'), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('https://lnovel.tw/'), findsOneWidget);
      expect(find.text('https://www.bilinovel.net/'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('completed or disposed loading cannot leave a late hint behind', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const SourceLoadingIndicator(source: SourceId.lightNovelShelf)),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(_app(const Text('加载完成')));
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('加载完成'), findsOneWidget);
    expect(find.text('打开原网站'), findsNothing);
    expect(launcher.launches, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local EPUB loading never offers a source website', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const SourceLoadingIndicator(source: SourceId.localEpub)),
    );
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('打开原网站'), findsNothing);
    expect(find.byType(SourceWebsiteLink), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'website display follows the selected Wenku8 mirror without saving changes',
    (tester) async {
      var writes = 0;
      final host = ApiHostCubit(
        read: () async => 'https://m.wenku8.net',
        write: (_) async {
          writes++;
        },
      );
      await host.initialized;
      addTearDown(host.close);
      await tester.pumpWidget(
        BlocProvider.value(
          value: host,
          child: _app(const SourceWebsiteLink(source: SourceId.wenku8)),
        ),
      );
      expect(find.text('https://m.wenku8.net/'), findsOneWidget);
      await tester.tap(find.text('打开原网站'));
      await tester.pump();
      expect(launcher.launches.single.$1, 'https://m.wenku8.net/');
      expect(writes, 0);
    },
  );

  for (final throws in [false, true]) {
    testWidgets(
      'unavailable external browser is reported safely (throws=$throws)',
      (tester) async {
        launcher.success = false;
        launcher.fail = throws;
        await tester.pumpWidget(
          _app(const SourceWebsiteLink(source: SourceId.bili)),
        );
        await tester.tap(find.text('打开原网站'));
        await tester.pump();
        expect(find.text('无法打开浏览器，可复制网址后手动访问'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'short screens and large text keep the slow-load action scrollable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 200);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 200),
              textScaler: TextScaler.linear(2),
            ),
            child: const Scaffold(
              body: SourceLoadingIndicator(source: SourceId.bili),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 8));
      await tester.ensureVisible(find.text('打开原网站'));
      await tester.pump();
      await tester.tap(find.text('打开原网站'));
      await tester.pump();
      expect(launcher.launches.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final platform in [TargetPlatform.android]) {
    testWidgets(
      'source addresses remain readable with large text on a narrow phone ($platform)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        addTearDown(tester.view.reset);
        final changes = <SourceId>[];
        await tester.pumpWidget(
          MaterialApp(
            theme:
                platform == TargetPlatform.iOS
                    ? iosGlassTheme(Brightness.light)
                    : materialYouTheme(Brightness.light),
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
            home: Scaffold(
              body: MaterialSourcePicker(
                value: SourceId.wenku8,
                sources: const [SourceId.wenku8, SourceId.bili],
                onChanged: changes.add,
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('source-picker-button')));
        await tester.pumpAndSettle();
        expect(find.textContaining('https://www.wenku8.net/'), findsOneWidget);
        final bili = find.byKey(const ValueKey('source-option-bili'));
        await tester.scrollUntilVisible(bili, 150);
        await tester.pumpAndSettle();
        await tester.tap(bili);
        await tester.pumpAndSettle();
        expect(changes, [SourceId.bili]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
    testWidgets(
      'source sheet shows addresses and opening a site does not select it ($platform)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(600, 1000);
        addTearDown(tester.view.reset);
        final host = ApiHostCubit(
          read: () async => 'https://m.wenku8.net',
          write: (_) async {},
        );
        await host.initialized;
        addTearDown(host.close);
        final changes = <SourceId>[];
        await tester.pumpWidget(
          BlocProvider.value(
            value: host,
            child: MaterialApp(
              theme:
                  platform == TargetPlatform.iOS
                      ? iosGlassTheme(Brightness.light)
                      : materialYouTheme(Brightness.light),
              home: Scaffold(
                body: MaterialSourcePicker(
                  value: SourceId.wenku8,
                  sources: [
                    SourceId.wenku8,
                    SourceId.lightNovelShelf,
                    SourceId.bili,
                    SourceId.rule('sfacg_public', label: 'SF轻小说（公开目录）'),
                  ],
                  onChanged: changes.add,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('source-picker-button')));
        await tester.pumpAndSettle();
        for (final url in [
          'https://m.wenku8.net/',
          'https://www.lightnovel.app/',
          'https://www.bilinovel.net/',
          'https://book.sfacg.com/',
        ]) {
          expect(find.textContaining(url), findsOneWidget);
        }
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is AppIconButton && widget.tooltip == '打开哔哩轻小说原网站',
          ),
        );
        await tester.pumpAndSettle();
        expect(changes, isEmpty);
        expect(launcher.launches.single.$1, 'https://www.bilinovel.net/');
        expect(find.text('选择书源'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('source-option-bili')));
        await tester.pumpAndSettle();
        expect(changes, [SourceId.bili]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'iOS native source menu keeps the website outside the menu and follows selection',
    (tester) async {
      final previousSource = activeSource.value;
      activeSource.value = SourceId.wenku8;
      addTearDown(() => activeSource.value = previousSource);
      final auth = AuthCubit();
      final authBefore = auth.state;
      final host = ApiHostCubit(
        read: () async => 'https://m.wenku8.net',
        write: (_) async {},
      );
      await host.initialized;
      addTearDown(auth.close);
      addTearDown(host.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: auth),
            BlocProvider<ApiHostCubit>.value(value: host),
          ],
          child: MaterialApp(
            theme: iosGlassTheme(Brightness.light),
            home: const Scaffold(
              body: SingleChildScrollView(child: SourceSettings()),
            ),
          ),
        ),
      );
      final nativeMenu = find.byType(AppleGlassMenu);
      expect(find.text('https://m.wenku8.net/'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(SourceWebsiteLink)).dy,
        greaterThan(tester.getBottomLeft(nativeMenu).dy),
      );
      final menu = tester.widget<AppleGlassMenu>(nativeMenu);
      expect(
        menu.items.every((item) => !item['label']!.contains('http')),
        isTrue,
      );
      // UIKit invokes this callback on iOS. Its dismissal timing differs from
      // the Material popup used as a desktop-only fallback in widget tests.
      final bili = menu.items.singleWhere((item) => item['label'] == '哔哩轻小说');
      menu.onSelect(bili['value']!);
      await tester.pumpAndSettle();
      expect(activeSource.value, SourceId.bili);
      expect(rustApi.sourceSelections, ['bili']);
      expect(find.text('https://www.bilinovel.net/'), findsOneWidget);
      expect(find.text('https://m.wenku8.net/'), findsNothing);
      await tester.tap(find.text('打开原网站'));
      await tester.pumpAndSettle();
      expect(launcher.launches.single.$1, 'https://www.bilinovel.net/');
      expect(activeSource.value, SourceId.bili);
      expect(auth.state, authBefore);
      expect(rustApi.sourceSelections, ['bili']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'reselecting the current iOS source at large text does not persist or change the website',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);
      final previousSource = activeSource.value;
      activeSource.value = SourceId.wenku8;
      addTearDown(() => activeSource.value = previousSource);
      final auth = AuthCubit();
      addTearDown(auth.close);
      await tester.pumpWidget(
        BlocProvider<AuthCubit>.value(
          value: auth,
          child: MaterialApp(
            theme: iosGlassTheme(Brightness.light),
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
            home: const Scaffold(
              body: SingleChildScrollView(child: SourceSettings()),
            ),
          ),
        ),
      );
      final nativeMenu = find.byType(AppleGlassMenu);
      await tester.ensureVisible(nativeMenu);
      await tester.pumpAndSettle();
      // Exercise the native callback rather than opening a desktop popup route:
      // native UIKit menus do not push a Flutter route or hide the chrome.
      final menu = tester.widget<AppleGlassMenu>(nativeMenu);
      menu.onSelect(menu.selected!);
      await tester.pumpAndSettle();
      expect(activeSource.value, SourceId.wenku8);
      expect(rustApi.sourceSelections, isEmpty);
      expect(find.text('https://www.wenku8.net/'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
