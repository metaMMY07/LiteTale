import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/reader_raster_readiness.dart';

class _ManualCompleter extends ImageStreamCompleter {
  void deliver(ui.Image image) => setImage(ImageInfo(image: image));

  void fail() => reportError(
    context: ErrorDescription('deliberate illustration failure'),
    exception: StateError('unreadable image'),
    silent: true,
  );
}

class _ManualImage extends ImageProvider<_ManualImage> {
  final completer = _ManualCompleter();

  @override
  Future<_ManualImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ManualImage key,
    ImageDecoderCallback decode,
  ) => completer;
}

Future<ui.Image> _pixels(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 8, 8),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(8, 8);
      } finally {
        picture.dispose();
      }
    }))!;

Widget _page(ReaderRasterReadiness readiness, List<ImageProvider> images) =>
    MaterialApp(
      home: ReaderRasterScope(
        readiness: readiness,
        child: Row(
          children: [
            for (var i = 0; i < images.length; i++)
              Expanded(
                child: ReaderRasterImage(
                  key: ValueKey(i),
                  image: images[i],
                  errorChild: const Text('图片加载失败'),
                ),
              ),
          ],
        ),
      ),
    );

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('delayed first frame keeps the spread pending until painted', (
    tester,
  ) async {
    var changes = 0;
    final readiness = ReaderRasterReadiness(onChanged: () => changes++);
    final image = _ManualImage();
    await tester.pumpWidget(_page(readiness, [image]));
    final revisionBeforeDecode = readiness.revision;
    expect(readiness.isReady, isFalse);
    image.completer.deliver(await _pixels(tester));
    // The stream delivers before Image has rebuilt and painted its first frame.
    expect(readiness.isReady, isFalse);
    await tester.pump();
    expect(readiness.isReady, isTrue);
    expect(readiness.revision, greaterThan(revisionBeforeDecode));
    expect(changes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a spread waits for both leaves and errors unblock capture', (
    tester,
  ) async {
    final readiness = ReaderRasterReadiness(onChanged: () {});
    final first = _ManualImage();
    final second = _ManualImage();
    await tester.pumpWidget(_page(readiness, [first, second]));
    first.completer.deliver(await _pixels(tester));
    await tester.pump();
    expect(readiness.isReady, isFalse);
    second.completer.fail();
    await tester.pump();
    expect(find.text('图片加载失败'), findsOneWidget);
    expect(readiness.isReady, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing an image invalidates capture until its own frame', (
    tester,
  ) async {
    final readiness = ReaderRasterReadiness(onChanged: () {});
    final first = _ManualImage();
    final second = _ManualImage();
    await tester.pumpWidget(_page(readiness, [first]));
    first.completer.deliver(await _pixels(tester));
    await tester.pump();
    final oldRevision = readiness.revision;
    await tester.pumpWidget(_page(readiness, [second]));
    expect(readiness.isReady, isFalse);
    expect(readiness.revision, greaterThan(oldRevision));
    second.completer.deliver(await _pixels(tester));
    await tester.pump();
    expect(readiness.isReady, isTrue);
  });

  testWidgets('rotated scope and disposed image release pending resources', (
    tester,
  ) async {
    final oldPage = ReaderRasterReadiness(onChanged: () {});
    final newPage = ReaderRasterReadiness(onChanged: () {});
    final image = _ManualImage();
    await tester.pumpWidget(_page(oldPage, [image]));
    expect(oldPage.isReady, isFalse);
    await tester.pumpWidget(_page(newPage, [image]));
    expect(oldPage.isReady, isTrue);
    expect(newPage.isReady, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(newPage.isReady, isTrue);
    image.completer.deliver(await _pixels(tester));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('already decoded illustration needs no artificial delay', (
    tester,
  ) async {
    final readiness = ReaderRasterReadiness(onChanged: () {});
    final image = _ManualImage();
    image.completer.deliver(await _pixels(tester));
    await tester.pumpWidget(_page(readiness, [image]));
    expect(readiness.isReady, isTrue);
    expect(tester.takeException(), isNull);
  });
}
