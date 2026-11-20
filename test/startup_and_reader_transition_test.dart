import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/android_detail_insets.dart';
import 'package:wild/widgets/app_launch_screen.dart';
import 'package:wild/widgets/reader_speech_scope.dart';
import 'package:wild/widgets/reader_system_ui_scope.dart';

void main() {
  testWidgets(
    'iOS keeps the logo over home until native chrome is ready',
    (tester) async {
      var taps = 0;
      VoidCallback? attached;
      await tester.pumpWidget(
        MaterialApp(
          home: IosStartupTransition(
            homeMounted: true,
            child: Builder(
              builder: (context) {
                attached ??= IosStartupTransition.waitForGlass(context);
                return Center(
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('Home'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final cover = find.byType(AppLaunchScreen);
      expect(cover, findsOneWidget);
      final panels = find.descendant(
        of: cover,
        matching: find.byType(SlideTransition),
      );
      final top = find.descendant(
        of: panels.first,
        matching: find.byType(ColoredBox),
      );
      final bottom = find.descendant(
        of: panels.at(1),
        matching: find.byType(ColoredBox),
      );
      final topAtRest = tester.getTopLeft(top);
      final bottomAtRest = tester.getTopLeft(bottom);
      expect(tester.getSize(top).width, tester.getSize(cover).width);
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getTopLeft(top), topAtRest);
      await tester.tap(find.text('Home'), warnIfMissed: false);
      expect(taps, 0);

      attached!();
      await tester.pump();
      await tester.pump();
      await tester.pump(readerMenuMotionDuration ~/ 2);
      expect(tester.getTopLeft(top).dy, lessThan(topAtRest.dy));
      expect(tester.getTopLeft(bottom).dy, greaterThan(bottomAtRest.dy));
      await tester.pumpAndSettle();
      expect(cover, findsNothing);
      await tester.tap(find.text('Home'));
      expect(taps, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS clears the cover with reduced motion even without a native reply',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: IosStartupTransition(
            homeMounted: true,
            child: Builder(
              builder: (context) {
                IosStartupTransition.waitForGlass(context);
                return const Text('Home');
              },
            ),
          ),
        ),
      );
      expect(find.byType(AppLaunchScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 651));
      await tester.pump();
      expect(find.byType(AppLaunchScreen), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('detail retains its top clearance with system bars hidden', (
    tester,
  ) async {
    final media = ValueNotifier(
      const MediaQueryData(
        size: Size(900, 400),
        devicePixelRatio: 2.625,
        padding: EdgeInsets.only(top: 28),
        viewPadding: EdgeInsets.only(top: 28),
      ),
    );
    addTearDown(media.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: media,
          child: const AndroidDetailInsets(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Text('Details'),
              ),
            ),
          ),
          builder:
              (context, data, child) => MediaQuery(data: data, child: child!),
        ),
      ),
    );
    final detail = find.text('Details');
    final original = tester.getTopLeft(detail);
    expect(original.dy, 28);
    media.value = media.value.copyWith(
      padding: EdgeInsets.zero,
      viewPadding: EdgeInsets.zero,
    );
    await tester.pump();
    expect(tester.getTopLeft(detail), original);
    media.value = media.value.copyWith(
      padding: const EdgeInsets.only(top: 28),
      viewPadding: const EdgeInsets.only(top: 28),
    );
    await tester.pump();
    expect(tester.getTopLeft(detail), original);
  });

  testWidgets(
    'Android enters immersive mode after the reader slide',
    (tester) async {
      final modes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            modes.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      navigator.currentState!.push(
        HorizontalCoverPageRoute<void>(
          builder: (_) => const ReaderSystemUiScope(child: Scaffold()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(modes, isEmpty);
      await tester.pumpAndSettle();
      expect(modes, ['SystemUiMode.immersiveSticky']);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(modes, [
        'SystemUiMode.immersiveSticky',
        'SystemUiMode.edgeToEdge',
      ]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
