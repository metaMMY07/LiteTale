import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/epub_reader_position.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/services/reading_progress.dart';

final book = 'epub:${'a' * 64}';
final otherBook = 'epub:${'b' * 64}';
String chapter(int index, {String? forBook}) => '${forBook ?? book}:c$index';

void main() {
  test(
    'restart restores the exact consecutive illustration after reflow',
    () async {
      const oldPages = [
        ReaderPage(content: '甲乙丙丁', isImage: false),
        ReaderPage(content: 'first.png', isImage: true),
        ReaderPage(content: 'second.png', isImage: true),
        ReaderPage(content: '戊己', isImage: false),
      ];
      const newPages = [
        ReaderPage(content: '甲乙', isImage: false),
        ReaderPage(content: '丙丁', isImage: false),
        ReaderPage(content: 'first.png', isImage: true),
        ReaderPage(content: 'second.png', isImage: true),
        ReaderPage(content: '戊己', isImage: false),
      ];
      final database = _Properties();
      final original = ReaderPosition.at(oldPages, 2);
      await database.store().write(book, chapter(4), original);
      final restored = await database.store().read(book, chapter(4));
      expect(_fields(restored), (4, 1, true));
      expect(restored!.pageIn(newPages), 3);
      expect(database.values, hasLength(1));
      expect(
        database.values.keys.single,
        'epub_reader_position_v1:${'a' * 64}',
      );
    },
  );

  test(
    'chapter and book identity must both match; another chapter uses history',
    () async {
      final database = _Properties();
      final store = database.store();
      await store.write(book, chapter(2), const ReaderPosition(120, 3, false));
      expect(await store.read(book, chapter(1)), isNull);
      expect(await store.read(otherBook, chapter(2)), isNull);
      expect(database.reads, 0);
      expect(_fields(await store.read(book, chapter(2))), (120, 3, false));

      final restarted = database.store();
      expect(await restarted.read(book, chapter(1)), isNull);
      expect(_fields(await restarted.read(book, chapter(2))), (120, 3, false));
      expect(database.reads, 1);
    },
  );

  test(
    'malformed records, versions, counters and mismatched ids safely fall back',
    () async {
      final valid = _encoded(
        book,
        chapter(2),
        const ReaderPosition(50, 1, true),
      );
      final base = jsonDecode(valid) as Map<String, dynamic>;
      final bad = <String>[
        '',
        '{broken',
        '[]',
        'null',
        ' ' * 2049,
        for (final change in <Map<String, Object?>>[
          {'version': 2},
          {'version': 1.0},
          {'bookId': otherBook},
          {'chapterId': chapter(2, forBook: otherBook)},
          {'chapterId': '$book:c00'},
          {'chapterId': '$book:c1000000'},
          {'textOffset': -1},
          {'textOffset': 32 * 1024 * 1024 + 1},
          {'textOffset': 50.0},
          {'precedingImages': -1},
          {'precedingImages': 100001},
          {'onImage': 'true'},
          {'onImage': null},
        ])
          jsonEncode({...base, ...change}),
      ];
      for (final value in bad) {
        final store = EpubReaderPositionStore(
          readProperty: (_) async => value,
          writeProperty: (_, _) async => fail('a bad read must not write'),
        );
        expect(await store.read(book, chapter(2)), isNull);
      }
    },
  );

  test(
    'invalid caller ids and anchors cannot access unrelated properties',
    () async {
      final database = _Properties();
      final store = database.store();
      for (final (id, cid) in <(String, String)>[
        ('lns:1', 'c0'),
        ('epub:short', 'epub:short:c0'),
        ('epub:${'A' * 64}', 'epub:${'A' * 64}:c0'),
        (book, chapter(0, forBook: otherBook)),
        (book, '$book:c01'),
        (book, '$book:c-1'),
        (book, '$book:c1000000'),
        (book, '$book:c1/path'),
        ('$book\n', '$book\n:c0'),
        (book, '$book:c1\n'),
      ]) {
        expect(await store.read(id, cid), isNull);
        await expectLater(
          store.write(id, cid, const ReaderPosition(0, 0, false)),
          throwsArgumentError,
        );
      }
      await expectLater(store.clear('lns:1'), throwsArgumentError);
      await expectLater(
        store.write(book, chapter(0), const ReaderPosition(-1, 0, false)),
        throwsArgumentError,
      );
      await expectLater(
        store.write(book, chapter(0), const ReaderPosition(0, -1, false)),
        throwsArgumentError,
      );
      expect(database.reads, 0);
      expect(database.values, isEmpty);
    },
  );

  test(
    'a slow property never blocks body display and its one read is shared',
    () async {
      final gate = Completer<String>();
      var reads = 0;
      final store = EpubReaderPositionStore(
        readTimeout: const Duration(milliseconds: 5),
        readProperty: (_) {
          reads++;
          return gate.future;
        },
        writeProperty: (_, _) async {},
      );
      expect(await store.read(book, chapter(1)), isNull);
      expect(await store.read(book, chapter(1)), isNull);
      expect(reads, 1);
      gate.complete(
        _encoded(book, chapter(1), const ReaderPosition(80, 2, true)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(_fields(await store.read(book, chapter(1))), (80, 2, true));
      expect(reads, 1);
    },
  );

  test(
    'a delayed old read cannot overwrite a newer chapter or a cleared book',
    () async {
      for (final clear in [false, true]) {
        final gate = Completer<String>();
        final store = EpubReaderPositionStore(
          readProperty: (_) => gate.future,
          writeProperty: (_, _) async {},
        );
        final old = store.read(book, chapter(1));
        if (clear) {
          await store.clear(book);
        } else {
          await store.write(
            book,
            chapter(2),
            const ReaderPosition(90, 3, false),
          );
        }
        gate.complete(
          _encoded(book, chapter(1), const ReaderPosition(20, 0, true)),
        );
        expect(await old, isNull);
        expect(await store.read(book, chapter(1)), isNull);
        expect(
          _fields(await store.read(book, chapter(2))),
          clear ? null : (90, 3, false),
        );
      }
    },
  );

  test('writes, clear and a subsequent reimport stay serialized', () async {
    final first = Completer<void>();
    final values = <String, String>{};
    final events = <String>[];
    var concurrent = 0;
    final store = EpubReaderPositionStore(
      readProperty: (key) async => values[key] ?? '',
      writeProperty: (key, value) async {
        expect(++concurrent, 1);
        if (events.isEmpty) await first.future;
        events.add(
          value.isEmpty ? 'clear' : (jsonDecode(value)['chapterId'] as String),
        );
        values[key] = value;
        concurrent--;
      },
    );
    final old = store.write(
      book,
      chapter(1),
      const ReaderPosition(10, 0, false),
    );
    await Future<void>.delayed(Duration.zero);
    final removed = store.clear(book);
    final imported = store.write(
      book,
      chapter(2),
      const ReaderPosition(0, 1, true),
    );
    expect(events, isEmpty);
    first.complete();
    await Future.wait([old, removed, imported]);
    expect(events, [chapter(1), 'clear', chapter(2)]);
    expect(await store.read(book, chapter(1)), isNull);
    expect(_fields(await store.read(book, chapter(2))), (0, 1, true));
    await store.clear(book);
    final restarted = EpubReaderPositionStore(
      readProperty: (key) async => values[key] ?? '',
      writeProperty: (_, _) async {},
    );
    expect(await restarted.read(book, chapter(2)), isNull);
  });

  test(
    'a failed property write is reported without poisoning the next write',
    () async {
      var broken = true;
      final store = EpubReaderPositionStore(
        readProperty: (_) async => '',
        writeProperty: (_, _) async {
          if (broken) throw StateError('test disk failure');
        },
      );
      await expectLater(
        store.write(book, chapter(1), const ReaderPosition(10, 0, false)),
        throwsStateError,
      );
      expect(await store.read(book, chapter(1)), isNull);
      broken = false;
      await store.write(book, chapter(2), const ReaderPosition(20, 1, false));
      expect(_fields(await store.read(book, chapter(2))), (20, 1, false));
    },
  );

  test(
    'RAM remembers at most 64 books and reloads an evicted anchor',
    () async {
      final database = _Properties();
      final store = database.store();
      final books = [
        for (var i = 0; i < 65; i++)
          'epub:${i.toRadixString(16).padLeft(64, '0')}',
      ];
      for (var i = 0; i < books.length; i++) {
        await store.write(
          books[i],
          chapter(0, forBook: books[i]),
          ReaderPosition(i, 0, false),
        );
      }
      expect(
        _fields(await store.read(books.last, chapter(0, forBook: books.last))),
        (64, 0, false),
      );
      expect(database.reads, 0);
      expect(
        _fields(
          await store.read(books.first, chapter(0, forBook: books.first)),
        ),
        (0, 0, false),
      );
      expect(database.reads, 1);
    },
  );

  test('history and complete anchors use the same queue order', () async {
    final firstAnchor = Completer<void>();
    final events = <String>[];
    final database = <String, String>{};
    var writes = 0;
    final store = EpubReaderPositionStore(
      readProperty: (key) async => database[key] ?? '',
      writeProperty: (key, value) async {
        if (writes++ == 0) await firstAnchor.future;
        events.add('anchor:${jsonDecode(value)['chapterId']}');
        database[key] = value;
      },
    );
    final queue = ReadingProgressQueue(
      write:
          (p) => p.persist(
            writeHistory: (p) async => events.add('history:${p.chapterId}'),
            positionStore: store,
          ),
    );
    queue.enqueue(_progress(1));
    final first = queue.flush();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['history:${chapter(1)}']);
    queue.enqueue(_progress(2));
    queue.enqueue(_progress(3));
    expect(
      await queue.flushBounded(timeout: const Duration(milliseconds: 5)),
      isFalse,
    );
    expect(events, ['history:${chapter(1)}']);
    firstAnchor.complete();
    await first;
    await queue.flush();
    expect(events, [
      'history:${chapter(1)}',
      'anchor:${chapter(1)}',
      'history:${chapter(3)}',
      'anchor:${chapter(3)}',
    ]);
    expect(_fields(await store.read(book, chapter(3))), (300, 3, true));
  });

  test(
    'nonlocal progress and progress without an anchor preserve the old path',
    () async {
      final histories = <String>[];
      var anchorWrites = 0;
      final store = EpubReaderPositionStore(
        readProperty: (_) async => '',
        writeProperty: (_, _) async => anchorWrites++,
      );
      for (final progress in [
        _progress(1, id: 'lns:1'),
        _progress(2, id: '123'),
        _progress(3, withAnchor: false),
      ]) {
        await progress.persist(
          writeHistory: (p) async => histories.add(p.bookId),
          positionStore: store,
        );
      }
      expect(histories, ['lns:1', '123', book]);
      expect(anchorWrites, 0);
    },
  );

  test(
    'a failed history write never saves the optional anchor first',
    () async {
      var anchorWrites = 0;
      final store = EpubReaderPositionStore(
        readProperty: (_) async => '',
        writeProperty: (_, _) async => anchorWrites++,
      );
      await expectLater(
        _progress(1).persist(
          writeHistory: (_) async => throw StateError('test history failure'),
          positionStore: store,
        ),
        throwsStateError,
      );
      expect(anchorWrites, 0);
    },
  );

  test(
    'discard waits for an active anchor and clear removes it without resurrection',
    () async {
      final gate = Completer<void>();
      final database = <String, String>{};
      final histories = <int>[];
      final store = EpubReaderPositionStore(
        readProperty: (key) async => database[key] ?? '',
        writeProperty: (key, value) async {
          if (value.isNotEmpty) await gate.future;
          database[key] = value;
        },
      );
      final queue = ReadingProgressQueue(
        write:
            (p) => p.persist(
              writeHistory: (p) async => histories.add(p.page),
              positionStore: store,
            ),
      );
      queue.enqueue(_progress(1));
      final flushing = queue.flush();
      await Future<void>.delayed(Duration.zero);
      queue.enqueue(_progress(2));
      final removing = queue.discard(book).then((_) => store.clear(book));
      gate.complete();
      await Future.wait([flushing, removing]);
      await queue.flush();
      expect(histories, [1]);
      expect(await store.read(book, chapter(1)), isNull);
      expect(database.values.single, '');
    },
  );
}

(int, int, bool)? _fields(ReaderPosition? position) =>
    position == null
        ? null
        : (position.textOffset, position.precedingImages, position.onImage);

String _encoded(String id, String cid, ReaderPosition position) => jsonEncode({
  'version': 1,
  'bookId': id,
  'chapterId': cid,
  'textOffset': position.textOffset,
  'precedingImages': position.precedingImages,
  'onImage': position.onImage,
});

ReadingProgress _progress(int page, {String? id, bool withAnchor = true}) =>
    ReadingProgress(
      bookId: id ?? book,
      title: '本地书',
      volumeId: 'v',
      volumeTitle: '目录',
      chapterId: id == null ? chapter(page) : 'remote-$page',
      chapterTitle: '章$page',
      characters: page * 100,
      page: page,
      cover: '',
      author: '作者',
      position: withAnchor ? ReaderPosition(page * 100, page, true) : null,
    );

class _Properties {
  final values = <String, String>{};
  var reads = 0;

  EpubReaderPositionStore store() => EpubReaderPositionStore(
    readProperty: (key) async {
      reads++;
      return values[key] ?? '';
    },
    writeProperty: (key, value) async => values[key] = value,
  );
}
