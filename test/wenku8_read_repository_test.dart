import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_read_repository.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const _info = NovelInfo(
  title: '书',
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
const _detail = SourceBookDetail(_info, [
  Volume(
    id: 'v',
    title: '卷',
    chapters: [Chapter(title: '甲', url: '', aid: '1', cid: '2')],
  ),
]);

class _Fixture {
  String host = 'https://www.wenku8.net';
  int session = 0;
  DateTime now = DateTime(2026);
  int details = 0, chapters = 0, prefetches = 0;
  Future<SourceChapter> Function()? chapterResult;
  Future<SourceChapter?> Function(bool Function())? prefetchResult;
  late final repository = Wenku8ReadRepository(
    host: () async => host,
    session: () => session,
    now: () => now,
    detail: (_) async {
      details++;
      return _detail;
    },
    chapter: (_, __) async {
      chapters++;
      return chapterResult == null
          ? const SourceChapter('正文')
          : chapterResult!();
    },
    prefetch: (_, __, current) async {
      prefetches++;
      return prefetchResult == null
          ? const SourceChapter('下一章')
          : prefetchResult!(current);
    },
  );
}

void main() {
  test(
    'closing a foreground reader joined to prefetch never sends a replacement GET',
    () async {
      final f = _Fixture();
      final started = Completer<void>(), result = Completer<SourceChapter?>();
      var current = true;
      f.prefetchResult = (_) {
        started.complete();
        return result.future;
      };
      final prefetch = f.repository.prefetch(
        '1',
        '2',
        isCurrent: () => current,
      );
      await started.future;
      final foreground = f.repository.chapter(
        '1',
        '2',
        isCurrent: () => current,
      );
      final rejected = expectLater(
        foreground,
        throwsA(isA<Wenku8PrefetchDeferred>()),
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      result.complete(null);
      await prefetch;
      await rejected;
      expect(f.chapters, 0);
    },
  );
  test(
    'reopening a book reuses detail and expires after five minutes',
    () async {
      final f = _Fixture();
      await Future.wait([f.repository.detail('1'), f.repository.detail('1')]);
      await f.repository.detail('1');
      expect(f.details, 1);
      f.now = f.now.add(const Duration(minutes: 5));
      await f.repository.detail('1');
      expect(f.details, 2);
    },
  );

  test(
    'successful prefetch is used for reader and return without another GET',
    () async {
      final f = _Fixture();
      await f.repository.prefetch('1', '2', isCurrent: () => true);
      final value = await f.repository.chapter('1', '2');
      expect(value.content, '下一章');
      await f.repository.chapter('1', '3');
      await f.repository.chapter('1', '2');
      expect(f.prefetches, 1);
      expect(f.chapters, 1);
    },
  );

  test('foreground adopts same in-flight speculative chapter', () async {
    final f = _Fixture();
    final started = Completer<void>(), result = Completer<SourceChapter>();
    f.prefetchResult = (_) {
      started.complete();
      return result.future;
    };
    final prefetch = f.repository.prefetch('1', '2', isCurrent: () => true);
    await started.future;
    final foreground = f.repository.chapter('1', '2');
    result.complete(const SourceChapter('一次请求'));
    await prefetch;
    expect((await foreground).content, '一次请求');
    expect(f.chapters, 0);
  });

  test('interrupted speculation yields to normal foreground read', () async {
    final f = _Fixture();
    final started = Completer<void>(), result = Completer<SourceChapter?>();
    f.prefetchResult = (_) {
      started.complete();
      return result.future;
    };
    final prefetch = f.repository.prefetch('1', '2', isCurrent: () => true);
    await started.future;
    final foreground = f.repository.chapter('1', '2');
    await Future<void>.delayed(Duration.zero);
    result.complete(null);
    await prefetch;
    expect((await foreground).content, '正文');
    expect(f.chapters, 1);
  });

  test('account, host, book and chapter isolate cached text', () async {
    final f = _Fixture();
    await f.repository.chapter('1', '2');
    f.session++;
    await f.repository.chapter('1', '2');
    f.host = 'https://wenku8.net';
    await f.repository.chapter('1', '2');
    await f.repository.chapter('3', '2');
    await f.repository.chapter('3', '4');
    expect(f.chapters, 5);
  });

  test('account change rejects late result and does not retain it', () async {
    final f = _Fixture();
    final result = Completer<SourceChapter>(), started = Completer<void>();
    f.chapterResult = () {
      started.complete();
      return result.future;
    };
    final old = f.repository.chapter('1', '2');
    final rejected = expectLater(old, throwsStateError);
    await started.future;
    f.session++;
    f.repository.clear();
    result.complete(const SourceChapter('旧账号'));
    await rejected;
    f.chapterResult = null;
    expect((await f.repository.chapter('1', '2')).content, '正文');
    expect(f.chapters, 2);
  });

  test('silent failed prefetch does not poison a later user retry', () async {
    final f = _Fixture();
    f.prefetchResult = (_) => Future.error(StateError('HTTP 403'));
    await f.repository.prefetch('1', '2', isCurrent: () => true);
    expect((await f.repository.chapter('1', '2')).content, '正文');
    expect(f.prefetches, 1);
    expect(f.chapters, 1);
  });

  test(
    '12 chapter LRU bounds memory while nearby chapters remain cached',
    () async {
      final f = _Fixture();
      for (var i = 1; i <= 13; i++) {
        await f.repository.chapter('1', '$i');
      }
      await f.repository.chapter('1', '13');
      expect(f.chapters, 13);
      await f.repository.chapter('1', '1');
      expect(f.chapters, 14);
    },
  );
}
