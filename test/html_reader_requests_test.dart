import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/novel/html_reader_cubit.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const book = NovelInfo(
  title: '测试书',
  author: '作者',
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
    id: 'v',
    title: '卷',
    chapters: [
      Chapter(title: '甲', url: '', cid: 'a', aid: 'lns:1'),
      Chapter(title: '乙', url: '', cid: 'b', aid: 'lns:1'),
    ],
  ),
];

void main() {
  test(
    'late chapter and font cannot overwrite newest chapter/history',
    () async {
      final a = Completer<SourceChapter>();
      final b = Completer<SourceChapter>();
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      final reader = HtmlReaderCubit(
        novelInfo: book,
        initialAid: 'lns:1',
        initialCid: 'a',
        initialVolumes: volumes,
        progress: queue,
        sessionGeneration: (_) => 0,
        read:
            ({required aid, required cid}) => cid == 'a' ? a.future : b.future,
      );
      final old = reader.loadChapter();
      final current = reader.loadChapter(cid: 'b');
      b.complete(const SourceChapter('乙正文', fontFamily: '乙字体'));
      await current;
      a.complete(const SourceChapter('甲正文', fontFamily: '甲字体'));
      await old;
      expect((reader.state as HtmlReaderLoaded).cid, 'b');
      expect((reader.state as HtmlReaderLoaded).sourceFont, '乙字体');
      await queue.flush();
      expect(saved.map((p) => p.chapterId), ['b']);
      await reader.close();
    },
  );

  test(
    'late error cannot replace success and close ignores pending work',
    () async {
      final old = Completer<SourceChapter>();
      final queue = ReadingProgressQueue(write: (_) async {});
      final reader = HtmlReaderCubit(
        novelInfo: book,
        initialAid: 'lns:1',
        initialCid: 'a',
        initialVolumes: volumes,
        progress: queue,
        sessionGeneration: (_) => 0,
        read:
            ({required aid, required cid}) =>
                cid == 'a'
                    ? old.future
                    : Future.value(const SourceChapter('乙')),
      );
      final load = reader.loadChapter();
      await reader.loadChapter(cid: 'b');
      old.completeError(StateError('old timeout'));
      await load;
      expect(reader.state, isA<HtmlReaderLoaded>());
      await reader.close();
      await reader.loadChapter();
    },
  );

  test(
    'account replacement ends loading and never saves stale contents',
    () async {
      var generation = 0;
      final result = Completer<SourceChapter>();
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      final reader = HtmlReaderCubit(
        novelInfo: book,
        initialAid: 'lns:1',
        initialCid: 'a',
        initialVolumes: volumes,
        progress: queue,
        sessionGeneration: (_) => generation,
        read: ({required aid, required cid}) => result.future,
      );
      final load = reader.loadChapter();
      generation++;
      result.complete(const SourceChapter('旧账号的正文'));
      await load;
      expect(reader.state, isA<HtmlReaderError>());
      await queue.flush();
      expect(saved, isEmpty);
      await reader.close();
    },
  );

  test('disk latency does not hold chapter in loading state', () async {
    final gate = Completer<void>();
    final queue = ReadingProgressQueue(write: (_) => gate.future);
    final reader = HtmlReaderCubit(
      novelInfo: book,
      initialAid: 'lns:1',
      initialCid: 'a',
      initialVolumes: volumes,
      progress: queue,
      sessionGeneration: (_) => 0,
      read: ({required aid, required cid}) async => const SourceChapter('正文'),
    );
    await reader.loadChapter();
    expect(reader.state, isA<HtmlReaderLoaded>());
    final flush = queue.flush();
    gate.complete();
    await flush;
    await reader.close();
  });

  test(
    'closing while a chapter is pending cannot emit or write afterwards',
    () async {
      final result = Completer<SourceChapter>();
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      final reader = HtmlReaderCubit(
        novelInfo: book,
        initialAid: 'lns:1',
        initialCid: 'a',
        initialVolumes: volumes,
        progress: queue,
        sessionGeneration: (_) => 0,
        read: ({required aid, required cid}) => result.future,
      );
      final load = reader.loadChapter();
      await reader.close();
      result.complete(const SourceChapter('正文'));
      await load;
      await queue.flush();
      expect(saved, isEmpty);
    },
  );
}
