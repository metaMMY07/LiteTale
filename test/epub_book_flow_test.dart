import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/epub_book_flow.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

void main() {
  EpubBookFlow flow(
    List<int> sizes, {
    int maxPages = 64,
    bool deferAhead = false,
    int pageStride = 1,
    Future<SourceChapter> Function(Chapter)? read,
    bool Function()? isCurrent,
  }) => EpubBookFlow(
    chapters: [
      for (var i = 0; i < sizes.length; i++)
        Chapter(aid: 'epub:book', cid: '$i', title: '章$i', url: ''),
    ],
    read: read ?? (c) async => SourceChapter('章${c.cid}'),
    isCurrent: isCurrent ?? () => true,
    maxPages: maxPages,
    deferAhead: deferAhead,
    maxNeighbourChapters: deferAhead ? 1 : 2,
    pageStride: pageStride,
    paginate:
        (c, data) => [
          for (var i = 0; i < sizes[int.parse(c.cid)]; i++)
            ReaderPage(
              content: '${c.cid}/$i',
              isImage: false,
              textStart: i * 10,
              textEnd: (i + 1) * 10,
            ),
        ],
  );

  test(
    'short sections share a book window with no blank spread separator',
    () async {
      final book = flow([1, 2, 1, 2]);
      final start = await book.open('0');
      expect(start.pages.map((p) => p.content), ['0/0', '1/0', '1/1', '2/0']);
      expect(start.pages[1].chapterTitle, '章1');
      final more = (await book.warm(start, 0))!;
      expect(more.pages.map((p) => p.content), [
        '0/0',
        '1/0',
        '1/1',
        '2/0',
        '3/0',
        '3/1',
      ]);
      expect(more.token, same(start.token));
      expect(more.refs.first, same(start.refs.first));
      expect(more.hasBefore, isFalse);
      expect(more.hasAfter, isFalse);
      book.close();
    },
  );

  test(
    'rolling window stays bounded and retains anchor and spread parity',
    () async {
      final reads = <String>[];
      final book = flow(
        List.filled(80, 4),
        maxPages: 32,
        read: (c) async {
          reads.add(c.cid);
          return SourceChapter(c.cid);
        },
      );
      var window = await book.open('0');
      final seen = <String>{};
      for (var turns = 0; turns < 160; turns++) {
        final index = window.index;
        final anchor = window.refs[index];
        seen.add(anchor.page.content);
        final extended = await book.warm(window, index);
        if (extended != null) {
          expect(extended.refs.length, lessThanOrEqualTo(32));
          expect(
            extended.refs[extended.index].page.content,
            anchor.page.content,
          );
          expect(extended.index % 2, index % 2);
          window = extended;
        }
        final next = window.index + 2;
        if (next >= window.pages.length) break;
        window = EpubFlowWindow(
          window.refs,
          next,
          window.token,
          window.chapterCount,
        );
      }
      expect(seen.length, 160);
      expect(reads.length, 80);
      book.close();
    },
  );

  test(
    'resume uses chapter offsets and backwards enters the preceding leaf',
    () async {
      final book = flow([5, 30, 3]);
      final at = await book.open(
        '1',
        position: const ReaderPosition(255, 0, false),
      );
      expect(at.refs[at.index].localIndex, 25);
      expect(at.pages[at.index].chapterId, '1');
      final atStart = await book.open('1');
      expect(atStart.refs[atStart.index - 1].page.content, '0/4');
      expect(await book.across(await book.open('0'), -1), isNull);
      final last = await book.open('2', initialPage: -1);
      expect(await book.across(last, 1), isNull);
      book.close();
    },
  );

  test('broken adjacent section leaves current content readable', () async {
    var fail = true;
    final book = flow(
      [2, 2],
      read: (c) async {
        if (c.cid == '1' && fail) {
          throw const FormatException('broken neighbour');
        }
        return SourceChapter(c.cid);
      },
    );
    final first = await book.open('0');
    expect(first.pages, hasLength(2));
    expect(await book.warm(first, 0), isNull);
    fail = false;
    expect((await book.warm(first, 0))!.pages, hasLength(4));
    expect(first.pages, hasLength(2));
    book.close();
  });

  test(
    'CSS prefetch cannot advance through the book without a page turn',
    () async {
      final reads = <String>[];
      final book = flow(
        List.filled(6, 1),
        deferAhead: true,
        pageStride: 2,
        read: (c) async {
          reads.add(c.cid);
          return SourceChapter(c.cid);
        },
      );
      final first = await book.open('0');
      final next = (await book.warm(first, 0))!;
      expect(next.pages, hasLength(4));
      expect(await book.warm(next, 0), isNull);
      expect(reads, ['0', '1', '2', '3']);
      expect((await book.warm(next, 2))!.pages, hasLength(6));
      book.close();
    },
  );

  test('duplicate reads share work and close rejects a late chapter', () async {
    final gate = Completer<SourceChapter>();
    var count = 0;
    final book = flow(
      [2],
      read: (c) {
        count++;
        return gate.future;
      },
    );
    final a = book.open('0'), b = book.open('0');
    expect(count, 1);
    book.close();
    final rejected = [
      expectLater(a, throwsStateError),
      expectLater(b, throwsStateError),
    ];
    gate.complete(const SourceChapter('late'));
    await Future.wait(rejected);
  });

  test(
    'first spread does not wait for an invisible following chapter',
    () async {
      final gate = Completer<SourceChapter>();
      final reads = <String>[];
      final book = flow(
        [2, 30],
        deferAhead: true,
        pageStride: 2,
        read: (c) {
          reads.add(c.cid);
          return c.cid == '1'
              ? gate.future
              : Future.value(SourceChapter(c.cid));
        },
      );
      final first = await book.open('0');
      expect(first.pages.map((p) => p.content), ['0/0', '0/1']);
      expect(reads, ['0']);
      final warming = book.warm(first, 0);
      await pumpEventQueue();
      expect(reads, ['0', '1']);
      gate.complete(const SourceChapter('next'));
      final next = (await warming)!;
      expect(next.pages[2].content, '1/0');
      expect(next.token, same(first.token));
      expect(next.index, first.index);
      book.close();
    },
  );

  test(
    'a spread still waits for its visible second leaf across chapters',
    () async {
      final reads = <String>[];
      final book = flow(
        [1, 1, 30],
        deferAhead: true,
        pageStride: 2,
        read: (c) async {
          reads.add(c.cid);
          return SourceChapter(c.cid);
        },
      );
      final first = await book.open('0');
      expect(first.pages.map((p) => p.content), ['0/0', '1/0']);
      expect(reads, ['0', '1']);
      expect((await book.warm(first, 0))!.pages[2].content, '2/0');
      book.close();
    },
  );

  test(
    'deferred filling keeps previous content and odd resume spread parity',
    () async {
      final reads = <String>[];
      final book = flow(
        [5, 3, 40],
        deferAhead: true,
        pageStride: 2,
        read: (c) async {
          reads.add(c.cid);
          return SourceChapter(c.cid);
        },
      );
      final first = await book.open('1');
      expect(first.index, 5);
      expect(first.pages[4].content, '0/4');
      expect(first.pages[5].content, '1/0');
      expect(reads, ['1', '0']);
      final warm = (await book.warm(first, first.index))!;
      expect(warm.index % 2, first.index % 2);
      expect(warm.refs[warm.index].page.content, '1/0');
      book.close();
    },
  );
}
