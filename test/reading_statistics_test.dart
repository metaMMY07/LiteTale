import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/settings/reading_session_scope.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/sources/book_source.dart';

void main() {
  group('ReadingStatisticsCubit', () {
    test('serializes property writes in mutation order', () async {
      var now = DateTime(2026, 5, 1, 8);
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final savedSnapshots = <Map<String, dynamic>>[];
      var activeWrites = 0;
      var maxConcurrentWrites = 0;
      var writeCount = 0;
      final cubit = ReadingStatisticsCubit(
        read: () async => '',
        write: (value) async {
          writeCount++;
          activeWrites++;
          maxConcurrentWrites =
              activeWrites > maxConcurrentWrites
                  ? activeWrites
                  : maxConcurrentWrites;
          if (writeCount == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          }
          savedSnapshots.add(jsonDecode(value) as Map<String, dynamic>);
          activeWrites--;
        },
        clock: () => now,
      );
      final start = cubit.startSession('lns:serial', '顺序写入');
      await firstWriteStarted.future;
      final sessionId = cubit.state.events.single.sessionId;
      now = now.add(const Duration(seconds: 20));
      cubit.recordElapsed(sessionId, now);
      final queuedPersist = cubit.persist();
      await Future<void>.delayed(Duration.zero);
      expect(writeCount, 1, reason: '前一条写入未完成时，后续写入应排队');

      releaseFirstWrite.complete();
      await start;
      await queuedPersist;
      expect(maxConcurrentWrites, 1);
      expect(savedSnapshots.first['events'], hasLength(1));
      expect((savedSnapshots.last['events'] as List).length, 2);
      expect(cubit.snapshot().totalSeconds, 20);
      await cubit.close();
    });

    test(
      'starts empty and allocates real time across local day and hour buckets',
      () async {
        var now = DateTime(2026, 9, 30, 23, 59, 30);
        final writes = <String>[];
        final cubit = ReadingStatisticsCubit(
          read: () async => '',
          write: (value) async => writes.add(value),
          clock: () => now,
        );
        await cubit.initialize();
        expect(cubit.snapshot().sessionCount, 0);
        expect(cubit.snapshot().totalSeconds, 0);

        final sessionId = await cubit.startSession('lns:book-1', '本地书');
        now = DateTime(2026, 10, 1, 0, 0, 30);
        cubit.recordElapsed(sessionId, now);
        await cubit.persist();

        final snapshot = cubit.snapshot();
        expect(snapshot.sessionCount, 1);
        expect(snapshot.totalSeconds, 60);
        expect(snapshot.activeDays, 2);
        expect(snapshot.secondsForDay(DateTime(2026, 9, 30)), 30);
        expect(snapshot.secondsForDay(DateTime(2026, 10, 1)), 30);
        expect(snapshot.secondsByHour[23], 30);
        expect(snapshot.secondsByHour[0], 30);
        expect(writes, isNotEmpty);
        final stored = jsonDecode(writes.last) as Map<String, dynamic>;
        expect(stored['version'], readingStatisticsSchemaVersion);
        expect((stored['events'] as List).length, 3);
        await cubit.close();
      },
    );

    test(
      'keeps a true session count while accumulating more time in the same hour',
      () async {
        var now = DateTime(2026, 5, 4, 9);
        final cubit = ReadingStatisticsCubit(
          read: () async => '',
          write: (_) async {},
          clock: () => now,
        );
        final sessionId = await cubit.startSession('lnv:book-2', '百科书');
        now = now.add(const Duration(seconds: 20));
        cubit.recordElapsed(sessionId, now);
        now = now.add(const Duration(seconds: 40));
        cubit.recordElapsed(sessionId, now);
        await cubit.persist();

        expect(cubit.snapshot().sessionCount, 1);
        expect(cubit.snapshot().totalSeconds, 60);
        expect(
          cubit.state.events.where(
            (event) => event.kind == ReadingStatisticsEventKind.duration,
          ),
          hasLength(1),
        );
        await cubit.close();
      },
    );

    test('filters books by source and stores sourceOf(bookId)', () async {
      var now = DateTime(2026, 4, 3, 10);
      final cubit = ReadingStatisticsCubit(
        read: () async => '',
        write: (_) async {},
        clock: () => now,
      );
      final shelfSession = await cubit.startSession('lns:101', '书架来源');
      now = now.add(const Duration(seconds: 12));
      cubit.recordElapsed(shelfSession, now);
      await cubit.endSession(shelfSession, at: now);

      final novelSession = await cubit.startSession('lnv:202', '百科来源');
      now = now.add(const Duration(seconds: 18));
      cubit.recordElapsed(novelSession, now);
      await cubit.endSession(novelSession, at: now);

      expect(cubit.snapshot().totalSeconds, 30);
      expect(cubit.snapshot(source: SourceId.lightNovelShelf).totalSeconds, 12);
      expect(cubit.snapshot(source: SourceId.lnovel).totalSeconds, 18);
      expect(cubit.snapshot(source: SourceId.wenku8).totalSeconds, 0);
      expect(cubit.state.events.map((event) => event.source).toSet(), {
        'lightNovelShelf',
        'lnovel',
      });
      await cubit.close();
    });

    test(
      'restores after restart and merges duplicate ids with max cumulative seconds',
      () async {
        var now = DateTime(2026, 3, 3, 12);
        var stored = '';
        final first = ReadingStatisticsCubit(
          read: () async => stored,
          write: (value) async => stored = value,
          clock: () => now,
        );
        final id = await first.startSession('wenku-9', '文库书');
        now = now.add(const Duration(seconds: 45));
        first.recordElapsed(id, now);
        await first.endSession(id, at: now);
        final original = first.exportJson();
        await first.close();

        final restored = ReadingStatisticsCubit(
          read: () async => stored,
          write: (value) async => stored = value,
          clock: () => now,
        );
        await restored.initialize();
        expect(restored.snapshot().totalSeconds, 45);
        expect(restored.snapshot().sessionCount, 1);

        final newerBackup = jsonDecode(original) as Map<String, dynamic>;
        final backupEvents = newerBackup['events'] as List<dynamic>;
        for (final row in backupEvents.cast<Map<String, dynamic>>()) {
          if (row['kind'] == 'duration') row['seconds'] = 90;
        }
        final changed = jsonEncode(newerBackup);
        expect(await restored.importJsonMerge(changed), 1);
        expect(restored.snapshot().totalSeconds, 90);
        expect(restored.snapshot().sessionCount, 1);
        expect(await restored.importJsonMerge(changed), 0);
        expect(restored.snapshot().totalSeconds, 90);
        await restored.close();
      },
    );

    test(
      'handles malformed persisted JSON without throwing or inventing history',
      () async {
        final cubit = ReadingStatisticsCubit(
          read: () async => '{broken json',
          write: (_) async {},
        );
        await expectLater(cubit.initialize(), completes);
        expect(cubit.state.initialized, isTrue);
        expect(cubit.state.warning, isNotNull);
        expect(cubit.snapshot().sessionCount, 0);
        expect(cubit.snapshot().totalSeconds, 0);
        await cubit.close();
      },
    );
  });

  testWidgets(
    'scope waits for readable content and pauses for covered routes and app background',
    (tester) async {
      var now = DateTime(2026, 2, 1, 10);
      var isReading = false;
      final navigatorKey = GlobalKey<NavigatorState>();
      final cubit = ReadingStatisticsCubit(
        read: () async => '',
        write: (_) async {},
        clock: () => now,
      );
      await cubit.initialize();

      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: StatefulBuilder(
              builder:
                  (context, setState) => ReadingSessionScope(
                    bookId: 'lns:reader-test',
                    title: '正在阅读',
                    isReading: isReading,
                    flushInterval: const Duration(seconds: 2),
                    routeCheckInterval: const Duration(milliseconds: 100),
                    clock: () => now,
                    child: Scaffold(
                      body: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => setState(() => isReading = true),
                              child: const Text('正文已加载'),
                            ),
                            TextButton(
                              onPressed:
                                  () => Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder:
                                          (_) => const Scaffold(
                                            body: Center(child: Text('遮挡路由')),
                                          ),
                                    ),
                                  ),
                              child: const Text('打开新页面'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            ),
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 150));
      expect(cubit.snapshot().sessionCount, 0, reason: '正文尚未加载');

      await tester.tap(find.text('正文已加载'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(cubit.snapshot().sessionCount, 1);
      now = now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 2));
      expect(cubit.snapshot().totalSeconds, 20);

      await tester.tap(find.text('打开新页面'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      final afterCover = cubit.snapshot().totalSeconds;
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 2));
      expect(cubit.snapshot().totalSeconds, afterCover, reason: '頂層路由覆蓋時應暫停');

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      expect(cubit.snapshot().sessionCount, 2);
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 2));
      final beforeBackground = cubit.snapshot().totalSeconds;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 150));
      now = now.add(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 2));
      expect(
        cubit.snapshot().totalSeconds,
        beforeBackground,
        reason: 'app 進入背景後應停止計時',
      );
      expect(cubit.snapshot().sessionCount, 2);
      await cubit.close();
    },
  );
}
