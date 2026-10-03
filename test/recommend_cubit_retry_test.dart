import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/recommend_cubit.dart';
import 'package:wild/src/rust/wenku8/models.dart';

void main() {
  test('a failed recommendation load can be retried successfully', () async {
    var attempts = 0;
    final cubit = RecommendCubit(
      loadWenku8: () async {
        attempts++;
        if (attempts == 1) throw Exception('HTTP 403 Forbidden');
        return const [HomeBlock(title: '今日推荐', list: [])];
      },
      loadShelf: (_) async => const [],
    );

    await cubit.load();
    expect(cubit.state, isA<RecommendError>());

    await cubit.load(forceRefresh: true);
    expect(cubit.state, isA<RecommendLoaded>());
    expect((cubit.state as RecommendLoaded).blocks.single.title, '今日推荐');
    expect(attempts, 2);

    await cubit.close();
  });
}
