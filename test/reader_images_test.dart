import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/pages/novel/reader_image_viewer.dart';
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
    'image preview zooms without changing the reader route underneath',
    (tester) async {
      const ref = ReaderImageRef(source: SourceId.localEpub, url: 'fixture');
      final repo = ReaderImageRepository(
        client: MockClient((_) async => http.Response('', 500)),
      );
      final local = ReaderImageRef(
        source: ref.source,
        url: ref.url,
        readLocal: () async => epubFixturePng(),
      );
      await tester.pumpWidget(
        MaterialApp(home: ReaderImageViewer(image: local, repository: repo)),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(find.text('图片预览'), findsOneWidget);
      expect(find.byTooltip('保存到相册'), findsOneWidget);
      expect(find.text('图片加载失败'), findsNothing);
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
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
}
