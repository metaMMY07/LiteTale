import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/pages/novel/reader_image_viewer.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_illustration.dart';
import 'support/epub_fixture.dart';

void main() {
  test(
    'explicit retry replaces a cached original without keeping failed pixels',
    () async {
      var requests = 0;
      final repo = ReaderImageRepository(
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes(epubFixturePng(), 200);
        }),
      );
      const ref = ReaderImageRef(
        source: SourceId.bili,
        url: 'https://example.org/retry.png',
      );
      final first = await repo.read(ref);
      repo.invalidate(ref);
      expect(await repo.read(ref), isNot(same(first)));
      expect(requests, 2);
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  test('body, preview and saving coalesce to the same original data', () async {
    var calls = 0;
    final ready = Completer<http.Response>();
    final repository = ReaderImageRepository(
      client: MockClient((_) {
        calls++;
        return ready.future;
      }),
    );
    const ref = ReaderImageRef(
      source: SourceId.bili,
      url: 'https://example.org/figure.jpg',
    );
    final a = repository.read(ref), b = repository.read(ref);
    await Future<void>.delayed(Duration.zero);
    ready.complete(http.Response.bytes(epubFixturePng(), 200));
    expect(await a, same(await b));
    expect(calls, 1);
    expect((await a).extension, 'png');
  });
  test('all non-Wenku built-in policies remain tied to the book', () async {
    final seen = <String, String>{};
    final repository = ReaderImageRepository(
      client: MockClient((request) async {
        seen[request.url.path] =
            request.headers['Referer'] ?? request.headers['referer'] ?? '';
        return http.Response.bytes(epubFixturePng(), 200);
      }),
    );
    final sources = [
      SourceId.lightNovelShelf,
      SourceId.lnovel,
      SourceId.bili,
      SourceId.huanmeng,
      SourceId.rule('sfacg_public'),
    ];
    for (final source in sources) {
      await repository.read(
        ReaderImageRef(
          source: source,
          url: 'https://example.org/${source.name}',
        ),
      );
    }
    expect(seen['/bili'], contains('bilinovel.net'));
    expect(seen['/lightNovelShelf'], contains('lightnovel.app'));
    expect(seen['/huanmeng'], contains('huanmengacg.com'));
    expect(seen.length, 5);
  });
  test(
    'HTML rejection and HTTP errors are never cached as illustrations',
    () async {
      var requests = 0;
      final repo = ReaderImageRepository(
        client: MockClient(
          (_) async =>
              ++requests < 3
                  ? http.Response('<html>blocked</html>', 200)
                  : http.Response.bytes(epubFixturePng(), 200),
        ),
      );
      const ref = ReaderImageRef(
        source: SourceId.bili,
        url: 'https://example.org/x',
      );
      await expectLater(repo.read(ref), throwsFormatException);
      await expectLater(repo.read(ref), throwsFormatException);
      expect((await repo.read(ref)).extension, 'png');
      expect(requests, 3);
    },
  );
  test('oversized bodies and invalid schemes are rejected', () async {
    final repo = ReaderImageRepository(
      client: MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: {'content-length': '${ReaderImageRepository.maxBytes + 1}'},
        ),
      ),
    );
    await expectLater(
      repo.read(
        const ReaderImageRef(
          source: SourceId.bili,
          url: 'https://example.org/large',
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      repo.read(
        const ReaderImageRef(source: SourceId.bili, url: 'file:///etc/a'),
      ),
      throwsFormatException,
    );
  });
  test(
    'gallery cancellation is distinct and export preserves original bytes',
    () async {
      MethodCall? observed;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReaderImageExporter.channel, (
        call,
      ) async {
        observed = call;
        return call.method == 'save' ? 'cancelled' : 'exported';
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          ReaderImageExporter.channel,
          null,
        ),
      );
      final data = ReaderImageData(epubFixturePng());
      expect(
        await ReaderImageExporter.save(data, export: false),
        ReaderImageSaveResult.cancelled,
      );
      expect(
        await ReaderImageExporter.save(data, export: true, name: 'a/b'),
        ReaderImageSaveResult.exported,
      );
      expect(observed!.arguments['bytes'], data.bytes);
      expect(observed!.arguments['mime'], 'image/png');
      expect(observed!.arguments['name'], isNot(contains('/')));
    },
  );
  testWidgets(
    'preview taps use the visible image and close only the preview route',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final local = ReaderImageRef(
        source: SourceId.localEpub,
        url: 'preview-tap-fixture',
        readLocal: () async => epubFixturePng(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => Center(
                    child: TextButton(
                      onPressed: () => openReaderImage(context, local),
                      child: const Text('阅读界面'),
                    ),
                  ),
            ),
          ),
        ),
      );
      final viewer = find.byType(ReaderImageViewer);
      final picture = find.descendant(of: viewer, matching: find.byType(Image));
      final reader = find.text('阅读界面');
      Future<void> openPreview() async {
        await tester.tap(reader);
        for (var i = 0; i < 10 && picture.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(picture, findsOneWidget);
      }

      await openPreview();
      final center = tester.getCenter(picture);
      const bottomMargin = Offset(200, 720);
      expect(tester.getRect(picture).contains(bottomMargin), isFalse);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 350));
      expect(viewer, findsOneWidget);

      // This point starts outside the image and becomes part of it after zoom.
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(tester.getRect(picture).contains(bottomMargin), isTrue);
      await tester.tapAt(bottomMargin);
      await tester.pump(const Duration(milliseconds: 350));
      expect(viewer, findsOneWidget);

      final zoomed = tester.getRect(picture);
      await tester.dragFrom(center, const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(tester.getRect(picture).left, greaterThan(zoomed.left));
      final ios = defaultTargetPlatform == TargetPlatform.iOS;
      final actions = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReaderImageExporter.channel, (
        call,
      ) async {
        actions.add(call.method);
        expect(call.arguments['bytes'], epubFixturePng());
        return call.method == 'save' ? 'saved' : 'exported';
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          ReaderImageExporter.channel,
          null,
        ),
      );
      await tester.tap(
        find.byIcon(
          ios ? CupertinoIcons.arrow_down_to_line : Icons.download_rounded,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byIcon(ios ? CupertinoIcons.share : Icons.ios_share_rounded),
      );
      await tester.pumpAndSettle();
      expect(actions, ['save', 'export']);
      expect(find.text('已导出图片'), findsOneWidget);
      await tester.tap(find.byIcon(ios ? CupertinoIcons.xmark : Icons.close));
      await tester.pumpAndSettle();
      expect(reader, findsOneWidget);

      await openPreview();
      await tester.tapAt(bottomMargin);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(reader, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
  testWidgets('contain-fit whitespace does not intercept a reading tap', (
    tester,
  ) async {
    var background = 0;
    final ref = ReaderImageRef(
      source: SourceId.localEpub,
      url: 'x',
      readLocal: () async => epubFixturePng(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 200,
            child: GestureDetector(
              onTap: () => background++,
              child: ReaderIllustration(
                image: ref,
                provider: MemoryImage(epubFixturePng()),
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getTopLeft(find.byType(ReaderIllustration)) +
          const Offset(10, 100),
    );
    await tester.pump();
    expect(background, 1);
  });

  testWidgets(
    'preview grows from the illustration and follows a dismiss drag',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bytes = epubFixturePng();
      final provider = MemoryImage(bytes);
      var originalReads = 0;
      final ref = ReaderImageRef(
        source: SourceId.localEpub,
        url: 'preview-motion-fixture',
        readLocal: () async {
          originalReads++;
          return bytes;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: const Alignment(.7, .55),
              child: SizedBox.square(
                dimension: 128,
                child: ReaderIllustration(
                  image: ref,
                  provider: provider,
                  child: Image(image: provider, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      );
      final origin = tester.getRect(find.byType(ReaderIllustration));
      final region = find.byType(ReaderImageRegion);
      for (var i = 0; i < 10 && region.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(region, findsOneWidget);
      final viewer = find.byType(ReaderImageViewer);
      final picture = find.descendant(of: viewer, matching: find.byType(Image));
      await tester.tap(region);
      await tester.pump();
      expect(
        (tester.getRect(picture).center - origin.center).distance,
        lessThan(.01),
      );
      expect(tester.getRect(picture).width, closeTo(origin.width, .01));
      await tester.pumpAndSettle();
      final fitted = tester.getRect(picture);
      expect(fitted.width, greaterThan(origin.width));
      expect(originalReads, 0);

      // The preview stays dark even though MaterialApp uses its light theme.
      final close = find.ancestor(
        of: find.byIcon(CupertinoIcons.xmark),
        matching: find.byType(AppIconButton),
      );
      expect(tester.widget<AppIconButton>(close).color, Colors.white);
      expect(Theme.of(tester.element(close)).brightness, Brightness.dark);

      final shortDrag = await tester.startGesture(fitted.center);
      await shortDrag.moveBy(const Offset(45, 56));
      await tester.pump();
      final dragged = tester.getRect(picture);
      expect(dragged.center.dx, greaterThan(fitted.center.dx));
      expect(dragged.center.dy, greaterThan(fitted.center.dy));
      expect(dragged.width, lessThan(fitted.width));
      await shortDrag.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(picture), fitted);

      final longDrag = await tester.startGesture(fitted.center);
      await longDrag.moveBy(const Offset(-105, 135));
      await tester.pump();
      final released = tester.getRect(picture);
      await longDrag.up();
      await tester.pump();
      expect(tester.getRect(picture), released);
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(tester.getRect(find.byType(ReaderIllustration)), origin);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
