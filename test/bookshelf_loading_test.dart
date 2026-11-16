import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/home/bookshelf_page.dart';
import 'package:wild/pages/home/history_cubit.dart';
import 'package:wild/pages/home/history_page.dart';
import 'package:wild/pages/novel/reader_route.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

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

void main() {
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
