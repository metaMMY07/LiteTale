import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/recommend_cubit.dart';
import 'package:wild/services/huanmeng_api_session.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';

NovelCover cover(int id) =>
    NovelCover(aid: 'hm:$id', detailUrl: 'hm:$id', title: '夹具 $id', img: '');
void main() {
  late SourceId saved;
  late int revision;
  setUp(() {
    saved = activeSource.value;
    revision = sourceRevision.value;
    activeSource.value = SourceId.huanmeng;
  });
  tearDown(() {
    activeSource.value = saved;
    sourceRevision.value = revision;
  });
  test(
    'ESJ native feed starts at page one and continues at page two',
    () async {
      activeSource.value = SourceId.esj;
      final pages = <int>[];
      final cubit = RecommendCubit(
        loadWenku8: () async => throw StateError('Wrong source'),
        loadShelf: (_) async => throw StateError('Wrong source'),
        loadMore: (source, page) async {
          expect(source, SourceId.esj);
          pages.add(page);
          return PageStatsNovelCover(
            currentPage: page,
            maxPage: 2,
            records: [
              NovelCover(
                aid: 'esj:$page',
                detailUrl: '',
                title: '测试 $page',
                img: '',
              ),
            ],
          );
        },
      );
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.loadMore();
      expect(pages, [1, 2]);
      expect((cubit.state as RecommendLoaded).moreBooks.single.aid, 'esj:2');
    },
  );
  test(
    'Huanmeng home starts on page one and loads page two without repeating page one',
    () async {
      final requests = <int>[];
      final cubit = RecommendCubit(
        loadWenku8: () async => throw StateError('Wrong home transport'),
        loadShelf: (_) async => throw StateError('Wrong supplementary source'),
        loadMore: (source, page) async {
          expect(source, SourceId.huanmeng);
          requests.add(page);
          return PageStatsNovelCover(
            currentPage: page,
            maxPage: 2,
            records: page == 1 ? [cover(1), cover(2)] : [cover(2), cover(3)],
          );
        },
      );
      addTearDown(cubit.close);
      await cubit.load();
      final initial = cubit.state as RecommendLoaded;
      expect(initial.page, 1);
      expect(initial.hasMore, isTrue);
      expect(initial.blocks.single.list.map((book) => book.aid), [
        'hm:1',
        'hm:2',
      ]);
      await cubit.loadMore();
      final next = cubit.state as RecommendLoaded;
      expect(requests, [1, 2]);
      expect(next.moreBooks.map((book) => book.aid), ['hm:3']);
      expect(next.hasMore, isFalse);
      await cubit.loadMore();
      expect(requests, [1, 2]);
    },
  );
  test('last first page does not offer another request', () async {
    var calls = 0;
    final cubit = RecommendCubit(
      loadMore: (_, page) async {
        calls++;
        return PageStatsNovelCover(
          currentPage: 1,
          maxPage: 1,
          records: [cover(1)],
        );
      },
    );
    addTearDown(cubit.close);
    await cubit.load();
    await cubit.loadMore();
    expect(calls, 1);
    expect((cubit.state as RecommendLoaded).hasMore, isFalse);
  });
  test(
    'ignored pagination cannot trigger repeated automatic requests',
    () async {
      var calls = 0;
      final cubit = RecommendCubit(
        loadMore: (_, page) async {
          calls++;
          return PageStatsNovelCover(
            currentPage: page,
            maxPage: page + 1,
            records: [cover(1)],
          );
        },
      );
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.loadMore();
      final failed = cubit.state as RecommendLoaded;
      expect(calls, 2);
      expect(failed.moreError, isNotNull);
      expect(failed.moreBooks, isEmpty);
      expect(failed.page, 1);
    },
  );
  test('source switch rejects a late Huanmeng homepage', () async {
    final gate = Completer<PageStatsNovelCover>();
    final cubit = RecommendCubit(loadMore: (_, __) => gate.future);
    addTearDown(cubit.close);
    final pending = cubit.load();
    activeSource.value = SourceId.wenku8;
    sourceRevision.value++;
    gate.complete(
      PageStatsNovelCover(currentPage: 1, maxPage: 1, records: [cover(1)]),
    );
    await pending;
    expect(cubit.state, isA<RecommendLoading>());
  });
  test(
    'page two verification preserves its target and the already visible homepage',
    () async {
      var calls = 0;
      final challenge = HuanmengVerificationRequired(
        Uri.parse(
          'https://www.huanmengacg.com/index.php/bookapi/search?password=chiyu666&page=2&size=20',
        ),
        sourceRevision.value,
      );
      final cubit = RecommendCubit(
        loadMore: (_, page) async {
          calls++;
          if (calls == 2) throw challenge;
          return PageStatsNovelCover(
            currentPage: page,
            maxPage: 2,
            records: [cover(page)],
          );
        },
      );
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.loadMore();
      final failed = cubit.state as RecommendLoaded;
      expect(failed.blocks.single.list.single.aid, 'hm:1');
      expect(failed.moreCause, same(challenge));
      expect(failed.page, 1);
      await cubit.loadMore();
      final recovered = cubit.state as RecommendLoaded;
      expect(recovered.moreCause, isNull);
      expect(recovered.moreError, isNull);
      expect(recovered.moreBooks.single.aid, 'hm:2');
      expect(recovered.page, 2);
    },
  );
}
