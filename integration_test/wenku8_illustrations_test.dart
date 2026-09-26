import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:wild/main.dart' as app;
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/pages/novel/reader_page.dart';
import 'package:wild/pages/novel/html_reader_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/src/rust/api/database.dart' as db;
import 'package:wild/widgets/cached_image.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Wenku8 illustration chapter in both native readers',
    (tester) async {
      Future<void> waitFor(bool Function() ready, String label) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed.inSeconds < 55) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: label);
      }

      await app.main();
      await waitFor(
        () => find.byType(NavigationBar).evaluate().isNotEmpty,
        'app initialized',
      );
      // Real chapter, production network/parser/cache path. No mocked chapter.
      final chapter = await api.chapterContent(aid: '3492', cid: '144956');
      final urls =
          RegExp(
            r'<!--image-->(.*?)<!--image-->',
          ).allMatches(chapter).map((m) => m.group(1)!.trim()).toList();
      expect(urls.length, greaterThanOrEqualTo(2));
      expect(urls.first, 'https://pic.777743.xyz/3/3492/144956/178126.jpg');
      final wrong = await http
          .get(
            Uri.parse(urls.first),
            headers: {'Referer': 'https://www.lightnovel.app/'},
          )
          .timeout(const Duration(seconds: 25));
      expect(
        wrong.statusCode,
        403,
        reason: 'reproduce dev.3 wrong source header',
      );
      debugPrint('ILLUSTRATION_OLD_ROUTE_403 confirmed on Android');

      // Also prove LightNovelShelf keeps its own headers when the active source
      // differs. Both policies must render through the real provider.
      final sample = await rootBundle.load('lib/assets/startup.png');
      final refs = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        refs.add(request.headers.value('referer') ?? '');
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(sample.buffer.asUint8List());
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      final original = activeSource.value;
      final type = nav.context.read<ReaderTypeCubit>();
      final originalType = type.state;
      addTearDown(() async {
        activeSource.value = original;
        // Flutter may dispose app Cubits before package:test tearDown runs.
        // Restore the persisted option without emitting into a closed Cubit.
        await db.saveProperty(key: 'reader_type', value: originalType.toString());
      });
      activeSource.value = SourceId.wenku8;
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder:
                (_) => Scaffold(
                  body: CachedImage(
                    url: 'http://127.0.0.1:${server.port}/shelf.png',
                    source: SourceId.lightNovelShelf,
                    width: 100,
                    height: 100,
                  ),
                ),
          ),
        ),
      );
      await waitFor(
        () => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        'shelf image decoded',
      );
      expect(refs, ['https://www.lightnovel.app/']);
      nav.pop();
      await tester.pumpAndSettle();
      debugPrint('ILLUSTRATION_SOURCE_ISOLATION_OK shelf Referer preserved');

      // Metadata identifies the public book/chapter; the reader loads the real
      // chapter above through its normal Cubit and persistent content cache.
      const info = NovelInfo(
        title: '奇招百出的维多利亚',
        author: '',
        status: '',
        finUpdate: '',
        imgUrl: 'http://img.wenku8.com/image/3/3492/3492s.jpg',
        introduce: '',
        tags: [],
        heat: '',
        trending: '',
        isAnimated: false,
      );
      const volumes = [
        Volume(
          id: '3492',
          title: '第一卷',
          chapters: [Chapter(aid: '3492', cid: '144956', title: '插图', url: '')],
        ),
      ];
      activeSource.value = SourceId.lightNovelShelf;
      await binding.convertFlutterSurfaceToImage();
      for (final mode in [ReaderType.html, ReaderType.normal]) {
        await type.updateType(mode);
        unawaited(
          nav.pushNamed(
            '/novel/reader',
            arguments: {
              'novelId': '3492',
              'chapterId': '144956',
              'title': '插图',
              'initialPage': 0,
              'novelInfo': info,
              'volumes': volumes,
            },
          ),
        );
        // During route transitions the preceding page may still be mounted.
        // Inspect only the reader, not that page's unrelated cover widgets.
        final reader = find.byType(
          mode == ReaderType.html ? HtmlReaderPage : ReaderPage,
        );
        final readerImages = find.descendant(
          of: reader,
          matching: find.byType(Image),
        );
        final readerFrames = find.descendant(
          of: reader,
          matching: find.byType(RawImage),
        );
        await waitFor(
          () => tester
              .widgetList<Image>(readerImages)
              .any(
                (image) =>
                    image.image is CachedImageProvider &&
                    (image.image as CachedImageProvider).url == urls.first,
              ),
          '$mode real illustration provider',
        );
        final images = tester
            .widgetList<Image>(readerImages)
            .where((image) => image.image is CachedImageProvider);
        expect(
          images.every(
            (image) =>
                (image.image as CachedImageProvider).source == SourceId.wenku8,
          ),
          isTrue,
        );
        await waitFor(
          () =>
              tester
                  .widgetList<RawImage>(readerFrames)
                  .where(
                    (image) => image.image != null && image.image!.width > 300,
                  )
                  .length >=
              images.length,
          '$mode real image decoded',
        );
        expect(find.text('图片加载失败'), findsNothing);
        await tester.pump(const Duration(milliseconds: 400));
        await binding.takeScreenshot('wenku8-illustration-${mode.name}');
        debugPrint(
          'ILLUSTRATION_READER_OK ${mode.name} chapter 144956 decoded ${images.length} mounted images',
        );
        nav.pop();
        await tester.pumpAndSettle();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
