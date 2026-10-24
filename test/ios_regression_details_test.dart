import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/recommend_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/services/hardware_turn_buffer.dart';
import 'package:wild/utils/controller_event.dart';
import 'package:wild/widgets/apple_book_cover.dart';

void main() {
  testWidgets('two-line captions align short and long book covers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 125,
                height: 260,
                child: AppleBookCover(
                  title: '短标题',
                  url: '',
                  source: SourceId.bili,
                ),
              ),
              SizedBox(
                width: 125,
                height: 260,
                child: AppleBookCover(
                  title: '这是一个应该占据两行的很长的书名',
                  url: '',
                  source: SourceId.bili,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final frames = find.byKey(const ValueKey('book-cover-frame'));
    expect(
      tester.getRect(frames.at(0)).height,
      tester.getRect(frames.at(1)).height,
    );
    expect(
      tester.getTopLeft(find.text('短标题')).dy,
      tester.getTopLeft(find.text('这是一个应该占据两行的很长的书名')).dy,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('hardware keys survive settling and expire behind modals', (
    tester,
  ) async {
    var active = true, busy = true;
    var now = DateTime(2026);
    final keys = <String>[];
    final buffer = HardwareTurnBuffer(
      active: () => active,
      busy: () => busy,
      now: () => now,
      dispatch: (e) => keys.add(e.key),
    );
    addTearDown(buffer.dispose);
    buffer.add(const ReaderControllerEventArgs('DOWN'));
    buffer.add(const ReaderControllerEventArgs('DOWN'));
    expect(keys, isEmpty);
    busy = false;
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(keys, ['DOWN', 'DOWN']);
    busy = true;
    buffer.add(const ReaderControllerEventArgs('UP'));
    active = false;
    await tester.pump(const Duration(milliseconds: 20));
    active = true;
    busy = false;
    await tester.pump(const Duration(milliseconds: 20));
    expect(keys, ['DOWN', 'DOWN']);
    busy = true;
    buffer.add(const ReaderControllerEventArgs('UP'));
    now = now.add(const Duration(seconds: 2));
    busy = false;
    await tester.pump(const Duration(milliseconds: 20));
    expect(keys, ['DOWN', 'DOWN']);
  });
  test(
    'home pagination merges once and rejects another source late result',
    () async {
      final saved = activeSource.value;
      activeSource.value = SourceId.bili;
      addTearDown(() => activeSource.value = saved);
      NovelCover book(String id) =>
          NovelCover(aid: 'bili:$id', title: id, img: '', detailUrl: '');
      var calls = 0;
      final pending = Completer<PageStatsNovelCover>();
      final cubit = RecommendCubit(
        loadWenku8:
            () async => [
              HomeBlock(title: 'home', list: [book('1')]),
            ],
        loadShelf: (_) async => [],
        loadMore: (_, page) {
          calls++;
          return pending.future;
        },
      );
      addTearDown(cubit.close);
      await cubit.load();
      final loading = cubit.loadMore();
      cubit.loadMore();
      expect(calls, 1);
      pending.complete(
        PageStatsNovelCover(
          currentPage: 1,
          maxPage: 2,
          records: [book('1'), book('2')],
        ),
      );
      await loading;
      expect((cubit.state as RecommendLoaded).moreBooks.map((b) => b.aid), [
        'bili:2',
      ]);
      final late = Completer<PageStatsNovelCover>();
      final next = RecommendCubit(
        loadWenku8: () async => [],
        loadShelf: (_) async => [],
        loadMore: (_, __) => late.future,
      );
      addTearDown(next.close);
      await next.load();
      final request = next.loadMore();
      activeSource.value = SourceId.lnovel;
      late.complete(
        PageStatsNovelCover(currentPage: 1, maxPage: 2, records: [book('3')]),
      );
      await request;
      expect((next.state as RecommendLoaded).moreBooks, isEmpty);
    },
  );
}
