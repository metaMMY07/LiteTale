import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/services/reading_progress.dart';

ReadingProgress position(int page, {String book = 'lns:1'}) => ReadingProgress(
  bookId: book,
  title: '小说',
  volumeId: 'v',
  volumeTitle: '卷',
  chapterId: 'c$page',
  chapterTitle: '章$page',
  characters: page * 50,
  page: page,
  cover: '',
  author: '作者',
);

void main() {
  test(
    'fast turns coalesce but different sources remain independent',
    () async {
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      for (var page = 0; page < 100; page++) {
        queue.enqueue(position(page));
      }
      queue.enqueue(position(3, book: 'lnv:1'));
      await queue.flush();
      expect(saved.map((p) => (p.bookId, p.page)), [
        ('lns:1', 99),
        ('lnv:1', 3),
      ]);
    },
  );

  test(
    'slow old save cannot complete after newer write or another mode',
    () async {
      final gate = Completer<void>();
      final writes = <int>[];
      var concurrent = 0;
      final queue = ReadingProgressQueue(
        write: (p) async {
          expect(++concurrent, 1);
          if (p.page == 1) await gate.future;
          writes.add(p.page);
          concurrent--;
        },
      );
      queue.enqueue(position(1));
      final first = queue.flush();
      await Future<void>.delayed(Duration.zero);
      queue.enqueue(position(2));
      queue.enqueue(position(3));
      final second = queue.flush();
      expect(writes, isEmpty);
      gate.complete();
      await Future.wait([first, second]);
      expect(writes, [1, 3]);
      await queue.flush();
    },
  );

  test(
    'bounded flush leaves actual writer serialized until it finishes',
    () async {
      final gate = Completer<void>();
      final writes = <int>[];
      final queue = ReadingProgressQueue(
        write: (p) async {
          if (p.page == 1) await gate.future;
          writes.add(p.page);
        },
      );
      queue.enqueue(position(1));
      expect(
        await queue.flushBounded(timeout: const Duration(milliseconds: 5)),
        isFalse,
      );
      queue.enqueue(position(2));
      final flush = queue.flush();
      expect(writes, isEmpty);
      gate.complete();
      await flush;
      expect(writes, [1, 2]);
    },
  );

  test('failed save is observable and explicit flush can recover it', () async {
    var broken = true;
    final saved = <int>[];
    final queue = ReadingProgressQueue(
      write: (p) async {
        if (broken) throw StateError('disk unavailable');
        saved.add(p.page);
      },
    );
    queue.enqueue(position(4));
    expect(await queue.flushBounded(), isFalse);
    expect(queue.errorFor('lns:1'), isNotNull);
    broken = false;
    expect(await queue.flushBounded(), isTrue);
    expect(saved, [4]);
    expect(queue.errorFor('lns:1'), isNull);
  });

  test('new account invalidates queued position before disk starts', () async {
    var generation = 1;
    final saved = <ReadingProgress>[];
    final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
    queue.enqueue(position(1), isValid: () => generation == 1);
    generation = 2;
    await queue.flush();
    expect(saved, isEmpty);
  });

  test(
    'prefix index preserves text/image anchors and existing progress units',
    () {
      const pages = [
        ReaderPage(content: '甲乙', isImage: false),
        ReaderPage(content: 'a.jpg', isImage: true),
        ReaderPage(content: 'b.jpg', isImage: true),
        ReaderPage(content: '丙丁戊', isImage: false),
      ];
      final index = ReaderPageOffsets(pages);
      for (var i = 0; i < pages.length; i++) {
        final previous = ReaderPosition.at(pages, i);
        expect(index.at(i).textOffset, previous.textOffset);
        expect(index.at(i).precedingImages, previous.precedingImages);
        expect(index.at(i).onImage, previous.onImage);
        expect(index.at(i).pageIn(pages), i);
      }
      expect(
        [for (var i = 0; i < pages.length; i++) index.charactersThrough(i)],
        [2, 2, 2, 5],
      );
    },
  );
}
