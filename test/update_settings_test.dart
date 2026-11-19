// The browser is mocked at the url_launcher plugin boundary.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:wild/pages/home/about_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/widgets/update_checker.dart';

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String? url,
  String? publishedAt,
  String? revision,
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': url ?? 'https://github.com/metaMMY07/LiteTale/releases/tag/$tag',
  'body': 'Notes for $tag',
  'published_at': publishedAt,
  'target_commitish': revision,
};

UpdateCubit _cubitWith(
  List<Map<String, Object?>> releases, {
  required String currentVersion,
  int statusCode = 200,
}) {
  return UpdateCubit(
    client: MockClient(
      (_) async => http.Response(jsonEncode(releases), statusCode),
    ),
    version: () => currentVersion,
  );
}

class _UpdateBrowser extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    expect(options.mode, PreferredLaunchMode.externalApplication);
    opened.add(url);
    return true;
  }
}

void main() {
  group('update version ordering', () {
    test('orders stable, preview, and numeric development identifiers', () {
      expect(
        compareUpdateVersions('1.2.0', '1.2.0-preview.10'),
        greaterThan(0),
      );
      expect(
        compareUpdateVersions('0.1.9-dev.10', '0.1.9-dev.9'),
        greaterThan(0),
      );
      expect(compareUpdateVersions('0.1.9-dev.2', '0.1.9-dev.11'), lessThan(0));
      expect(
        compareUpdateVersions('v1.10.0', '1.9.99+build.4'),
        greaterThan(0),
      );
      expect(
        compareUpdateVersions('1.2.0-preview.2', '1.2.0-preview.2+ci.8'),
        0,
      );
    });

    test(
      'preview channel selects newer numeric dev tag while stable filters it',
      () async {
        final releases = [
          _release('0.1.9', prerelease: false),
          _release('0.1.10-dev.9', prerelease: true),
          _release('0.1.10-dev.10', prerelease: true),
        ];

        final stable = _cubitWith(releases, currentVersion: '0.1.8');
        addTearDown(stable.close);
        final stableInfo = await stable.checkUpdate(
          force: true,
          channel: 'stable',
        );

        final preview = _cubitWith(releases, currentVersion: '0.1.8');
        addTearDown(preview.close);
        final previewInfo = await preview.checkUpdate(
          force: true,
          channel: 'preview',
        );

        expect(stableInfo?.version, '0.1.9');
        expect(stable.state.phase, UpdatePhase.available);
        expect(previewInfo?.version, '0.1.10-dev.10');
        expect(preview.state.phase, UpdatePhase.available);
      },
    );
  });

  group('release feed handling', () {
    test('stable updates include published fix and build tags', () async {
      final cubit = _cubitWith([
        _release('v1.2.5-build120', publishedAt: '2026-11-17T08:00:00Z'),
        _release('v1.2.5-fix', publishedAt: '2026-11-17T14:39:00Z'),
        _release('v1.2.6-test', prerelease: true),
        _release('v1.2.4-build113'),
      ], currentVersion: '1.2.4');
      addTearDown(cubit.close);

      expect((await cubit.checkUpdate())?.version, 'v1.2.5-fix');
    });

    test(
      'same-version fixes compare against their release snapshot build',
      () async {
        const revision = '6389030147c202796eb637f5fcfb71caae31836d';
        var installedBuild = 120;
        final requests = <Uri>[];
        final cubit = UpdateCubit(
          client: MockClient((request) async {
            requests.add(request.url);
            return request.url.host == 'api.github.com'
                ? http.Response(
                  jsonEncode([_release('v1.2.5-fix', revision: revision)]),
                  200,
                )
                : http.Response('name: wild\nversion: 1.2.5+122\n', 200);
          }),
          version: () => '1.2.5',
          buildNumber: () => installedBuild,
        );
        addTearDown(cubit.close);
        expect((await cubit.checkUpdate())?.version, 'v1.2.5-fix');
        expect(requests, hasLength(2));
        expect(
          requests.last.toString(),
          'https://raw.githubusercontent.com/metaMMY07/LiteTale/$revision/pubspec.yaml',
        );
        installedBuild = 122;
        expect(await cubit.checkUpdate(force: true), isNull);
        expect(cubit.state.phase, UpdatePhase.current);
      },
    );

    test(
      'empty or draft-only feeds report unpublished, never latest',
      () async {
        final empty = _cubitWith([], currentVersion: '1.0.0');
        addTearDown(empty.close);
        expect(await empty.checkUpdate(force: true), isNull);
        expect(empty.state.phase, UpdatePhase.unpublished);
        expect(empty.state.message, isNot('已是最新版本'));

        final draftOnly = _cubitWith([
          _release('9.0.0', draft: true),
        ], currentVersion: '1.0.0');
        addTearDown(draftOnly.close);
        expect(await draftOnly.checkUpdate(force: true), isNull);
        expect(draftOnly.state.phase, UpdatePhase.unpublished);
        expect(draftOnly.state.message, isNot('已是最新版本'));
      },
    );

    test(
      'draft releases are ignored when selecting a published release',
      () async {
        final cubit = _cubitWith([
          _release('9.0.0', draft: true),
          _release('1.5.0'),
        ], currentVersion: '1.0.0');
        addTearDown(cubit.close);

        final info = await cubit.checkUpdate(force: true);

        expect(info?.version, '1.5.0');
        expect(cubit.state.phase, UpdatePhase.available);
      },
    );

    test('HTTP errors are failures, not a current-version result', () async {
      final cubit = _cubitWith([], currentVersion: '1.0.0', statusCode: 503);
      addTearDown(cubit.close);

      expect(await cubit.checkUpdate(force: true), isNull);
      expect(cubit.state.phase, UpdatePhase.failed);
      expect(cubit.state.message, isNot('已是最新版本'));
    });

    test('non-HTTPS or off-repository release URL is rejected', () async {
      for (final unsafeUrl in [
        'http://github.com/metaMMY07/LiteTale/releases/tag/2.0.0',
        'https://evil.example/metaMMY07/LiteTale/releases/tag/2.0.0',
      ]) {
        final cubit = _cubitWith([
          _release('2.0.0', url: unsafeUrl),
        ], currentVersion: '1.0.0');
        addTearDown(cubit.close);

        expect(await cubit.checkUpdate(force: true), isNull);
        expect(cubit.state.phase, UpdatePhase.failed);
        expect(cubit.state.updateInfo, isNull);
        expect(cubit.state.message, isNot('已是最新版本'));
      }
    });
  });

  testWidgets(
    'startup keeps its update through route replacement and prompts once',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final response = Completer<http.Response>();
      var requests = 0;
      final cubit = UpdateCubit(
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
        version: () => '1.2.4',
      );
      addTearDown(cubit.close);
      const page = UpdateChecker(child: Scaffold(body: Text('发现')));
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(navigatorKey: navigator, home: page),
        ),
      );
      void replacePage() => unawaited(
        navigator.currentState!.pushReplacement<void, void>(
          MaterialPageRoute(builder: (_) => page),
        ),
      );
      replacePage();
      await tester.pumpAndSettle();
      response.complete(
        http.Response(jsonEncode([_release('v1.2.5-fix')]), 200),
      );
      await tester.pumpAndSettle();
      expect(find.text('检测到新版本'), findsOneWidget);
      expect(find.text('要更新吗？'), findsOneWidget);
      expect(find.text('打开 GitHub'), findsOneWidget);
      await tester.tap(find.text('暂不'));
      await tester.pumpAndSettle();
      replacePage();
      await tester.pumpAndSettle();
      expect(find.text('检测到新版本'), findsNothing);
      expect(requests, 1);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'manual check shows progress, results, and the configured release',
    (tester) async {
      var response = Completer<http.Response>();
      final cubit = UpdateCubit(
        client: MockClient((_) => response.future),
        version: () => '1.2.4',
        buildNumber: () => null,
      );
      final preferences = SettingsPreferencesCubit(write: (_) async {});
      await preferences.update(
        (settings) =>
            settings.copyWith(autoUpdate: false, updateChannel: 'preview'),
      );
      addTearDown(cubit.close);
      addTearDown(preferences.close);
      final originalBrowser = UrlLauncherPlatform.instance;
      final browser = _UpdateBrowser();
      UrlLauncherPlatform.instance = browser;
      addTearDown(() => UrlLauncherPlatform.instance = originalBrowser);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: cubit),
            BlocProvider.value(value: preferences),
          ],
          child: const MaterialApp(home: UpdateChecker(child: AboutPage())),
        ),
      );

      Future<void> check(http.Response result) async {
        await tester.tap(find.text('检查更新'));
        await tester.pump();
        expect(find.text('正在检查更新…'), findsOneWidget);
        response.complete(result);
        await tester.pumpAndSettle();
        response = Completer<http.Response>();
      }

      expect(cubit.state.phase, UpdatePhase.idle);
      await check(http.Response(jsonEncode([_release('v1.2.4')]), 200));
      expect(find.text('已是最新版本'), findsOneWidget);
      await check(http.Response('[]', 503));
      expect(find.text('检查失败，请检查网络后重试'), findsOneWidget);
      await check(
        http.Response(
          jsonEncode([_release('v1.2.5-test', prerelease: true)]),
          200,
        ),
      );
      expect(find.text('检测到新版本'), findsOneWidget);
      await tester.tap(find.text('打开 GitHub'));
      await tester.pumpAndSettle();
      expect(browser.opened, [
        'https://github.com/metaMMY07/LiteTale/releases/tag/v1.2.5-test',
      ]);
    },
  );
}
