import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/novel/novel_info_cubit.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/services/wenku8_read_repository.dart';
import 'package:wild/sources/book_source.dart';

const info = NovelInfo(
  title: 'fixture',
  author: '',
  status: '',
  finUpdate: '',
  imgUrl: '',
  introduce: '',
  tags: [],
  heat: '',
  trending: '',
  isAnimated: false,
);
const volumes = [
  Volume(
    id: '1',
    title: 'fixture',
    chapters: [Chapter(title: 'one', url: '', aid: '1', cid: '2')],
  ),
];
void main() {
  test(
    'detail timeout leaves loading and a late response cannot start a catalog GET',
    () async {
      final stalled = Completer<NovelInfo>();
      var catalogs = 0;
      final cubit = NovelInfoCubit(
        '1',
        loadTimeout: const Duration(milliseconds: 30),
        loadInfo: ({required aid}) => stalled.future,
        loadVolumes: ({required aid}) async {
          catalogs++;
          return volumes;
        },
        loadHistory: ({required novelId}) async => null,
      );
      await cubit.load();
      expect(cubit.state, isA<NovelInfoError>());
      expect((cubit.state as NovelInfoError).message, contains('超时'));
      stalled.complete(info);
      await Future<void>.delayed(Duration.zero);
      expect(catalogs, 0);
      await cubit.close();
    },
  );
  test('failed local history does not hide a readable book', () async {
    final cubit = NovelInfoCubit(
      '1',
      loadInfo: ({required aid}) async => info,
      loadVolumes: ({required aid}) async => volumes,
      loadHistory:
          ({required novelId}) async => throw StateError('fixture db failure'),
    );
    await cubit.load();
    expect(cubit.state, isA<NovelInfoLoaded>());
    expect((cubit.state as NovelInfoLoaded).readingHistory, isNull);
    await cubit.close();
  });
  test('a timed out cached detail is detached and can be retried', () async {
    var calls = 0;
    final old = Completer<SourceBookDetail>();
    final repo = Wenku8ReadRepository(
      host: () async => 'host',
      session: () => 0,
      requestTimeout: const Duration(milliseconds: 25),
      detail:
          (_) async =>
              ++calls == 1 ? old.future : const SourceBookDetail(info, volumes),
      chapter: (_, __) async => const SourceChapter('text'),
      prefetch: (_, __, ___) async => null,
    );
    await expectLater(repo.detail('1'), throwsA(isA<TimeoutException>()));
    expect((await repo.detail('1')).info.title, 'fixture');
    old.complete(const SourceBookDetail(info, []));
    await Future<void>.delayed(Duration.zero);
    expect((await repo.detail('1')).volumes, volumes);
    expect(calls, 2);
  });
}
