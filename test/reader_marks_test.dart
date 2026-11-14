import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/models/reader_mark.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/reader_page.dart' as reader;
import 'package:wild/services/reader_mark_store.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/reader_cover_view.dart';
import 'package:wild/widgets/reader_mark_selection.dart';
import 'package:wild/widgets/reader_marks_panel.dart';
import 'package:wild/widgets/reader_css_marks.dart';

import 'paginated_reader_requests_test.dart' as fixture;
import 'reader_controls_test.dart' show providers;

const _chapter = (aid: 'lns:1', cid: 'a');
const _location = ReaderMarkLocation(_chapter, '甲', ReaderMarkAxis.text, 6);

class _MarkSource implements BookSource {
  const _MarkSource(this.firstChapter, this.secondChapter);
  final String firstChapter, secondChapter;

  @override
  SourceId get id => SourceId.lnovel;

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async =>
      SourceChapter(chapterId == 'a' ? firstChapter : secondChapter);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saved notes and bookmarks survive reload and a failed write', () async {
    final db = <String, String>{};
    var failWrite = false;
    ReaderMarkStore open() => ReaderMarkStore(
      read: (key) async => db[key] ?? '',
      write: (key, value) async {
        if (failWrite) throw StateError('storage failure');
        db[key] = value;
      },
    );
    final first = open();
    await Future.wait([
      first.addBookmark('lns:1', _location, pageNumber: 3),
      first.saveHighlight(
        'lns:1',
        _location,
        quote: 'beta',
        color: ReaderMarkColor.green,
        pageNumber: 4,
      ),
      first.saveHighlight(
        'lns:1',
        _location,
        quote: 'beta',
        color: ReaderMarkColor.pink,
        note: '笔记',
      ),
    ]);
    final second = open();
    await second.load('lns:1');
    await second.load('lns:2');
    final mark = second.marks('lns:1').singleWhere((m) => !m.isBookmark);
    expect(mark.color, ReaderMarkColor.pink);
    expect(mark.note, '笔记');
    expect(mark.pageNumber, 4);
    expect(
      second.marks('lns:1').singleWhere((m) => m.isBookmark).pageNumber,
      3,
    );
    expect(second.marks('lns:2'), isEmpty);
    failWrite = true;
    await expectLater(second.remove('lns:1', mark.id), throwsStateError);
    expect(second.marks('lns:1'), contains(mark));
    failWrite = false;
    await second.remove('lns:1', mark.id);
    final third = open();
    await third.load('lns:1');
    expect(third.marks('lns:1').single.isBookmark, isTrue);
  });

  testWidgets('highlight and bookmark jump by content after repagination', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const quote = 'A unique passage to find.';
    final text =
        '${'Opening paragraph with several words. ' * 110}\n'
        '<!--image-->https://example.invalid/p.png<!--image-->\n\n'
        '${'Several lines lead up to the passage. ' * 100}$quote';
    final cubit = fixture.reader(
      ({required aid, required cid}) async =>
          SourceChapter(cid == 'a' ? text : '另一章'),
      ReadingProgressQueue(write: (_) async {}),
    );
    addTearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });
    await cubit.loadChapter();
    final marked = ReaderMark(
      id: 'a',
      location: _location.at(text.indexOf(quote)),
      createdAt: DateTime(2026),
      quote: quote,
      color: ReaderMarkColor.green,
    );
    expect(await cubit.openMark(marked), isTrue);
    final before = cubit.state as ReaderLoaded;
    expect(before.pages[before.currentPageIndex].content, contains(quote));
    final bookmark = ReaderMark(
      id: 'b',
      location: cubit.markLocation(before),
      createdAt: DateTime(2026),
    );
    tester.view.physicalSize = const Size(680, 870);
    await cubit.reloadCurrentPage();
    await cubit.loadChapter(cid: 'b');
    expect(await cubit.openMark(bookmark), isTrue);
    final bookmarked = cubit.state as ReaderLoaded;
    expect(bookmarked.cid, 'a');
    expect(cubit.markOnPage(bookmarked, bookmark.location), isTrue);
    expect(await cubit.openMark(marked), isTrue);
    final after = cubit.state as ReaderLoaded;
    final page = after.pages[after.currentPageIndex];
    expect(page.markStart, lessThanOrEqualTo(text.indexOf(quote)));
    expect(page.markEnd, greaterThan(text.indexOf(quote)));
    expect(after.pages.length, isNot(before.pages.length));
    expect(cubit.savedMarkPageNumber(marked), after.currentPageIndex + 1);
    await cubit.close();
  });

  testWidgets(
    'iOS reader lists saved marks with their chapter and page and opens them',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 60, bottom: 34);
      addTearDown(tester.view.reset);

      const aid = 'lnv:marks-panel-fixture';
      const quote = 'A unique passage to highlight.';
      final text = '${'Lines before the marked passage.\n' * 60}$quote';
      final secondText = 'Second chapter opening.\n' * 35;
      final oldSource = api.bookSources[SourceId.lnovel]!;
      api.bookSources[SourceId.lnovel] = _MarkSource(text, secondText);
      addTearDown(() => api.bookSources[SourceId.lnovel] = oldSource);

      final memory = <String, String>{};
      ReaderMarkStore openStore() => ReaderMarkStore(
        read: (key) async => memory[key] ?? '',
        write: (key, value) async => memory[key] = value,
      );
      final seed = openStore();
      await seed.saveHighlight(
        aid,
        ReaderMarkLocation(
          (aid: aid, cid: 'a'),
          '甲章',
          ReaderMarkAxis.text,
          text.indexOf(quote),
        ),
        quote: quote,
        note: '原有高亮笔记',
        color: ReaderMarkColor.green,
      );
      await seed.addBookmark(
        aid,
        const ReaderMarkLocation(
          (aid: aid, cid: 'b'),
          '乙章',
          ReaderMarkAxis.text,
          0,
        ),
        quote: 'Second chapter opening.',
        pageNumber: 1,
      );
      seed.dispose();
      final store = openStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        providers(
          BlocProvider(
            create: (_) => FontSettingsCubit(),
            child: MaterialApp(
              theme: iosGlassTheme(Brightness.light),
              home: reader.ReaderPage(
                aid: aid,
                cid: 'a',
                initialTitle: '甲章',
                novelInfo: fixture.info,
                markStore: store,
                volumes: const [
                  Volume(
                    id: 'v',
                    title: '卷',
                    chapters: [
                      Chapter(aid: aid, cid: 'a', title: '甲章', url: ''),
                      Chapter(aid: aid, cid: 'b', title: '乙章', url: ''),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cubit =
          tester.element(find.byType(ReaderCoverView)).read<ReaderCubit>();
      final highlight = store
          .marks(aid)
          .singleWhere((mark) => !mark.isBookmark);
      final targetPage = cubit.savedMarkPageNumber(highlight)!;
      expect(targetPage, greaterThan(1));
      if (!cubit.state.showControls) cubit.toggleControls();
      await tester.pumpAndSettle();

      Future<void> openPanel() async {
        await tester.tap(find.byKey(const ValueKey('reader-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-settings-marks')));
        await tester.pumpAndSettle();
      }

      await openPanel();
      expect(find.text('乙章').hitTestable(), findsOneWidget);
      expect(find.text('保存时第 1 页').hitTestable(), findsOneWidget);
      await tester.tap(find.text('添加当前位置书签'));
      await tester.pumpAndSettle();
      expect(find.text('移除当前位置书签').hitTestable(), findsOneWidget);
      expect(find.text('第 1 页').hitTestable(), findsOneWidget);
      expect(store.marks(aid).first.pageNumber, 1);

      await tester.tap(find.text('高亮'));
      await tester.pumpAndSettle();
      final highlightRow = find.byKey(ValueKey(highlight.id));
      expect(
        find.descendant(of: highlightRow, matching: find.text('甲章')),
        findsOneWidget,
      );
      expect(find.text('原有高亮笔记').hitTestable(), findsOneWidget);
      expect(find.text('第 $targetPage 页').hitTestable(), findsOneWidget);
      await tester.tap(find.text(quote));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, targetPage - 1);

      await openPanel();
      await tester.tap(find.text('乙章'));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).cid, 'b');
      expect((cubit.state as ReaderLoaded).currentPageIndex, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a saved highlight reopens its full range and can be removed in place',
    (tester) async {
      const text = 'Alpha beta gamma.';
      final viewport = GlobalKey();
      final memory = <String, String>{};
      final store = ReaderMarkStore(
        read: (key) async => memory[key] ?? '',
        write: (key, value) async => memory[key] = value,
      );
      final selection = ReaderMarkSelection(
        viewport: viewport,
        book: 'lns:1',
        store: store,
        chapterText: (chapter, axis) => (text: text, encoded: false),
        canSelect: (_) => true,
      );
      addTearDown(selection.dispose);
      final paragraph = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => Stack(
                    key: viewport,
                    children: [
                      Positioned(
                        top: 160,
                        left: 32,
                        child: ReaderMarkedRegion(
                          selection: selection,
                          location: _location.at(0),
                          group: 0,
                          text: text,
                          child: RichText(
                            key: paragraph,
                            text: const TextSpan(
                              text: text,
                              style: TextStyle(
                                fontSize: 22,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 20,
                        left: 20,
                        child: TextButton(
                          onPressed:
                              () => showReaderMarks(
                                context,
                                selection: selection,
                                current: _location,
                              ),
                          child: const Text('打开标记'),
                        ),
                      ),
                      Positioned.fill(
                        child: ReaderMarkLayer(
                          selection: selection,
                          pageNumberAt: (_) => 4,
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      );
      final glyphs =
          paragraph.currentContext!.findRenderObject()! as RenderParagraph;
      final rect =
          glyphs
              .getBoxesForSelection(
                const TextSelection(baseOffset: 7, extentOffset: 8),
              )
              .single
              .toRect();
      final point = glyphs.localToGlobal(rect.center);
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      expect(selection.value?.quote, 'beta');
      expect(find.text('高亮'), findsOneWidget);
      expect(find.text('添加笔记'), findsOneWidget);
      expect(find.text('翻译'), findsNothing);
      expect(find.text('移除'), findsNothing);
      expect(
        find.byKey(const ValueKey('selection-start-handle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-end-handle')),
        findsOneWidget,
      );
      final endGrip = tester.getCenter(
        find.byKey(const ValueKey('selection-end-handle')),
      );
      final nextWord =
          glyphs
              .getBoxesForSelection(
                const TextSelection(baseOffset: 11, extentOffset: 16),
              )
              .single
              .toRect();
      final right = glyphs.localToGlobal(nextWord.bottomRight).dx;
      await tester.dragFrom(endGrip, Offset(right - endGrip.dx, 0));
      await tester.pumpAndSettle();
      expect(selection.value?.quote, startsWith('beta gam'));
      final highlighted = selection.value!.quote;
      await tester.tap(find.text('高亮'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('粉色'));
      await tester.pumpAndSettle();
      expect(store.marks('lns:1').single.color, ReaderMarkColor.pink);
      expect(store.marks('lns:1').single.pageNumber, 4);
      expect(find.text('移除'), findsOneWidget);
      selection.clear();
      await tester.pumpAndSettle();
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      expect(selection.value!.quote, highlighted);
      expect(find.text('移除'), findsOneWidget);
      await tester.tap(find.text('添加笔记'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '这段值得记下来');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.marks('lns:1').single.note, '这段值得记下来');
      expect(store.marks('lns:1').single.color, ReaderMarkColor.pink);
      await tester.tap(find.text('打开标记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加当前位置书签'));
      await tester.pumpAndSettle();
      expect(store.marks('lns:1').where((m) => m.isBookmark), hasLength(1));
      await tester.tap(find.text('移除当前位置书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高亮'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这段值得记下来'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await store.saveHighlight(
        'lns:1',
        _location.at(0),
        quote: 'Alpha',
        color: ReaderMarkColor.yellow,
      );
      await tester.pump();
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(find.text('这段高亮附带的笔记也会删除。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.marks('lns:1'), hasLength(2));
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除高亮'));
      await tester.pumpAndSettle();
      expect(store.marks('lns:1').single.quote, 'Alpha');
      expect(selection.value, isNull);
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      expect(find.text('移除'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('EPUB selection uses the asynchronously loaded DOM glyphs', (
    tester,
  ) async {
    const text = 'previous page / 当前页';
    const start = 16, end = 19;
    final viewport = GlobalKey();
    var geometryReads = 0;
    final store = ReaderMarkStore(
      read: (_) async => '',
      write: (_, _) async {},
    );
    final selection = ReaderMarkSelection(
      viewport: viewport,
      book: 'epub:book',
      store: store,
      chapterText: (chapter, axis) => (text: text, encoded: false),
      canSelect: (group) => group == 1,
    );
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            key: viewport,
            children: [
              Positioned.fill(
                child: ReaderCssMarks(
                  page: ReaderCssPage(
                    key: 'leaf',
                    index: 1,
                    domStart: start,
                    domEnd: end,
                    markText: text,
                    read: () async => Uint8List(0),
                    readMarkGlyphs: () async {
                      geometryReads++;
                      return const [
                        ReaderCssMarkGlyph(
                          16,
                          17,
                          16,
                          19,
                          Rect.fromLTRB(.1, .25, .14, .31),
                        ),
                        ReaderCssMarkGlyph(
                          17,
                          18,
                          16,
                          19,
                          Rect.fromLTRB(.14, .25, .18, .31),
                        ),
                        ReaderCssMarkGlyph(
                          18,
                          19,
                          16,
                          19,
                          Rect.fromLTRB(.18, .25, .22, .31),
                        ),
                      ];
                    },
                  ),
                  selection: selection,
                  group: 1,
                  location: const ReaderMarkLocation(
                    _chapter,
                    '甲',
                    ReaderMarkAxis.epubDom,
                    start,
                  ),
                ),
              ),
              Positioned.fill(child: ReaderMarkLayer(selection: selection)),
            ],
          ),
        ),
      ),
    );
    expect(geometryReads, 0);
    await tester.longPressAt(const Offset(98, 168));
    await tester.pumpAndSettle();
    expect(geometryReads, 1);
    expect(selection.value?.location.offset, start);
    expect(selection.value?.quote, '当前页');
    expect(selection.value?.boxes, hasLength(1));
  });
}
