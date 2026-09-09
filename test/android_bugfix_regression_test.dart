import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/pages/search_page.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/app_color_settings.dart';

const empty = PageStatsNovelCover(currentPage: 1, maxPage: 1, records: []);
PageStatsNovelCover books(String name, {int page = 1, int max = 1}) =>
    PageStatsNovelCover(
      currentPage: page,
      maxPage: max,
      records: [NovelCover(title: name, aid: name, img: '', detailUrl: '')],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'image-only and consecutive illustration markers finish in source order',
    () {
      final content = List.generate(
        40,
        (i) => '<!--image-->https://img/$i.jpg<!--image-->',
      ).join('\n');
      final pages = paginateReaderContent(
        content: content,
        canvasWidth: 360,
        canvasHeight: 600,
        fontSize: 20,
        paragraphSpacing: 8,
        lineHeight: 1.4,
      );
      expect(pages.length, 40);
      expect(pages.every((p) => p.isImage), isTrue);
      expect(pages.last.content, 'https://img/39.jpg');
    },
  );
  test(
    'text before and after inline images is retained without empty pages',
    () {
      final pages = paginateReaderContent(
        content: '前文<!--image-->a<!--image--><!--image-->b<!--image-->后文',
        canvasWidth: 360,
        canvasHeight: 600,
        fontSize: 20,
        paragraphSpacing: 8,
        lineHeight: 1.4,
      );
      expect(pages.map((p) => p.content.trim()).toList(), [
        '前文',
        'a',
        'b',
        '后文',
      ]);
    },
  );
  test('a viewport shorter than one text line still makes progress', () {
    final pages = paginateReaderContent(
      content: '第一行\n第二行',
      canvasWidth: 300,
      canvasHeight: 1,
      fontSize: 40,
      paragraphSpacing: 8,
      lineHeight: 2,
    );
    expect(pages.map((p) => p.content).join('').replaceAll('\n', ''), '第一行第二行');
    expect(pages.every((p) => p.content.isNotEmpty), isTrue);
  });
  test('invalid reading area returns an error instead of looping', () {
    expect(
      () => paginateReaderContent(
        content: '文字',
        canvasWidth: 0,
        canvasHeight: 0,
        fontSize: 20,
        paragraphSpacing: 8,
        lineHeight: 1.4,
      ),
      throwsArgumentError,
    );
  });

  test(
    'selected palette persists across restart and late load cannot overwrite selection',
    () async {
      var saved = 'system';
      final read = Completer<String>();
      final cubit = AppAccentCubit(
        read: () => read.future,
        write: (value) async {
          saved = value;
        },
      );
      final loading = cubit.load();
      await cubit.select('rose');
      read.complete('green');
      await loading;
      expect(cubit.state, 'rose');
      final restarted = AppAccentCubit(
        read: () async => saved,
        write: (_) async {},
      );
      await restarted.load();
      expect(restarted.state, 'rose');
      await cubit.close();
      await restarted.close();
    },
  );
  testWidgets(
    'palette selection immediately changes theme and supports small screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cubit = AppAccentCubit(read: () async => '', write: (_) async {});
      addTearDown(cubit.close);
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: BlocBuilder<AppAccentCubit, String>(
            builder:
                (_, accent) => MaterialApp(
                  theme: materialYouTheme(
                    Brightness.light,
                    seedColor: appAccentColors[accent]?.$2,
                  ),
                  home: const Scaffold(
                    body: SingleChildScrollView(child: AppColorSettings()),
                  ),
                ),
          ),
        ),
      );
      final before =
          Theme.of(
            tester.element(find.byType(AppColorSettings)),
          ).colorScheme.primary;
      await tester.tap(find.text('晴空蓝'));
      await tester.pumpAndSettle();
      expect(cubit.state, 'blue');
      expect(
        Theme.of(
          tester.element(find.byType(AppColorSettings)),
        ).colorScheme.primary,
        isNot(before),
      );
      await tester.tap(find.text('跟随系统壁纸'));
      await tester.pumpAndSettle();
      expect(cubit.state, 'system');
      expect(tester.takeException(), isNull);
    },
  );

  for (final submit in ['button', 'keyboard', 'history']) {
    testWidgets(
      '$submit submits the same trimmed search query and displays results',
      (tester) async {
        final request = Completer<PageStatsNovelCover>();
        final calls = <(String, String, int)>[];
        await tester.pumpWidget(
          MaterialApp(
            home: SearchPage(
              historyLoader:
                  () async => [
                    const SearchHistory(
                      searchType: 'articlename',
                      searchKey: '魔女',
                      searchTime: 0,
                    ),
                  ],
              searcher: ({
                required searchType,
                required searchKey,
                required page,
              }) {
                calls.add((searchType, searchKey, page));
                return request.future;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (submit == 'history') {
          await tester.tap(find.text('魔女'));
        } else {
          await tester.enterText(find.byType(TextField), ' 魔女 ');
          if (submit == 'button') {
            await tester.tap(find.byTooltip('执行搜索'));
          } else {
            await tester.testTextInput.receiveAction(TextInputAction.search);
          }
        }
        await tester.pump();
        expect(calls, [('articlename', '魔女', 1)]);
        expect(find.text('正在搜索，请稍候…'), findsOneWidget);
        request.complete(books('魔女之旅'));
        await tester.pumpAndSettle();
        expect(find.text('魔女之旅'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('late old response cannot replace a newer keyword', (
    tester,
  ) async {
    final first = Completer<PageStatsNovelCover>();
    final second = Completer<PageStatsNovelCover>();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          historyLoader: () async => [],
          searcher:
              ({required searchType, required searchKey, required page}) =>
                  searchKey == '旧' ? first.future : second.future,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '旧');
    await tester.tap(find.byTooltip('执行搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '新');
    await tester.tap(find.byTooltip('执行搜索'));
    await tester.pump();
    second.complete(books('新结果'));
    await tester.pumpAndSettle();
    first.complete(books('旧结果'));
    await tester.pumpAndSettle();
    expect(find.text('新结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
  });
  testWidgets(
    'failed next page preserves existing results and retries same page',
    (tester) async {
      final calls = <int>[];
      var fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            historyLoader: () async => [],
            searcher: ({
              required searchType,
              required searchKey,
              required page,
            }) async {
              calls.add(page);
              if (page == 1) return books('已有结果', max: 2);
              if (fail) {
                fail = false;
                throw Exception('network');
              }
              return books('第二页', page: 2, max: 2);
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '关键词');
      await tester.tap(find.byTooltip('执行搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('已有结果'), findsOneWidget);
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(calls, [1, 2, 2]);
      expect(find.text('第二页'), findsOneWidget);
    },
  );
  testWidgets('search controls fit landscape with keyboard', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          historyLoader: () async => [],
          searcher:
              ({
                required searchType,
                required searchKey,
                required page,
              }) async => empty,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '书名');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('执行搜索'), findsOneWidget);
  });
}
