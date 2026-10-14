import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/category_page.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const groups = [
  TagGroup(title: '分类', tags: ['校园', '冒险']),
];
PageStatsNovelCover emptyPage() =>
    const PageStatsNovelCover(currentPage: 1, maxPage: 1, records: []);

Future<void> show(
  WidgetTester tester, {
  Future<List<TagGroup>> Function()? tags,
  Future<PageStatsNovelCover> Function({
    required String tag,
    required String v,
    required int pageNumber,
  })?
  page,
  Future<void> Function(String, String)? save,
  Future<String> Function(String)? preferences,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: CategoryPage(
        initialTag: '校园',
        tagsLoader: tags ?? () async => groups,
        pageLoader:
            page ??
            ({required tag, required v, required pageNumber}) async =>
                emptyPage(),
        preferenceLoader: preferences ?? (_) async => '',
        preferenceSaver: save ?? (_, __) async {},
      ),
    ),
  ),
);

void main() {
  testWidgets('stalled preferences cannot prevent initial books loading', (
    tester,
  ) async {
    final pending = Completer<String>();
    var calls = 0;
    await show(
      tester,
      preferences: (_) => pending.future,
      page: ({required tag, required v, required pageNumber}) async {
        calls++;
        return emptyPage();
      },
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(calls, 1);
    pending.complete('');
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('rapid selections persist in order without blocking reads', (
    tester,
  ) async {
    final firstWrite = Completer<void>();
    final modes = <String>[], saved = <String>[];
    var writes = 0;
    await show(
      tester,
      page: ({required tag, required v, required pageNumber}) async {
        modes.add(v);
        return emptyPage();
      },
      save: (key, value) async {
        if (writes++ == 0) await firstWrite.future;
        if (key.endsWith('view_mode')) saved.add(value);
      },
    );
    await tester.pump();
    await tester.tap(find.text('热门'));
    await tester.pump();
    await tester.tap(find.text('完结'));
    await tester.pump();
    expect(modes, ['0', '1', '2']);
    expect(saved, isEmpty);
    firstWrite.complete();
    await tester.pump();
    expect(saved, ['1', '2']);
  });

  testWidgets('list success cannot erase a failed category picker', (
    tester,
  ) async {
    final tags = Completer<List<TagGroup>>(),
        page = Completer<PageStatsNovelCover>();
    await show(
      tester,
      tags: () => tags.future,
      page: ({required tag, required v, required pageNumber}) => page.future,
    );
    await tester.pump();
    tags.completeError(StateError('tag failed'));
    await tester.pump();
    page.complete(emptyPage());
    await tester.pump();
    expect(find.text('重试加载分类'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('picker success cannot erase a failed book list', (tester) async {
    final tags = Completer<List<TagGroup>>(),
        page = Completer<PageStatsNovelCover>();
    await show(
      tester,
      tags: () => tags.future,
      page: ({required tag, required v, required pageNumber}) => page.future,
    );
    await tester.pump();
    page.completeError(StateError('book list failed'));
    await tester.pump();
    tags.complete(groups);
    await tester.pump();
    expect(find.textContaining('book list failed'), findsOneWidget);
    expect(find.text('重新加载分类书目'), findsOneWidget);
  });

  testWidgets(
    'changing mode starts a fresh request and ignores stale completion',
    (tester) async {
      final old = Completer<PageStatsNovelCover>(),
          next = Completer<PageStatsNovelCover>();
      final modes = <String>[], saved = <String>[];
      await show(
        tester,
        page: ({required tag, required v, required pageNumber}) {
          modes.add(v);
          return v == '0' ? old.future : next.future;
        },
        save: (key, value) async {
          if (key.endsWith('view_mode')) saved.add(value);
        },
      );
      await tester.pump();
      await tester.tap(find.text('热门'));
      await tester.pump();
      expect(modes, ['0', '1']);
      expect(saved, ['1']);
      next.completeError(StateError('new request failed'));
      await tester.pump();
      old.complete(emptyPage());
      await tester.pump();
      expect(find.textContaining('new request failed'), findsOneWidget);
    },
  );

  testWidgets(
    'leaving while both requests are pending causes no setState after disposal',
    (tester) async {
      final tags = Completer<List<TagGroup>>(),
          page = Completer<PageStatsNovelCover>();
      await show(
        tester,
        tags: () => tags.future,
        page: ({required tag, required v, required pageNumber}) => page.future,
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      tags.complete(groups);
      page.complete(emptyPage());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
