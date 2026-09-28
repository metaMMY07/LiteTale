import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/widgets/page_curl_view.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PTQ platform view restores cached pages across repeated turns',
    (tester) async {
      final curlKey = GlobalKey<PageCurlViewState>();
      var page = 1;
      final changes = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: StatefulBuilder(
            builder:
                (context, update) => Scaffold(
                  body: PageCurlView(
                    key: curlKey,
                    pageCount: 3,
                    index: page,
                    paperColor: const Color(0xFF40392F),
                    paperDecoration: const BoxDecoration(
                      color: Color(0xFF40392F),
                    ),
                    onPageChanged: (next) {
                      debugPrint('PTQ test pageChanged: $next');
                      changes.add(next);
                      update(() => page = next);
                    },
                    pageBuilder:
                        (_, index) => Center(
                          child: Text(
                            'PAGE $index',
                            style: const TextStyle(
                              fontSize: 55,
                              color: Color(0xFFF5E9D8),
                            ),
                          ),
                        ),
                  ),
                ),
          ),
        ),
      );

      Future<void> waitFor(bool Function() ready) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed < const Duration(seconds: 30)) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
        expect(ready(), isTrue);
      }

      // A user can tap before the first PNG and AndroidView are ready. Move
      // the Flutter page immediately while the native curl cache warms.
      final firstTurnWatch = Stopwatch()..start();
      await curlKey.currentState!.turn(1);
      expect(page, 2);
      debugPrint(
        'PTQ cold-cache first turn completed in '
        '${firstTurnWatch.elapsedMilliseconds} ms',
      );
      await tester.pump();
      await waitFor(() => !curlKey.currentState!.isTurning);
      await curlKey.currentState!.turn(-1);
      await waitFor(() => page == 1);
      await tester.pump();
      await waitFor(() => !curlKey.currentState!.isTurning);

      await waitFor(() => find.byType(AndroidView).evaluate().isNotEmpty);

      // The first few turns intentionally use the immediate Flutter fallback.
      // Once both adjacent bitmaps are decoded, verify the native path too.
      await waitFor(() => curlKey.currentState!.isNativeInteractive);

      final size = tester.getSize(find.byType(PageCurlView));
      await curlKey.currentState!.turn(1, startY: size.height * 0.18);
      await waitFor(() => page == 2);
      await waitFor(() => !curlKey.currentState!.isTurning);
      await waitFor(() => curlKey.currentState!.isNativeInteractive);

      debugPrint('PTQ test turning backwards');
      await curlKey.currentState!.turn(-1, startY: size.height * 0.8);
      await waitFor(() => page == 1);
      await waitFor(() => !curlKey.currentState!.isTurning);
      await waitFor(() => curlKey.currentState!.isNativeInteractive);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );

      await curlKey.currentState!.turn(1, startY: size.height * 0.82);
      await waitFor(() => page == 2);
      await waitFor(() => !curlKey.currentState!.isTurning);
      expect(changes, [2, 1, 2, 1, 2]);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
