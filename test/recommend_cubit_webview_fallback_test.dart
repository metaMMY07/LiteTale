import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/recommend_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const _homeBlocks = [
  HomeBlock(
    title: '网页首页推荐',
    list: [
      NovelCover(
        title: '浏览器读取的书',
        img: 'https://img.wenku8.com/101.jpg',
        detailUrl: '/book/101.htm',
        aid: '101',
      ),
    ],
  ),
];

void main() {
  late SourceId previousSource;

  setUp(() {
    previousSource = activeSource.value;
    activeSource.value = SourceId.wenku8;
  });

  tearDown(() {
    activeSource.value = previousSource;
  });

  test(
    'valid browser data replaces a failed API request and survives its late error',
    () async {
      final apiRequest = Completer<List<HomeBlock>>();
      final cubit = RecommendCubit(
        loadWenku8: () => apiRequest.future,
        loadShelf: (_) async => [],
      );
      final pendingLoad = cubit.load();
      await Future<void>.delayed(Duration.zero);

      expect(cubit.showWenku8WebViewFallback(_homeBlocks), isTrue);
      apiRequest.completeError(StateError('HTTP 403 Forbidden'));
      await pendingLoad;

      expect(cubit.state, isA<RecommendLoaded>());
      final state = cubit.state as RecommendLoaded;
      expect(state.isWenku8WebViewFallback, isTrue);
      expect(state.blocks.single.list.single.aid, '101');
      await cubit.close();
    },
  );

  test(
    'late browser data is ignored after switching to another source',
    () async {
      final cubit = RecommendCubit(
        loadWenku8: () async => throw StateError('HTTP 403 Forbidden'),
        loadShelf: (_) async => [],
      );
      await cubit.load();
      expect(cubit.state, isA<RecommendError>());

      activeSource.value = SourceId.lightNovelShelf;
      expect(cubit.showWenku8WebViewFallback(_homeBlocks), isFalse);
      expect(cubit.state, isA<RecommendError>());
      await cubit.close();
    },
  );

  test('an empty browser result cannot clear the retryable error', () async {
    final cubit = RecommendCubit(
      loadWenku8: () async => throw StateError('HTTP 403 Forbidden'),
      loadShelf: (_) async => [],
    );
    await cubit.load();

    expect(cubit.showWenku8WebViewFallback(const []), isFalse);
    expect(cubit.state, isA<RecommendError>());
    await cubit.close();
  });
}
