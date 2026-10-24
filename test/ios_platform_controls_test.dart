import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

void main() {
  testWidgets(
    'iOS forms preserve validation and use Cupertino controls',
    (tester) async {
      final form = GlobalKey<FormState>();
      var submitted = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Scaffold(
            body: Form(
              key: form,
              child: Column(
                children: [
                  AppTextFormField(
                    autofillHints: const [AutofillHints.username],
                    validator: (value) => value == 'reader' ? null : '请输入用户名',
                  ),
                  AppButton.filled(
                    onPressed: () {
                      submitted = form.currentState!.validate();
                    },
                    child: const Text('登录'),
                  ),
                  AppSwitch(value: true, onChanged: (_) {}),
                  AppSlider(value: .5, onChanged: (_) {}),
                  AppSegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('文库8')),
                      ButtonSegment(value: 1, label: Text('本地 EPUB')),
                    ],
                    selected: const {0},
                    onSelectionChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CupertinoTextFormFieldRow), findsOneWidget);
      expect(find.byType(CupertinoSwitch), findsOneWidget);
      expect(find.byType(CupertinoSlider), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(SegmentedButton<int>), findsNothing);
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(submitted, isFalse);
      expect(find.text('请输入用户名'), findsOneWidget);
      await tester.enterText(find.byType(CupertinoTextField), 'reader');
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(submitted, isTrue);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Android retains its existing Material controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AppButton.filled(onPressed: () {}, child: const Text('继续')),
                AppSwitch(value: true, onChanged: (_) {}),
                AppSlider(value: .5, onChanged: (_) {}),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(CupertinoSwitch), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'long bookcase selectors scroll instead of truncating',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: AppleGlassFilterBar(
                labels: List.generate(12, (i) => '第${i + 1}组书架'),
                index: 0,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      await tester.drag(
        find.byType(AppleGlassFilterBar),
        const Offset(-240, 0),
      );
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test(
    'iOS uses semantic colors in both appearances and retains selectable accents',
    () {
      for (final brightness in Brightness.values) {
        final theme = iosGlassTheme(brightness);
        expect(
          theme.scaffoldBackgroundColor,
          IosSystemColors.color('background', brightness),
        );
        expect(
          theme.colorScheme.onSurface,
          IosSystemColors.color('label', brightness),
        );
        expect(
          theme.colorScheme.primary,
          IosSystemColors.color('ios-blue', brightness),
        );
        final purple = iosGlassTheme(
          brightness,
          accent: IosSystemColors.accent('ios-purple', brightness),
        );
        expect(
          purple.colorScheme.primary,
          IosSystemColors.color('ios-purple', brightness),
        );
      }
      expect(iosAccentKey('iris'), 'ios-purple');
      expect(iosAccentKey('rose'), 'ios-pink');
    },
  );
}
