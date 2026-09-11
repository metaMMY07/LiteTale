import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/pages/home/settings_page.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/api/database.dart' as db;
import 'package:wild/src/rust/api/font.dart';
import 'chapter_font_fixture.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/novel_cover_card.dart';

class FixtureSource implements BookSource {
  FixtureSource(this.cover);
  final String cover;
  @override
  SourceId get id => SourceId.lightNovelShelf;
  NovelCover get book =>
      NovelCover(aid: 'lns:424242', title: '图文阅读测试', img: cover, detailUrl: '');
  @override
  Future<List<HomeBlock>> discover() async => [
    HomeBlock(title: '近期录入', list: [book]),
  ];
  @override
  Future<api.PageStatsNovelCover> search(
    String key,
    String type,
    int page,
  ) async =>
      api.PageStatsNovelCover(currentPage: page, maxPage: 1, records: [book]);
  @override
  Future<SourceBookDetail> detail(String id) async => SourceBookDetail(
    NovelInfo(
      title: book.title,
      author: '测试作者',
      status: '轻书架',
      finUpdate: '',
      imgUrl: cover,
      introduce: '本地集成测试数据',
      tags: [],
      heat: '',
      trending: '',
      isAnimated: false,
    ),
    [
      Volume(
        id: id,
        title: '第一卷',
        chapters: [Chapter(aid: id, cid: '$id:1', title: '图文正文', url: '')],
      ),
    ],
  );
  @override
  Future<SourceChapter> chapter(String aid, String cid) async => SourceChapter(
    '前段文字\n<!--image-->$cover<!--image-->\n后段文字',
    fontFamily: 'ShelfFixture',
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'guest setup, isolated sources, native illustrated reader and saved selection',
    (tester) async {
      Future<void> waitFor(bool Function() ready, String label) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed.inSeconds < 30) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(ready(), isTrue, reason: label);
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final image = await rootBundle.load('lib/assets/startup.png');
      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(image.buffer.asUint8List());
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final original = api.bookSources[SourceId.lightNovelShelf]!;
      api.bookSources[SourceId.lightNovelShelf] = FixtureSource(
        'http://127.0.0.1:${server.port}/image.png',
      );
      addTearDown(() => api.bookSources[SourceId.lightNovelShelf] = original);
      await app.main();
      await waitFor(
        () => find.byType(NavigationBar).evaluate().isNotEmpty,
        'home opens without login',
      );
      final decodedFont = await decodeChapterFont(
        data: base64Decode(chapterFontFixture),
      );
      expect(decodedFont.take(4), [0, 1, 0, 0]);
      await (FontLoader('ShelfFixture')
        ..addFont(Future.value(ByteData.sublistView(decodedFont)))).load();
      await expectLater(
        decodeChapterFont(data: base64Decode('d09GMg==')),
        throwsA(anything),
      );
      await api.selectSource(SourceId.wenku8);
      await tester.pumpAndSettle();
      expect(find.text('选择书源'), findsOneWidget);
      await tester.tap(find.text('选择书源'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<SourceId>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('轻书架').last);
      await tester.pumpAndSettle();
      expect(activeSource.value, SourceId.lightNovelShelf);
      expect(find.text('登录轻书架'), findsOneWidget);
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('litetale-source-settings');
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pop();
      await tester.pumpAndSettle();
      await waitFor(
        () => find.byType(NovelCoverCard).evaluate().isNotEmpty,
        'selected provider cards',
      );
      expect(find.text('选择书源'), findsNothing);
      unawaited(nav.pushNamed('/search'));
      await tester.pumpAndSettle();
      tester.testTextInput.register();
      await tester.enterText(find.byType(TextField), '图文');
      await tester.pump();
      await tester.tap(find.byTooltip('执行搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(NovelCoverCard), findsOneWidget);
      await tester.tap(find.byType(NovelCoverCard));
      await tester.pumpAndSettle();
      await waitFor(
        () => find.text('图文正文').evaluate().isNotEmpty,
        'shared book detail loaded',
      );
      final info = await api.novelInfo(aid: 'lns:424242');
      final volumes = await api.novelReader(aid: 'lns:424242');
      await tester
          .element(find.text('小说详情'))
          .read<ReaderTypeCubit>()
          .updateType(ReaderType.normal);
      unawaited(
        nav.pushNamed(
          '/novel/reader',
          arguments: {
            'novelId': 'lns:424242',
            'chapterId': 'lns:424242:1',
            'title': '图文正文',
            'novelInfo': info,
            'volumes': volumes,
          },
        ),
      );
      await waitFor(
        () => find.byType(PageView).evaluate().isNotEmpty,
        'native reader loaded',
      );
      final cubit = tester.element(find.byType(PageView)).read<ReaderCubit>();
      expect((cubit.state as ReaderLoaded).pages.map((p) => p.isImage), [
        false,
        true,
        false,
      ]);
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect((cubit.state as ReaderLoaded).currentPageIndex, 1);
      await binding.takeScreenshot('litetale-native-illustration');
      final visible = cubit.state.showControls;
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pumpAndSettle();
      expect(cubit.state.showControls, !visible);
      nav.pop();
      await tester.pumpAndSettle();
      final shelfHistory = await api.listReadingHistory(offset: 0, limit: 100);
      expect(shelfHistory.any((h) => h.novelId == 'lns:424242'), isTrue);
      await api.selectSource(SourceId.wenku8);
      expect(
        (await api.listReadingHistory(
          offset: 0,
          limit: 100,
        )).every((h) => !h.novelId.startsWith('lns:')),
        isTrue,
      );
      await api.selectSource(SourceId.lightNovelShelf);
      expect(
        await db.loadProperty(key: 'litetale.active_source'),
        'lightNovelShelf',
      );
      activeSource.value = SourceId.wenku8;
      await api.loadSourceSelection();
      expect(activeSource.value, SourceId.lightNovelShelf);
      await api.deleteHistoryByNovelId(novelId: 'lns:424242');
      await db.saveProperty(key: 'litetale.lns.search_history', value: '[]');
      // Leave the emulator on a real source; fixture data is never in the release.
      await api.selectSource(SourceId.wenku8);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
