import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/cached_image.dart';

void main() {
  final bytes = File('lib/assets/startup.png').readAsBytesSync();
  const url = 'https://example.test/cover-reveal.png';
  const source = SourceId.lightNovelShelf;

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('first decoded cover replaces placeholder without a fade', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    var taps = 0;
    Widget cover() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: GestureDetector(
            onTap: () => taps++,
            child: const SizedBox(
              width: 120,
              height: 180,
              child: CachedImage(url: url, source: source),
            ),
          ),
        ),
      ),
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(cover());
      final size = tester.getSize(find.byType(CachedImage));
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      await tester.tap(find.byType(CachedImage));
      expect(taps, 1);
      await tester.runAsync(() async {
        gate.complete(http.Response.bytes(bytes, 200));
        await precacheImage(
          CachedImageProvider(url, source: source),
          tester.element(find.byType(CachedImage)),
        );
      });
      await tester.pump();
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(tester.getSize(find.byType(CachedImage)), size);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(cover());
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    }, () => MockClient((_) => gate.future));
  });

  testWidgets('thumbnail decoding stays bounded without animating', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 180,
              child: CachedImage(url: url, source: source, cacheWidth: 120),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          ResizeImage(CachedImageProvider(url, source: source), width: 120),
          tester.element(find.byType(CachedImage)),
        );
      });
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 120);
      expect(find.byType(AnimatedOpacity), findsNothing);
    }, () => MockClient((_) async => http.Response.bytes(bytes, 200)));
  });
}
