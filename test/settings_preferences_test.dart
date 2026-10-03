import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/settings/settings_preferences.dart';

void main() {
  group('SettingsPreferencesCubit persistence', () {
    test(
      'rapid edits serialize complete states without losing earlier changes',
      () async {
        final firstWriteStarted = Completer<void>();
        final releaseFirstWrite = Completer<void>();
        final stored = <String>[];
        var inFlight = 0;
        var maximumInFlight = 0;

        final cubit = SettingsPreferencesCubit(
          read: () async => '',
          write: (value) async {
            inFlight++;
            if (inFlight > maximumInFlight) maximumInFlight = inFlight;
            try {
              if (stored.isEmpty) {
                firstWriteStarted.complete();
                await releaseFirstWrite.future;
              }
              stored.add(value);
            } finally {
              inFlight--;
            }
          },
        );
        addTearDown(cubit.close);

        final disableUpdates = cubit.update(
          (settings) => settings.copyWith(autoUpdate: false),
        );
        await firstWriteStarted.future;

        final selectPreview = cubit.update(
          (settings) => settings.copyWith(updateChannel: 'preview'),
        );
        final selectTraditional = cubit.update(
          (settings) => settings.copyWith(hanVariant: 'zh-TW'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          stored,
          isEmpty,
          reason: 'later writes wait for the in-flight write',
        );

        releaseFirstWrite.complete();
        await Future.wait([disableUpdates, selectPreview, selectTraditional]);

        final snapshots =
            stored
                .map((value) => jsonDecode(value) as Map<String, dynamic>)
                .toList();
        expect(maximumInFlight, 1);
        expect(snapshots, hasLength(3));
        expect(snapshots[0]['autoUpdate'], isFalse);
        expect(snapshots[0]['updateChannel'], 'stable');
        expect(snapshots[1]['autoUpdate'], isFalse);
        expect(snapshots[1]['updateChannel'], 'preview');
        expect(snapshots[2]['autoUpdate'], isFalse);
        expect(snapshots[2]['updateChannel'], 'preview');
        expect(snapshots[2]['hanVariant'], 'zh-TW');
        expect(cubit.state.autoUpdate, isFalse);
        expect(cubit.state.updateChannel, 'preview');
        expect(cubit.state.hanVariant, 'zh-TW');
        expect(readerHanLocale?.languageCode, 'zh');
        expect(readerHanLocale?.countryCode, 'TW');
      },
    );

    test(
      'a failed write does not publish the requested value and queue recovers',
      () async {
        var attempts = 0;
        final initial = const SettingsPreferences(hanVariant: 'zh-HK');
        final cubit = SettingsPreferencesCubit(
          read: () async => jsonEncode(initial.toJson()),
          write: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('storage unavailable');
          },
        );
        addTearDown(cubit.close);
        await cubit.initialize();

        expect(cubit.state.hanVariant, 'zh-HK');
        expect(readerHanLocale?.countryCode, 'HK');

        await expectLater(
          cubit.update((settings) => settings.copyWith(hanVariant: 'zh-TW')),
          throwsA(isA<StateError>()),
        );

        expect(cubit.state.hanVariant, 'zh-HK');
        expect(readerHanLocale?.countryCode, 'HK');

        await cubit.update((settings) => settings.copyWith(blackTheme: true));
        expect(attempts, 2);
        expect(cubit.state.blackTheme, isTrue);
        expect(cubit.state.hanVariant, 'zh-HK');
        expect(readerHanLocale?.countryCode, 'HK');
      },
    );

    test(
      'invalid stored JSON falls back to usable defaults at startup',
      () async {
        final cubit = SettingsPreferencesCubit(
          read: () async => '{not valid json',
          write: (_) async {},
        );
        addTearDown(cubit.close);

        await cubit.initialize();

        expect(cubit.state.autoUpdate, isTrue);
        expect(cubit.state.updateChannel, 'stable');
        expect(cubit.state.hanVariant, 'system');
        expect(cubit.state.logLevel, 'error');
        expect(cubit.state.blackTheme, isFalse);
        expect(readerHanLocale, isNull);
      },
    );
  });
}
