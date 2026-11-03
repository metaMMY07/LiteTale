import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/apple_reader_panel.dart';
import 'package:wild/widgets/reader_chapter_sheet.dart';
import 'package:wild/widgets/reader_settings_panel.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../test/reader_controls_test.dart' show providers;
import '../test/book_cover_details_test.dart' show volumes;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'native form renders all groups and closing preserves reader route',
    (tester) async {
      expect(Platform.isIOS, true);
      expect(await AppleReaderPanel.available, true);
      late BuildContext reader;
      var selected = '';
      await tester.pumpWidget(
        providers(
          MaterialApp(
            theme: iosGlassTheme(Brightness.dark),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  reader = context;
                  return Column(
                    children: [
                      const Text('当前阅读页'),
                      TextButton(
                        onPressed: () => showReaderSettingsPanel(context),
                        child: const Text('打开设置'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final chapter = await showReaderChapterSheet(
                            context,
                            volumes: volumes,
                            currentAid: 'bili:1',
                            currentCid: 'two',
                          );
                          selected = chapter?.cid ?? '';
                        },
                        child: const Text('打开目录'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(ModalRoute.of(reader)!.isCurrent, false);
      final data = await AppleReaderPanel.channel
          .invokeMapMethod<String, Object?>('testInspect');
      expect(data!['nativeForm'], true);
      expect(
        data['titles'],
        containsAll(['字号', '行高', '段间距', '左侧留白', '右侧留白', '上边距', '下边距', '音量键翻页']),
      );
      await binding.takeScreenshot('native-reader-settings-medium');
      await AppleReaderPanel.channel.invokeMethod<void>('testInspect', {
        'expand': true,
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      await binding.takeScreenshot('native-reader-settings-expanded');
      await AppleReaderPanel.channel.invokeMethod<void>('testCommit', {
        'id': 'size',
        'value': 24.0,
      });
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(reader.read<FontSizeCubit>().state, 24);
      await AppleReaderPanel.channel.invokeMethod<void>('testInspect', {
        'scroll': .42,
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await binding.takeScreenshot('native-reader-settings-middle');
      await AppleReaderPanel.channel.invokeMethod<void>('testClose');
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(ModalRoute.of(reader)!.isCurrent, true);

      // Exercise a fresh modal, select by stable identity and return to the same
      // reader; the callback is dispatched only once native dismissal completes.
      await tester.tap(find.text('打开目录'));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      await binding.takeScreenshot('native-reader-chapters');
      await AppleReaderPanel.channel.invokeMethod<void>('testSelect', {
        'id': '1:0',
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(selected, 'one');
      expect(ModalRoute.of(reader)!.isCurrent, true);

      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      // A Flutter/system back action dismisses only the modal route as well.
      Navigator.of(reader).pop();
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(ModalRoute.of(reader)!.isCurrent, true);
      expect(tester.takeException(), null);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
