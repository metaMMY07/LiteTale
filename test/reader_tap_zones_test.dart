import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/html_reader_page.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/reader_page.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/reader_cover_view.dart';
import 'package:wild/widgets/reader_controls.dart';

import 'paginated_reader_requests_test.dart' show info;
import 'reader_controls_test.dart' show providers;

class _ReaderTapSource implements BookSource {
  _ReaderTapSource([this.content]);
  final String? content;

  @override
  SourceId get id => SourceId.lnovel;

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async =>
      SourceChapter(
        content ?? List.filled(100, '这是阅读点击区的离线测试内容。' * 10).join('\n'),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const image = '<!--image-->test://illustration<!--image-->';

  testWidgets(
    'iOS portrait reader turns forward from the upper right',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = api.bookSources[SourceId.lnovel]!;
      api.bookSources[SourceId.lnovel] = _ReaderTapSource();
      addTearDown(() => api.bookSources[SourceId.lnovel] = old);

      const aid = 'lnv:tap-zones-fixture';
      const cid = 'a';
      await tester.pumpWidget(
        providers(
          BlocProvider(
            create: (_) => FontSettingsCubit(),
            child: MaterialApp(
              home: ReaderPage(
                aid: aid,
                cid: cid,
                initialTitle: '正文',
                initialPage: 1,
                novelInfo: info,
                volumes: const [
                  Volume(
                    id: 'v',
                    title: '卷',
                    chapters: [
                      Chapter(aid: aid, cid: cid, title: '正文', url: ''),
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
      ReaderLoaded loaded() => cubit.state as ReaderLoaded;
      expect(loaded().currentPageIndex, 1);

      await tester.tapAt(const Offset(350, 120));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, 2);

      await tester.tapAt(const Offset(40, 120));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, 1);

      await tester.tapAt(const Offset(240, 120));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, 1);
      expect(loaded().showControls, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('an image on the right leaf blocks menu taps across the spread', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final old = api.bookSources[SourceId.lnovel]!;
    api.bookSources[SourceId.lnovel] = _ReaderTapSource('左页正文\n$image\n后续正文');
    addTearDown(() => api.bookSources[SourceId.lnovel] = old);

    const aid = 'lnv:image-spread-taps';
    const cid = 'a';
    final preferences = SettingsPreferencesCubit(write: (_) async {});
    addTearDown(preferences.close);
    await tester.pumpWidget(
      providers(
        BlocProvider.value(
          value: preferences,
          child: BlocProvider(
            create: (_) => FontSettingsCubit(),
            child: MaterialApp(
              home: ReaderPage(
                aid: aid,
                cid: cid,
                initialTitle: '正文',
                novelInfo: info,
                volumes: const [
                  Volume(
                    id: 'v',
                    title: '卷',
                    chapters: [
                      Chapter(aid: aid, cid: cid, title: '正文', url: ''),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cubit =
        tester.element(find.byType(ReaderCoverView)).read<ReaderCubit>();
    ReaderLoaded loaded() => cubit.state as ReaderLoaded;
    expect(loaded().layout.isSpread, isTrue);
    expect(loaded().pages[1].isImage, isTrue);

    const leftMiddle = Offset(500, 330);
    await tester.tapAt(leftMiddle);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsNothing);

    await preferences.update((value) => value.copyWith(tapToTurn: false));
    await tester.pump();
    await tester.tapAt(const Offset(1120, 330));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsNothing);
    expect(loaded().currentPageIndex, 0);

    await preferences.update((value) => value.copyWith(tapToTurn: true));
    await tester.pump();
    await tester.tapAt(const Offset(1120, 330));
    await tester.pumpAndSettle();
    expect(loaded().currentPageIndex, 2);
    await tester.tapAt(leftMiddle);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsOneWidget);
  });

  testWidgets('scroll reader allows menu taps once the image scrolls away', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final old = api.bookSources[SourceId.lnovel]!;
    api.bookSources[SourceId.lnovel] = _ReaderTapSource(
      [image, ...List.filled(50, '向下滚动后的正文。')].join('\n'),
    );
    addTearDown(() => api.bookSources[SourceId.lnovel] = old);
    const aid = 'lnv:image-scroll-taps';
    const cid = 'a';
    await tester.pumpWidget(
      providers(
        BlocProvider(
          create: (_) => FontSettingsCubit(),
          child: MaterialApp(
            home: HtmlReaderPage(
              initialAid: aid,
              initialCid: cid,
              novelInfo: info,
              volumes: const [
                Volume(
                  id: 'v',
                  title: '卷',
                  chapters: [Chapter(aid: aid, cid: cid, title: '正文', url: '')],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsOneWidget);
    const textPoint = Offset(200, 420);
    await tester.tapAt(textPoint);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsNothing);

    await tester.tapAt(textPoint);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsNothing);

    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(440);
    await tester.pumpAndSettle();
    await tester.tapAt(textPoint);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderToolbar), findsOneWidget);
  });

  testWidgets(
    'scroll reader opens a saved chapter at the visible text anchor',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = api.bookSources[SourceId.lnovel]!;
      final lines = List.generate(110, (index) => '第 $index 段，滚动阅读测试。');
      api.bookSources[SourceId.lnovel] = _ReaderTapSource(lines.join('\n'));
      addTearDown(() => api.bookSources[SourceId.lnovel] = old);
      const aid = 'lnv:scroll-resume-fixture', cid = 'a';
      final offset = lines
          .take(60)
          .fold(0, (count, line) => count + line.length + 1);
      await tester.pumpWidget(
        providers(
          BlocProvider(
            create: (_) => FontSettingsCubit(),
            child: MaterialApp(
              home: HtmlReaderPage(
                initialAid: aid,
                initialCid: cid,
                initialTextOffset: offset,
                novelInfo: info,
                volumes: const [
                  Volume(
                    id: 'v',
                    title: '卷',
                    chapters: [
                      Chapter(aid: aid, cid: cid, title: '正文', url: ''),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(lines[0]), findsNothing);
      expect(find.text(lines[60]).hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(find.text(lines[60])).dy, lessThan(180));
    },
  );
}
