import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/bookshelf_unread.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/home/bookshelf_page.dart';
import 'package:wild/pages/home/history_cubit.dart';
import 'package:wild/pages/home/history_page.dart';
import 'package:wild/pages/novel/reader_route.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' show LocalShelfEntry;
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/api/wenku8.dart' show ReadingHistory;
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/novel_card.dart';

const groups = [
  Bookcase(id: '0', title: '全部'),
  Bookcase(id: '1', title: '分组一'),
  Bookcase(id: '2', title: '分组二'),
];
const content = BookcaseDto(
  tip: '',
  items: [
    BookcaseItem(
      aid: '1',
      bid: '10',
      title: 'fixture',
      author: '',
      cid: '2',
      chapterName: '',
    ),
  ],
);

LocalShelfEntry localBook(String id, String title) => (
  book: BookcaseItem(
    aid: id,
    bid: id,
    title: title,
    author: '',
    cid: '',
    chapterName: '',
  ),
  coverUrl: '',
);

class _ShelfStorage extends Fake implements RustLibApi {
  String chapterId = 'first';
  int historyReads = 0;

  @override
  Future<String> crateApiDatabaseLoadProperty({required String key}) async =>
      key == 'litetale.lnovel.local_shelf'
          ? '[{"id":"lnv:98700","title":"旧收藏","cover":"cover"},'
              '{"id":"lns:98700","title":"错源记录"}]'
          : '';

  @override
  Future<ReadingHistory?> crateApiWenku8NovelHistoryById({
    required String novelId,
  }) async {
    historyReads++;
    return ReadingHistory(
      novelId: novelId,
      novelName: '旧收藏',
      volumeId: 'v',
      volumeName: '',
      chapterId: chapterId,
      chapterTitle: '',
      lastReadAt: 1,
      progress: 0,
      progressPage: 0,
      cover: '',
      author: '',
    );
  }
}

class _ShelfCatalogSource extends Fake implements BookSource {
  int detailRequests = 0;

  @override
  SourceId get id => SourceId.lnovel;

  @override
  Future<SourceBookDetail> detail(String bookId) async {
    detailRequests++;
    return SourceBookDetail(
      const NovelInfo(
        title: '旧收藏',
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
      [
        Volume(
          id: 'v',
          title: '',
          chapters: [
            for (final cid in ['first', 'second', 'third'])
              Chapter(title: '', url: '', cid: cid, aid: bookId),
          ],
        ),
      ],
    );
  }
}

void main() {
  test(
    'old favorites and counts reuse disk and the existing detail cache',
    () async {
      final storage = _ShelfStorage();
      RustLib.initMock(api: storage);
      addTearDown(RustLib.dispose);
      final source = _ShelfCatalogSource();
      final original = api.bookSources[source.id]!;
      api.bookSources[source.id] = source;
      addTearDown(() => api.bookSources[source.id] = original);

      final shelf = await api.loadLocalShelf(source.id);
      expect(shelf.single.book.aid, 'lnv:98700');
      expect(shelf.single.coverUrl, 'cover');
      final ids = shelf.map((entry) => entry.book.aid);
      expect(await api.loadShelfUnreadCounts(ids), isEmpty);
      expect(storage.historyReads, 0);
      expect(source.detailRequests, 0);
      await api.loadBookDetail(aid: shelf.single.book.aid);
      expect(await api.loadShelfUnreadCounts(ids), {'lnv:98700': 2});
      storage.chapterId = 'third';
      expect(await api.loadShelfUnreadCounts(ids), isEmpty);
      storage.chapterId = 'unknown';
      expect(await api.loadShelfUnreadCounts(ids), isEmpty);
      expect(source.detailRequests, 1);
    },
  );

  testWidgets(
    'combined shelf opens the original identity and shows only known counts',
    (tester) async {
      final cubit = BookshelfCubit(
        localSources: () => [SourceId.lnovel, SourceId.huanmeng],
        loadLocal:
            (source) async =>
                source == SourceId.lnovel
                    ? [localBook('lnv:1', '百科书目')]
                    : [localBook('hm:1', '幻梦书目')],
        loadUnread: (_) async => {'lnv:1': 5},
      )..setWenku8Enabled(false);
      addTearDown(cubit.close);
      await cubit.loadLocalShelves();
      await cubit.refreshUnreadCounts();
      final discoverySource = activeSource.value;
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            home: const BookshelfPage(),
            routes: {
              '/novel/info':
                  (context) => Scaffold(
                    body: Text(
                      ModalRoute.of(context)!.settings.arguments as String,
                    ),
                  ),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.widgetWithText(NovelCard, '百科书目');
      final second = find.widgetWithText(NovelCard, '幻梦书目');
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      expect(
        find.descendant(of: first, matching: find.text('5')),
        findsOneWidget,
      );
      expect(tester.widget<NovelCard>(second).coverBadge, isNull);

      await tester.tap(find.text('全部书源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('轻小说百科').hitTestable());
      await tester.pumpAndSettle();
      expect(first, findsOneWidget);
      expect(second, findsNothing);
      expect(activeSource.value, discoverySource);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.text('lnv:1'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  test('unread count uses catalog order and an exact chapter anchor', () {
    Volume volume(String id, List<String> ids, {String bookId = 'lnv:1'}) =>
        Volume(
          id: id,
          title: '',
          chapters: [
            for (final cid in ids)
              Chapter(title: '', url: '', cid: cid, aid: bookId),
          ],
        );
    final catalog = [
      volume('v1', ['z9', 'a2']),
      volume('v2', ['p1', 'k8']),
    ];
    expect(unreadChapters(catalog, 'lnv:1', 'a2'), 2);
    expect(unreadChapters(catalog, 'lnv:1', 'k8'), 0);
    expect(unreadChapters(catalog, 'lnv:1', null), 4);
    expect(unreadChapters(catalog, 'lnv:1', 'missing'), isNull);
    expect(
      unreadChapters(
        [
          ...catalog,
          volume('v3', ['z9']),
        ],
        'lnv:1',
        null,
      ),
      isNull,
    );
    expect(
      unreadChapters(
        [
          ...catalog,
          volume('v3', ['a1'], bookId: '1'),
        ],
        'lnv:1',
        null,
      ),
      isNull,
    );
  });

  test('local books survive a failing refresh and Wenku8 sign-out', () async {
    final lateContent = Completer<BookcaseDto>();
    var fail = false, wait = false;
    final cubit = BookshelfCubit(
      scope: () => 0,
      localSources: () => [SourceId.lnovel, SourceId.huanmeng],
      loadLocal: (source) async {
        if (source == SourceId.huanmeng) throw StateError('bad local data');
        return [localBook('lnv:1', 'local')];
      },
      loadCases: () async {
        if (fail) throw Exception('HTTP 429');
        return groups;
      },
      loadCase:
          ({required caseId}) =>
              wait ? lateContent.future : Future.value(content),
      loadUnread: (_) async => {'1': 5, 'lnv:1': 7},
    );
    addTearDown(cubit.close);
    await cubit.loadLocalShelves();
    await cubit.loadBookcases();
    expect(cubit.state.localReadFailed, isTrue);
    expect(cubit.state.getBookBid('lnv:1'), 'lnv:1');
    expect(cubit.state.getBookBid('1'), '10');
    fail = true;
    await cubit.loadBookcases();
    expect(cubit.state.errorMessage, contains('429'));
    expect(cubit.state.getBookBid('lnv:1'), 'lnv:1');
    expect(cubit.state.getBookBid('1'), '10');

    fail = false;
    wait = true;
    final pending = cubit.loadBookcases();
    await Future<void>.delayed(Duration.zero);
    cubit.setWenku8Enabled(false);
    lateContent.complete(content);
    await pending;
    expect(cubit.state.wenku8Books, isEmpty);
    expect(cubit.state.unreadCounts, isNot(contains('1')));
    expect(cubit.state.getBookBid('lnv:1'), 'lnv:1');
  });

  testWidgets(
    'local EPUB entry points are available only on supported platforms',
    (tester) async {
      final shelf = BookshelfCubit(scope: () => 0);
      final history = HistoryCubit();
      addTearDown(shelf.close);
      addTearDown(history.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: shelf),
            BlocProvider.value(value: history),
          ],
          child: const MaterialApp(
            home: Column(
              children: [
                Expanded(child: BookshelfPage()),
                Expanded(child: HistoryPage()),
              ],
            ),
          ),
        ),
      );
      final count = supportsLocalEpub ? findsOneWidget : findsNothing;
      expect(find.text('本地书籍'), count);
      expect(find.text('本地 EPUB'), count);
      if (!supportsLocalEpub) {
        history.showLocal(true);
        expect(history.localOnly, isFalse);
        const aid =
            'epub:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            novelReaderRoute(const RouteSettings(arguments: {'novelId': aid})),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('此设备无法打开本地 EPUB'), findsOneWidget);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  test(
    'one flight refreshes one group; selecting a group reads it on demand',
    () async {
      final admitted = Completer<List<Bookcase>>();
      var lists = 0;
      final reads = <String>[];
      final cubit = BookshelfCubit(
        scope: () => 0,
        loadCases: () {
          lists++;
          return admitted.future;
        },
        loadCase: ({required caseId}) async {
          reads.add(caseId);
          return content;
        },
      );
      final first = cubit.loadBookcases(), duplicate = cubit.loadBookcases();
      expect(identical(first, duplicate), isTrue);
      admitted.complete(groups);
      await Future.wait([first, duplicate]);
      expect(lists, 1);
      expect(reads, ['0']);
      await cubit.selectBookcase('2');
      expect(reads, ['0', '2']);
      expect(cubit.state.currentCaseId, '2');
      expect(cubit.state.wenku8Books.single.aid, '1');
      await cubit.close();
    },
  );
  test(
    '429 refresh preserves loaded books and never launches legacy fallback',
    () async {
      var fail = false;
      final cubit = BookshelfCubit(
        scope: () => 0,
        loadCases: () async {
          if (fail) throw Exception('HTTP 429 Cloudflare\nStack backtrace');
          return groups;
        },
        loadCase: ({required caseId}) async => content,
      );
      await cubit.loadBookcases();
      fail = true;
      await cubit.loadBookcases();
      expect(cubit.state.status, BookshelfStatus.success);
      expect(cubit.state.getCurrentBooks(), content.items);
      expect(cubit.state.errorMessage, contains('429'));
      expect(cubit.state.errorMessage, isNot(contains('backtrace')));
      expect(cubit.state.isRefreshing, isFalse);
      await cubit.close();
    },
  );
  test(
    'account/source changes discard an old success without leaking books',
    () async {
      var scope = 0;
      final old = Completer<BookcaseDto>();
      final cubit = BookshelfCubit(
        scope: () => scope,
        loadCases: () async => groups,
        loadCase:
            ({required caseId}) =>
                scope == 0
                    ? old.future
                    : Future.value(const BookcaseDto(tip: '', items: [])),
      );
      final pending = cubit.loadBookcases();
      await Future<void>.delayed(Duration.zero);
      scope++;
      await cubit.loadBookcases();
      old.complete(content);
      await pending;
      expect(cubit.state.getCurrentBooks(), isEmpty);
      await cubit.close();
    },
  );
  test(
    'a stalled list stops loading and cannot issue a late group request',
    () async {
      final stalled = Completer<List<Bookcase>>();
      var reads = 0;
      final cubit = BookshelfCubit(
        scope: () => 0,
        requestTimeout: const Duration(milliseconds: 25),
        loadCases: () => stalled.future,
        loadCase: ({required caseId}) async {
          reads++;
          return content;
        },
      );
      await cubit.loadBookcases();
      expect(cubit.state.status, BookshelfStatus.error);
      stalled.complete(groups);
      await Future<void>.delayed(Duration.zero);
      expect(reads, 0);
      await cubit.close();
    },
  );
}
