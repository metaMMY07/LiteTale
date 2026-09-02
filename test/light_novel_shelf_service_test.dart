import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/light_novel_shelf_service.dart';

void main() {
  test('decodes public SignalR payload and normalizes display text', () {
    final books = decodeLightNovelShelfLatestBooks({
      'success': true,
      'response': {
        'data': [
          {
            'Id': 123,
            'Title': '  示例\n轻小说  ',
            'SeriesTitle': ' 示例系列 ',
            'Cover': 'https://example.com/cover.webp',
            'UserName': ' 录入者 ',
            'Category': {'Name': '文库本', 'ShortName': '文库'},
            'LastUpdatedAt': '2026-09-02T00:00:00Z',
          },
        ],
      },
    });

    expect(books, hasLength(1));
    expect(books.single.id, 123);
    expect(books.single.title, '示例 轻小说');
    expect(books.single.seriesTitle, '示例系列');
    expect(books.single.subtitle, '文库本 · 录入者');
    expect(books.single.webUrl, 'https://www.lightnovel.app/book/info/123');
    expect(books.single.lastUpdatedAt, DateTime.utc(2026, 9, 2));
  });

  test('allows missing optional fields and string IDs', () {
    final books = decodeLightNovelShelfLatestBooks({
      'Success': true,
      'Response': {
        'Data': [
          {
            'id': '321',
            'title': '示例',
            'cover': 'https://example.com/cover.webp',
          },
        ],
      },
    });
    expect(books.single.id, 321);
    expect(books.single.subtitle, isEmpty);
    expect(books.single.seriesTitle, isNull);
    expect(books.single.lastUpdatedAt, isNull);
  });

  test('accepts an empty feed', () {
    expect(
      decodeLightNovelShelfLatestBooks({
        'success': true,
        'response': {'data': []},
      }),
      isEmpty,
    );
  });

  test('rejects failed responses', () {
    expect(
      () => decodeLightNovelShelfLatestBooks({
        'success': false,
        'msg': 'user is unauthorized',
      }),
      throwsStateError,
    );
  });

  test('rejects malformed responses instead of showing unusable cards', () {
    for (final result in [
      null,
      {'success': true},
      {'success': true, 'response': {}},
      {
        'success': true,
        'response': {
          'data': [{}],
        },
      },
    ]) {
      expect(
        () => decodeLightNovelShelfLatestBooks(result),
        throwsFormatException,
      );
    }
  });

  test(
    'live anonymous feed can be loaded and cached',
    () async {
      final service = LightNovelShelfService.instance;
      final books = await service.fetchLatestBooks(forceRefresh: true);
      expect(books, isNotEmpty);
      expect(books.length, lessThanOrEqualTo(6));
      expect(
        books.every((book) => book.coverUrl.startsWith('https://')),
        isTrue,
      );
      final cached = await service.fetchLatestBooks();
      expect(cached.map((book) => book.id), books.map((book) => book.id));
    },
    skip: !const bool.fromEnvironment('LIGHT_NOVEL_SHELF_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
