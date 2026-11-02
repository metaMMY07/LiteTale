import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/book_cover_preview.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/book_cover_image.dart';
import 'package:wild/widgets/book_details_view.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'support/epub_fixture.dart';

class _Image extends ImageProvider<_Image> {
  final ready = Completer<ImageInfo>();
  @override
  Future<_Image> obtainKey(ImageConfiguration c) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_Image key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(ready.future);
}

const info = NovelInfo(
  title: '通用小说',
  author: '',
  status: '',
  finUpdate: '',
  imgUrl: '',
  introduce: '',
  tags: [],
  heat: '',
  trending: '',
  isAnimated: false,
);
const chapters = [
  Chapter(title: '第一章', cid: 'one', aid: 'bili:1', url: ''),
  Chapter(title: '第二章', cid: 'two', aid: 'bili:1', url: ''),
];
const volumes = [
  Volume(id: 'empty', title: '空卷', chapters: []),
  Volume(id: 'main', title: '正文卷', chapters: chapters),
];

Future<ui.Image> _pixels(WidgetTester tester) async {
  late ui.Image result;
  await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(epubFixturePng());
    result = (await codec.getNextFrame()).image;
    codec.dispose();
  });
  return result;
}

Widget _cover(
  _Image provider,
  BookCoverPreviewCache cache, {
  String url = 'https://example.invalid/a.png',
  bool reduced = false,
}) => MaterialApp(
  theme: materialYouTheme(Brightness.light, seedColor: Colors.green),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(
      body: SizedBox(
        width: 120,
        height: 180,
        child: BookCoverImage(
          url: url,
          source: SourceId.bili,
          imageProvider: provider,
          previewCache: cache,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'new cover fades in place; a previously displayed cover is immediate',
    (tester) async {
      final cache = BookCoverPreviewCache(), provider = _Image();
      await tester.pumpWidget(_cover(provider, cache));
      final frame = tester.getRect(find.byType(BookCoverImage));
      final pixels = await _pixels(tester);
      provider.ready.complete(ImageInfo(image: pixels));
      await tester.pump();
      expect(
        tester
            .widget<FadeTransition>(find.byKey(const ValueKey('cover-reveal')))
            .opacity
            .value,
        lessThan(1),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final opacity =
          tester
              .widget<FadeTransition>(
                find.byKey(const ValueKey('cover-reveal')),
              )
              .opacity
              .value;
      expect(opacity, greaterThan(0));
      expect(opacity, lessThan(1));
      expect(tester.getRect(find.byType(BookCoverImage)), frame);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.byKey(const ValueKey('cover-android-placeholder')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      final second = _Image();
      await tester.pumpWidget(_cover(second, cache));
      second.ready.complete(ImageInfo(image: pixels.clone()));
      await tester.pump();
      expect(
        tester
            .widget<FadeTransition>(find.byKey(const ValueKey('cover-reveal')))
            .opacity
            .value,
        1,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('recycled cover ignores a late frame from the previous book', (
    tester,
  ) async {
    final cache = BookCoverPreviewCache(), previous = _Image(), next = _Image();
    await tester.pumpWidget(_cover(previous, cache));
    await tester.pumpWidget(
      _cover(next, cache, url: 'https://example.invalid/b.png'),
    );
    final pixels = await _pixels(tester);
    final nextPixels = pixels.clone();
    previous.ready.complete(ImageInfo(image: pixels));
    await tester.pump();
    expect(find.byKey(const ValueKey('cover-reveal')), findsNothing);
    next.ready.complete(ImageInfo(image: nextPixels));
    // A replaced provider delivers on a microtask after the current frame;
    // build the frame scheduled by its listener before inspecting the tree.
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('cover-reveal')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reduced motion displays the first frame without a delayed reveal',
    (tester) async {
      final provider = _Image();
      await tester.pumpWidget(
        _cover(provider, BookCoverPreviewCache(), reduced: true),
      );
      provider.ready.complete(ImageInfo(image: await _pixels(tester)));
      await tester.pump();
      expect(
        tester
            .widget<FadeTransition>(find.byKey(const ValueKey('cover-reveal')))
            .opacity
            .value,
        1,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'missing metadata, resume and volume controls work across sources on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final source in [
          SourceId.wenku8,
          SourceId.lightNovelShelf,
          SourceId.lnovel,
          SourceId.bili,
          SourceId.huanmeng,
          SourceId.rule('sfacg_public'),
        ]) {
          String? selected;
          await tester.pumpWidget(
            MaterialApp(
              theme:
                  platform == TargetPlatform.iOS
                      ? iosGlassTheme(Brightness.light)
                      : materialYouTheme(Brightness.light),
              home: Scaffold(
                body: BookDetailsView(
                  key: ValueKey(source),
                  info: info,
                  volumes: volumes,
                  source: source,
                  resumeChapterId: 'two',
                  onRead: (c) => selected = c.cid,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('简介'), findsNothing);
          expect(find.textContaining('作者：'), findsNothing);
          expect(find.text('书评'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('detail-read')));
          await tester.pump();
          expect(selected, 'two');
          await tester.ensureVisible(find.byKey(const ValueKey('volume-1')));
          await tester.tap(find.byKey(const ValueKey('volume-1')));
          await tester.pump();
          expect(find.byKey(const ValueKey('chapter-1-two')), findsNothing);
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'empty directory cannot start reading and large text stays within a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
              body: BookDetailsView(
                info: info,
                volumes: const [],
                source: SourceId.bili,
                onRead: (_) => fail('No chapter exists'),
              ),
            ),
          ),
        ),
      );
      final button = tester.widget<AppButton>(
        find.byKey(const ValueKey('detail-read')),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'Android 1.0.0 color roles are restored without replacing selected seed',
    () {
      final theme = materialYouTheme(Brightness.dark, seedColor: Colors.teal);
      expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      expect(theme.cardTheme.color, theme.colorScheme.surfaceContainerLow);
      expect(
        theme.searchBarTheme.backgroundColor?.resolve({}),
        theme.colorScheme.surfaceContainerHighest,
      );
      expect(
        theme.colorScheme,
        ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      );
    },
  );
}
