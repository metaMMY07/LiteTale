import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/pages/update_cubit.dart';

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String? url,
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': url ?? 'https://github.com/metaMMY07/LiteTale/releases/tag/$tag',
  'body': 'Notes for $tag',
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
}
