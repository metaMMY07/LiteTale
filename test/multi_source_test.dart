import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/light_novel_shelf_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/services/reader_paginator.dart';

const details = {
  'Book': {
    'Id': 42,
    'Title': '测试分卷',
    'Author': '作者',
    'Cover': '',
    'Introduction': '<p>介绍</p>',
    'Category': {'Name': '轻小说'},
    'Chapter': [
      {'Id': 900, 'Title': '正文'},
      {'Id': 700, 'Title': '后记'},
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => activeSource.value = SourceId.wenku8);

  test(
    'live native adapter loads anonymous book cards',
    () async {
      final original = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = original);
      final blocks = await LightNovelShelfSource().discover();
      expect(blocks.single.list, isNotEmpty);
      expect(
        blocks.single.list.every(
          (b) => b.aid.startsWith('lns:') && b.img.startsWith('https://'),
        ),
        isTrue,
      );
    },
    skip: !const bool.fromEnvironment('LIGHT_NOVEL_SHELF_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test('same remote book number remains isolated by provider', () {
    expect(sourceOf('42'), SourceId.wenku8);
    expect(sourceOf(shelfBookId(42)), SourceId.lightNovelShelf);
    expect(remoteShelfId('lns:42'), 42);
    expect(() => remoteShelfId('42'), throwsFormatException);
  });
  test(
    'live JSON DTO casing and plural chapters map to the native reader',
    () async {
      final source = LightNovelShelfSource(
        invoke: (method, args) async {
          if (method == 'GetBookInfo') {
            return {
              'book': {
                'id': 42,
                'title': '书籍',
                'author': '作者',
                'cover': '',
                'chapters': [
                  {'id': 7, 'sortNum': 1, 'title': '序章'},
                ],
              },
            };
          }
          return {
            'chapter': {'Content': '<p>正文</p>', 'Font': ''},
          };
        },
      );
      final book = await source.detail('lns:42');
      expect(book.info.title, '书籍');
      expect(book.volumes.single.chapters.single.cid, 'lns:42:7');
      expect((await source.chapter('lns:42', 'lns:42:7')).content, '正文');
    },
  );
  test('detail maps stable chapter ids and author into shared models', () {
    final book = shelfDetail(details);
    expect(book.info.author, '作者');
    expect(book.volumes.single.chapters.map((c) => c.cid), [
      'lns:42:900',
      'lns:42:700',
    ]);
    expect(
      book.volumes.single.chapters.every((c) => c.aid == 'lns:42'),
      isTrue,
    );
  });
  test('chapter request uses one-based ordering, not chapter id', () async {
    final calls = <(String, Map<String, Object?>)>[];
    final source = LightNovelShelfSource(
      invoke: (method, args) async {
        calls.add((method, args));
        if (method == 'GetBookInfo') return details;
        return {
          'Chapter': {
            'Content': '<p>文前<img src="https://example.com/p.png">文后</p>',
          },
        };
      },
    );
    final chapter = await source.chapter('lns:42', 'lns:42:700');
    expect(calls.last.$1, 'GetNovelContent');
    expect(calls.last.$2, {'Bid': 42, 'SortNum': 2});
    expect(
      chapter.content,
      '文前<!--image-->https://example.com/p.png<!--image-->文后',
    );
  });
  test(
    'title and author searches use supported server methods and pagination',
    () async {
      final calls = <(String, Map<String, Object?>)>[];
      final source = LightNovelShelfSource(
        invoke: (method, args) async {
          calls.add((method, args));
          return {
            'data': [
              {'Id': 42, 'Title': '书', 'Cover': ''},
            ],
            'totalPages': 3,
          };
        },
      );
      final result = await source.search(' 作者 ', 'author', 2);
      expect(calls.last.$1, 'GetBookListByAuthor');
      expect(calls.last.$2['KeyWords'], '作者');
      expect(result.currentPage, 2);
      expect(result.maxPage, 3);
      expect(result.records.single.aid, 'lns:42');
      await source.search('书', 'articlename', 1);
      expect(calls.last.$1, 'GetBookListByTitle');
    },
  );
  test('HTML retains consecutive images, entities and paragraph order', () {
    final content = shelfReaderContent(
      '<p>前&amp;文</p><img src="/1.png"><img src="//example.com/2.png"><p>后<br>文</p><script>bad()</script>',
    );
    expect(
      content,
      contains(
        '前&文\n<!--image-->https://www.lightnovel.app/1.png<!--image--><!--image-->https://example.com/2.png<!--image-->后\n文',
      ),
    );
    expect(content, isNot(contains('bad')));
    final pages = paginateReaderContent(
      content: content,
      canvasWidth: 300,
      canvasHeight: 500,
      fontSize: 18,
      paragraphSpacing: 8,
      lineHeight: 1.5,
    );
    expect(pages.map((p) => p.isImage), [false, true, true, false]);
  });
  test('provider denial is surfaced without inventing results', () {
    expect(
      () => shelfPayload({'Success': false, 'Msg': 'NoToken'}),
      throwsStateError,
    );
    expect(
      shelfPayload({
        'success': true,
        'response': {'Data': []},
      }),
      {'Data': []},
    );
  });
  test(
    'opening a saved book routes by its id after switching provider',
    () async {
      final original = api.bookSources[SourceId.lightNovelShelf]!;
      final fake = LightNovelShelfSource(
        invoke: (method, args) async => details,
      );
      api.bookSources[SourceId.lightNovelShelf] = fake;
      addTearDown(() => api.bookSources[SourceId.lightNovelShelf] = original);
      activeSource.value = SourceId.wenku8;
      expect((await api.novelInfo(aid: 'lns:42')).title, '测试分卷');
      expect(
        (await api.novelReader(aid: 'lns:42')).single.chapters.first.aid,
        'lns:42',
      );
    },
  );
}
