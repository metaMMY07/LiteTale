import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/reader_chapter_prefetch.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const _volumes = [
  Volume(
    id: '1',
    title: '',
    chapters: [Chapter(title: '', url: '', aid: '1', cid: '1')],
  ),
  Volume(id: 'empty', title: '', chapters: []),
  Volume(
    id: '2',
    title: '',
    chapters: [
      Chapter(title: '', url: '', aid: '1', cid: '2'),
      Chapter(title: '', url: '', aid: '1', cid: '3'),
    ],
  ),
];

void main() {
  test(
    'next chapter crosses empty volumes and respects book and final boundary',
    () {
      expect(ReaderChapterPrefetch.nextChapter('1', '1', _volumes)?.cid, '2');
      expect(ReaderChapterPrefetch.nextChapter('1', '3', _volumes), null);
      expect(ReaderChapterPrefetch.nextChapter('9', '1', _volumes), null);
    },
  );

  testWidgets('only one next chapter, after display grace period', (
    tester,
  ) async {
    final calls = <String>[];
    final p = ReaderChapterPrefetch(({
      required aid,
      required cid,
      required isCurrent,
    }) async {
      calls.add(cid);
    });
    p.schedule(aid: '1', cid: '1', volumes: _volumes, isCurrent: () => true);
    await tester.pump(const Duration(milliseconds: 899));
    expect(calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, ['2']);
    await tester.pump(const Duration(seconds: 8));
    expect(calls, ['2']);
    p.cancel();
  });

  testWidgets(
    'switching chapters replaces queued speculation; closing cancels',
    (tester) async {
      final calls = <String>[];
      final p = ReaderChapterPrefetch(({
        required aid,
        required cid,
        required isCurrent,
      }) async {
        calls.add(cid);
      });
      p.schedule(aid: '1', cid: '1', volumes: _volumes, isCurrent: () => true);
      p.schedule(aid: '1', cid: '2', volumes: _volumes, isCurrent: () => true);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, ['3']);
      p.schedule(aid: '1', cid: '1', volumes: _volumes, isCurrent: () => true);
      p.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, ['3']);
    },
  );

  testWidgets(
    'same foreground chapter adopts active fetch; different chapter invalidates',
    (tester) async {
      late bool Function() stillCurrent;
      final done = Completer<void>();
      final p = ReaderChapterPrefetch(({
        required aid,
        required cid,
        required isCurrent,
      }) {
        stillCurrent = isCurrent;
        return done.future;
      });
      p.schedule(aid: '1', cid: '1', volumes: _volumes, isCurrent: () => true);
      await tester.pump(const Duration(seconds: 1));
      p.foreground('1', '2');
      expect(stillCurrent(), true);
      p.foreground('1', '3');
      expect(stillCurrent(), false);
      done.complete();
      p.cancel();
    },
  );

  testWidgets(
    'session change suppresses pending prefetch; failures never retry',
    (tester) async {
      var current = true;
      var calls = 0;
      final p = ReaderChapterPrefetch(({
        required aid,
        required cid,
        required isCurrent,
      }) async {
        calls++;
        throw StateError('site unavailable');
      });
      p.schedule(
        aid: '1',
        cid: '1',
        volumes: _volumes,
        isCurrent: () => current,
      );
      current = false;
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 0);
      current = true;
      p.schedule(
        aid: '1',
        cid: '1',
        volumes: _volumes,
        isCurrent: () => current,
      );
      await tester.pump(const Duration(seconds: 8));
      expect(calls, 1);
      p.cancel();
    },
  );
}
