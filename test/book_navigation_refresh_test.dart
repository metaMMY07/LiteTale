import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/history_cubit.dart';
import 'package:wild/pages/novel/novel_info_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/src/rust/wenku8/models.dart';

class _HistoryApi extends Fake implements RustLibApi {
  late Future<List<ReadingHistory>> Function() read;

  @override
  Future<List<ReadingHistory>> crateApiWenku8ListReadingHistory({
    required int offset,
    required int limit,
  }) => read();
}

ReadingHistory _record(String chapter, {int at = 1, int page = 0}) =>
    ReadingHistory(
      novelId: '42',
      novelName: '样本',
      volumeId: 'v',
      volumeName: '卷',
      chapterId: chapter,
      chapterTitle: chapter,
      lastReadAt: at,
      progress: 0,
      progressPage: page,
      cover: '',
      author: '',
    );

void main() {
  final api = _HistoryApi();
  setUpAll(() => RustLib.initMock(api: api));

  setUp(() {
    final source = activeSource.value;
    final revision = sourceRevision.value;
    activeSource.value = SourceId.wenku8;
    addTearDown(() {
      activeSource.value = source;
      sourceRevision.value = revision;
    });
  });

  test(
    'returning to history keeps rows and rejects an old source result',
    () async {
      api.read = () async => [_record('first')];
      final cubit = HistoryCubit();
      addTearDown(cubit.close);
      await cubit.load();
      final original = cubit.state;
      expect(original, isA<HistoryLoaded>());

      final pending = Completer<List<ReadingHistory>>();
      api.read = () => pending.future;
      final refresh = cubit.load(keepContent: true);
      expect(cubit.state, same(original));
      pending.complete([_record('first')]);
      await refresh;
      expect(cubit.state, same(original));

      api.read = () async => [_record('next')];
      await cubit.load(keepContent: true);
      final updated = cubit.state as HistoryLoaded;
      expect(updated.histories.single.chapterId, 'next');

      final stale = Completer<List<ReadingHistory>>();
      final started = Completer<void>();
      api.read = () {
        started.complete();
        return stale.future;
      };
      final earlier = cubit.load(keepContent: true);
      await started.future;
      sourceRevision.value++;
      api.read = () async => [];
      await cubit.load();
      stale.complete([_record('stale')]);
      await earlier;
      expect((cubit.state as HistoryLoaded).histories, isEmpty);
    },
  );

  test(
    'detail updates only when the reading position actually changes',
    () async {
      var history = _record('first');
      final cubit = NovelInfoCubit(
        '42',
        loadDetail:
            ({required aid}) async => const SourceBookDetail(
              NovelInfo(
                title: '样本',
                author: '',
                status: '',
                finUpdate: '',
                imgUrl: '',
                introduce: '',
                tags: [],
                heat: '',
                trending: '',
                isAnimated: false,
              ),
              [],
            ),
        loadHistory: ({required novelId}) async => history,
      );
      addTearDown(cubit.close);
      await cubit.load();
      final original = cubit.state as NovelInfoLoaded;

      history = _record('first', at: 100);
      await cubit.loadHistory();
      expect(cubit.state, same(original));

      history = _record('first', at: 100, page: 2);
      await cubit.loadHistory();
      final updated = cubit.state as NovelInfoLoaded;
      expect(updated.readingHistory?.progressPage, 2);
      expect(updated.novelInfo, same(original.novelInfo));
      expect(updated.volumes, same(original.volumes));
    },
  );
}
