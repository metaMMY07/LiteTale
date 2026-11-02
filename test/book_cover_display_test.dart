import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/book_cover_preview.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/book_cover_image.dart';

class _DecodedImage extends ImageProvider<_DecodedImage> {
  _DecodedImage(this.pixels);
  final ui.Image pixels;
  @override
  Future<_DecodedImage> obtainKey(ImageConfiguration _) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_DecodedImage key, ImageDecoderCallback _) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: pixels.clone())),
      );
}

final _sources = [
  SourceId.wenku8,
  SourceId.lightNovelShelf,
  SourceId.lnovel,
  SourceId.bili,
  SourceId.huanmeng,
  SourceId.rule('sfacg_public'),
];

Future<ui.Image> _bookPixels(WidgetTester tester) async {
  late ui.Image image;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawPaint(Paint()..color = const Color(0xFF236790));
    canvas.drawRect(
      const Rect.fromLTWH(30, 35, 180, 55),
      Paint()..color = Colors.amber,
    );
    canvas.drawCircle(const Offset(120, 185), 58, Paint()..color = Colors.pink);
    canvas.drawRect(
      const Rect.fromLTWH(40, 275, 160, 18),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    image = await picture.toImage(240, 360);
    picture.dispose();
  });
  return image;
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('COVER_QA_OUTPUT');
  if (output.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('covers-sheet')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('$output/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
  });
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'decoded first displays dissolve on every source on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(420, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pixels = await _bookPixels(tester);
        final cache = BookCoverPreviewCache();
        final theme =
            platform == TargetPlatform.iOS
                ? iosGlassTheme(Brightness.light)
                : materialYouTheme(Brightness.light, seedColor: Colors.green);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('covers-sheet'),
                child: GridView.count(
                  crossAxisCount: 3,
                  childAspectRatio: .62,
                  padding: const EdgeInsets.all(12),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  children: [
                    for (final source in _sources)
                      Column(
                        children: [
                          Expanded(
                            child: BookCoverImage(
                              url: 'https://example.invalid/${source.name}.png',
                              source: source,
                              imageProvider: _DecodedImage(pixels),
                              previewCache: cache,
                            ),
                          ),
                          Text(
                            source.label,
                            maxLines: 1,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final frames = tester.getRect(find.byType(BookCoverImage).first);
        final reveals = find.byKey(const ValueKey('cover-reveal'));
        expect(reveals, findsNWidgets(6));
        expect(
          tester
              .widgetList<FadeTransition>(reveals)
              .every((f) => f.opacity.value == 0),
          isTrue,
        );
        if (platform == TargetPlatform.iOS) {
          expect(
            find.byKey(const ValueKey('cover-local-blur')),
            findsNWidgets(6),
          );
        } else {
          expect(
            find.byKey(const ValueKey('cover-android-placeholder')),
            findsNWidgets(6),
          );
          final gradient =
              tester
                      .widget<DecoratedBox>(
                        find
                            .byKey(const ValueKey('cover-android-placeholder'))
                            .first,
                      )
                      .decoration
                  as BoxDecoration;
          expect(
            gradient.gradient!.colors.first,
            Color.alphaBlend(
              theme.colorScheme.primary.withValues(alpha: .08),
              theme.colorScheme.primaryContainer,
            ),
          );
        }
        final label = platform == TargetPlatform.iOS ? 'ios' : 'android';
        await _snapshot(tester, '$label-000');
        final duration = platform == TargetPlatform.iOS ? 200 : 500;
        for (var i = 1; i <= 4; i++) {
          await tester.pump(Duration(milliseconds: duration ~/ 4));
          if (i == 2) {
            for (final fade in tester.widgetList<FadeTransition>(reveals)) {
              expect(fade.opacity.value, inExclusiveRange(.15, .75));
            }
          }
          await _snapshot(tester, '$label-00$i');
        }
        await tester.pump(const Duration(milliseconds: 1));
        expect(
          tester
              .widgetList<FadeTransition>(reveals)
              .every((f) => f.opacity.value == 1),
          isTrue,
        );
        expect(find.byKey(const ValueKey('cover-local-blur')), findsNothing);
        expect(
          find.byKey(const ValueKey('cover-android-placeholder')),
          findsNothing,
        );
        expect(tester.getRect(find.byType(BookCoverImage).first), frames);
        await tester.pumpWidget(const SizedBox());
        pixels.dispose();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'offstage prefetch does not consume the first on-screen transition',
    (tester) async {
      final cache = BookCoverPreviewCache(), pixels = await _bookPixels(tester);
      final provider = _DecodedImage(pixels);
      var offstage = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Offstage(
                  offstage: offstage,
                  child: SizedBox(
                    width: 120,
                    height: 180,
                    child: BookCoverImage(
                      url: 'https://example.invalid/offstage.png',
                      source: SourceId.wenku8,
                      imageProvider: provider,
                      previewCache: cache,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      final reveal = find.byKey(
        const ValueKey('cover-reveal'),
        skipOffstage: false,
      );
      expect(tester.widget<FadeTransition>(reveal).opacity.value, 0);
      update(() => offstage = false);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<FadeTransition>(reveal).opacity.value, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<FadeTransition>(reveal).opacity.value,
        closeTo(.5, .05),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<FadeTransition>(reveal).opacity.value, 1);
      await tester.pumpWidget(const SizedBox());
      pixels.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
