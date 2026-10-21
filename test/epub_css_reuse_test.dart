import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/epub/epub_css_reader.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';

import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('litetale/epub_pages');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late LocalEpubLibrary library;
  late LocalEpubBook book;
  final readers = <EpubCssReader>[];
  var prepares = 0, captures = 0, releases = 0;
  Completer<void>? started, gate;
  Completer<void>? captureStarted, captureGate;
  late Uint8List captureBytes;
  final response = {
    'count': 2,
    'textLength': 8,
    'text': 'abcdefgh',
    'ranges': [
      {'start': 0, 'end': 4},
      {'start': 4, 'end': 8},
    ],
  };
  EpubCssReader reader() {
    final result = EpubCssReader(library: library);
    readers.add(result);
    return result;
  }

  Future<List<ReaderPage>> paginate(
    EpubCssReader owner, {
    double width = 640,
    Uint8List? font,
  }) => owner.paginate(
    book: book.id,
    chapter: book.chapterId(0),
    content: 'abcdefgh',
    userFont: font,
    options: {'width': width},
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('epub_reuse_');
    library = LocalEpubLibrary(useIsolates: false);
    await library.initialize(root.path);
    book =
        (await library.importFile(
          XFile.fromData(buildEpubFixture(), path: 'sample.epub'),
        )).book;
    prepares = captures = releases = 0;
    started = gate = null;
    captureStarted = captureGate = null;
    captureBytes = epubFixturePng();
    readers.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'prepare') {
        prepares++;
        if (started != null && !started!.isCompleted) started!.complete();
        await gate?.future;
        return response;
      }
      if (call.method == 'capture') {
        captures++;
        captureStarted?.complete();
        await captureGate?.future;
        return captureBytes;
      }
      if (call.method == 'close' && call.arguments['all'] == true) releases++;
      return null;
    });
  });
  tearDown(() async {
    for (final item in readers) {
      item.close();
    }
    await EpubCssReader.clearUnusedCache();
    messenger.setMockMethodCallHandler(channel, null);
    if (library.contains(book.id)) await library.remove(book.id);
    await Directory('${root.path}/local_epub').delete();
    await root.delete();
    PaintingBinding.instance.imageCache.clear();
  });

  test('small layout maps outlive the three native view slots', () async {
    final a = reader();
    final first = await paginate(a);
    for (var i = 1; i < 5; i++) {
      await paginate(a, width: 640 + i.toDouble());
    }
    expect((await paginate(a))[0].cssPage!.key, first[0].cssPage!.key);
    expect(prepares, 5);
  });

  test('native lossless WebP captures decode and remain reusable', () async {
    captureBytes = base64Decode(
      'UklGRh4AAABXRUJQVlA4TBEAAAAvAUAAAAdQoP71v/+BiOh/AAA=',
    );
    final first = await paginate(reader());
    final bytes = await first[0].cssPage!.read();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 2);
    expect(frame.image.height, 2);
    final pixels = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(pixels!.buffer.asUint8List(), [
      for (var i = 0; i < 4; i++) ...[127, 64, 255, 255],
    ]);
    frame.image.dispose();
    codec.dispose();
    final second = await paginate(reader());
    expect(await second[0].cssPage!.read(), same(bytes));
    expect(captures, 1);
  });

  test(
    'invalid and truncated capture containers fail before caching',
    () async {
      for (final invalid in [
        Uint8List(0),
        Uint8List(40),
        base64Decode('UklGRh4AAABXRUJQVlA4TBEAAAAvAUAAAAdQoP71v/+BiOh/AA=='),
      ]) {
        captureBytes = invalid;
        final pages = await paginate(reader());
        await expectLater(pages[0].cssPage!.read(), throwsStateError);
      }
      captureBytes = epubFixturePng();
      final pages = await paginate(reader());
      expect(await pages[0].cssPage!.read(), captureBytes);
      expect(captures, 4);
    },
  );

  test('decoded Flutter paper does not rebuild a PNG during warming', () async {
    final a = reader(), first = await paginate(a);
    final codec = await ui.instantiateImageCodec(epubFixturePng());
    final frame = await codec.getNextFrame();
    PaintingBinding.instance.imageCache.putIfAbsent(
      EpubCssImageProvider(first[0].cssPage!),
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: frame.image)),
      ),
    );
    await pumpEventQueue();
    codec.dispose();
    a.close();
    await EpubCssReader.clearUnusedCache();
    final b = reader(), next = await paginate(b);
    await EpubCssReader.warm(next, 0, count: 1, strict: true);
    expect(captures, 0);
    await EpubCssReader.warm(
      await paginate(b, width: 700),
      0,
      count: 1,
      strict: true,
    );
    expect(captures, 1);
  });

  test('reopen reuses layout and PNG while old owner stays closed', () async {
    final a = reader(), first = await paginate(a);
    await first[0].cssPage!.read();
    a.close();
    final b = reader(), second = await paginate(b);
    await second[0].cssPage!.read();
    expect(second.first.cssPage!.key, first.first.cssPage!.key);
    expect(prepares, 1);
    expect(captures, 1);
    await expectLater(first[0].cssPage!.read(), throwsStateError);
    await second[1].cssPage!.read();
    expect(captures, 2);
  });

  test('viewport and actual font bytes invalidate layout identity', () async {
    final a = reader();
    final first = await paginate(a);
    final resized = await paginate(a, width: 700);
    final fontA = await paginate(a, font: Uint8List.fromList([1, 2, 3]));
    final fontAAgain = await paginate(a, font: Uint8List.fromList([1, 2, 3]));
    final fontB = await paginate(a, font: Uint8List.fromList([1, 2, 4]));
    expect(first[0].cssPage!.key, isNot(resized[0].cssPage!.key));
    expect(fontA[0].cssPage!.key, fontAAgain[0].cssPage!.key);
    expect(fontA[0].cssPage!.key, isNot(fontB[0].cssPage!.key));
    expect(prepares, 4);
  });

  test(
    'closing during capture cannot poison PNG reuse in the next reader',
    () async {
      final a = reader(), first = await paginate(a);
      captureStarted = Completer();
      captureGate = Completer();
      final image = first[0].cssPage!.read();
      await captureStarted!.future;
      a.close();
      final b = reader(), next = paginate(b);
      final rejected = expectLater(image, throwsStateError);
      captureGate!.complete();
      await rejected;
      final pages = await next;
      await pages[0].cssPage!.read();
      expect(captures, 1);
      expect(prepares, 1);
    },
  );

  test(
    'closing the original owner does not poison a shared pending layout',
    () async {
      started = Completer();
      gate = Completer();
      final a = reader();
      final first = paginate(a);
      await started!.future;
      a.close();
      final b = reader(), second = paginate(b);
      final rejected = expectLater(first, throwsStateError);
      gate!.complete();
      await rejected;
      expect(await second, hasLength(2));
      expect(prepares, 1);
    },
  );

  test(
    'removed and reimported book cannot use old page bytes or document',
    () async {
      final oldDoc = await library.publication(book.id, book.chapterId(0));
      final a = reader(), first = await paginate(a);
      await first[0].cssPage!.read();
      await library.remove(book.id);
      book =
          (await library.importFile(
            XFile.fromData(buildEpubFixture(), path: 'sample.epub'),
          )).book;
      final newDoc = await library.publication(book.id, book.chapterId(0));
      expect(newDoc, isNot(same(oldDoc)));
      await expectLater(first[0].cssPage!.read(), throwsStateError);
      final next = await paginate(reader());
      expect(next[0].cssPage!.key, isNot(first[0].cssPage!.key));
      await next[0].cssPage!.read();
      expect(prepares, 2);
      expect(captures, 2);
    },
  );

  test(
    'chapter projections coalesce and idle release drops native and page caches',
    () async {
      final documents = await Future.wait([
        library.publication(book.id, book.chapterId(0)),
        library.publication(book.id, book.chapterId(0)),
      ]);
      expect(documents[0], same(documents[1]));
      expect(
        await library.publication(book.id, book.chapterId(0)),
        same(documents[0]),
      );
      final a = reader(), first = await paginate(a);
      await first[0].cssPage!.read();
      a.close();
      await EpubCssReader.clearUnusedCache();
      expect(releases, 1);
      final second = await paginate(reader());
      await second[0].cssPage!.read();
      expect(prepares, 2);
      expect(captures, 2);
    },
  );
}
