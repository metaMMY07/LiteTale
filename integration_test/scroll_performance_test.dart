import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/pages/home/recommend_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/widgets/novel_cover_card.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('public recommendation scroll frame timings', (tester) async {
    await app.main();
    final startup = Stopwatch()..start();
    while (find.byType(NavigationBar).evaluate().isEmpty &&
        startup.elapsed < const Duration(seconds: 50)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NavigationBar), findsOneWidget);
    final originalSource = activeSource.value;
    addTearDown(() => api.selectSource(originalSource));
    await api.selectSource(SourceId.lnovel);

    final watch = Stopwatch()..start();
    while (find.byType(NovelCoverCard).evaluate().isEmpty &&
        watch.elapsed < const Duration(seconds: 50)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NovelCoverCard), findsWidgets);

    // Give the first visible images a chance to finish before measuring motion.
    await tester.pump(const Duration(seconds: 2));
    final frames = <FrameTiming>[];
    void record(List<FrameTiming> values) => frames.addAll(values);
    SchedulerBinding.instance.addTimingsCallback(record);
    try {
      final feed = find.byType(RecommendationFeed);
      for (final dy in [-850.0, -850.0, 850.0, 850.0]) {
        await tester.fling(feed, Offset(0, dy), 1400);
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
      }
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(record);
    }

    double p90(Iterable<Duration> durations) {
      final ms = durations.map((d) => d.inMicroseconds / 1000).toList()..sort();
      return ms[((ms.length - 1) * 0.9).round()];
    }

    if (frames.isNotEmpty) {
      final over16ms =
          frames
              .where(
                (frame) => frame.totalSpan > const Duration(milliseconds: 16),
              )
              .length;
      debugPrint(
        'RECOMMEND_SCROLL_TIMINGS '
        'frames=${frames.length} '
        'build_p90_ms=${p90(frames.map((f) => f.buildDuration)).toStringAsFixed(1)} '
        'raster_p90_ms=${p90(frames.map((f) => f.rasterDuration)).toStringAsFixed(1)} '
        'total_over_16ms=$over16ms',
      );
    } else {
      debugPrint('RECOMMEND_SCROLL_TIMINGS unavailable');
    }
    expect(tester.takeException(), isNull);
  });
}
