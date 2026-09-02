import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/recommend_cubit.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const shelfBook = LightNovelShelfBook(
  id: 123,
  title: '示例',
  coverUrl: 'https://example.com/cover.webp',
  uploaderName: '',
  category: '',
);

void main() {
  test(
    'slow supplemental feed does not delay existing recommendations',
    () async {
      final shelfResult = Completer<List<LightNovelShelfBook>>();
      final cubit = RecommendCubit(
        loadWenku8: () async => [],
        loadShelf: (_) => shelfResult.future,
      );
      final loading = cubit.load();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state, isA<RecommendLoaded>());
      expect((cubit.state as RecommendLoaded).lightNovelShelfBooks, isEmpty);
      shelfResult.complete([shelfBook]);
      await loading;
      expect((cubit.state as RecommendLoaded).lightNovelShelfBooks, [
        shelfBook,
      ]);
      await cubit.close();
    },
  );

  test('optional source failure leaves Wenku8 available', () async {
    final cubit = RecommendCubit(
      loadWenku8: () async => [],
      loadShelf: (_) async => throw StateError('offline'),
    );
    await cubit.load();
    expect(cubit.state, isA<RecommendLoaded>());
    expect((cubit.state as RecommendLoaded).lightNovelShelfBooks, isEmpty);
    await cubit.close();
  });

  test('supplemental books remain available if Wenku8 is offline', () async {
    final cubit = RecommendCubit(
      loadWenku8: () async => throw StateError('offline'),
      loadShelf: (_) async => [shelfBook],
    );
    await cubit.load();
    expect(cubit.state, isA<RecommendLoaded>());
    expect((cubit.state as RecommendLoaded).lightNovelShelfBooks, [shelfBook]);
    await cubit.close();
  });

  test('a stale request cannot overwrite refreshed results', () async {
    final first = Completer<List<HomeBlock>>();
    var calls = 0;
    final cubit = RecommendCubit(
      loadWenku8: () => calls++ == 0 ? first.future : Future.value([]),
      loadShelf: (refresh) async => refresh ? [shelfBook] : [],
    );
    final staleRequest = cubit.load();
    await cubit.load(forceRefresh: true);
    first.complete([]);
    await staleRequest;
    expect((cubit.state as RecommendLoaded).lightNovelShelfBooks, [shelfBook]);
    await cubit.close();
  });

  test('completion after closing the page is ignored', () async {
    final first = Completer<List<HomeBlock>>();
    final cubit = RecommendCubit(
      loadWenku8: () => first.future,
      loadShelf: (_) async => [],
    );
    final loading = cubit.load();
    await cubit.close();
    first.complete([]);
    await loading;
  });
}
