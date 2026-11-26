import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../models/reader_document.dart';
import 'epub_models.dart';

typedef EpubArtworkRasterizer =
    Future<Uint8List?> Function(EpubArtworkPage page);

const _channel = MethodChannel('litetale/epub_artwork');

Future<Uint8List?> rasterizeEpubArtwork(EpubArtworkPage page) async {
  if (!Platform.isAndroid) return null;
  return _channel
      .invokeMethod<Uint8List>('render', {'html': page.html})
      .timeout(const Duration(seconds: 14));
}

/// Rendering happens once at import, serially, within a book-wide budget. The
/// reader sees ordinary owned images; there is no browser work during a turn.
Future<ParsedEpubBook> renderEpubArtwork(
  ParsedEpubBook book,
  EpubArtworkRasterizer rasterize,
) async {
  if (!book.chapters.any((chapter) => chapter.artwork != null)) return book;
  final timer = Stopwatch()..start();
  final assets = Map<String, Uint8List>.of(book.assets);
  final chapters = <EpubChapterData>[];
  var total = assets.values.fold(0, (sum, bytes) => sum + bytes.length);
  var fallback = false;
  var unavailable = false;
  for (final chapter in book.chapters) {
    final design = chapter.artwork;
    Uint8List? image;
    if (design != null && !unavailable && timer.elapsed.inSeconds < 60) {
      try {
        image = await rasterize(design).timeout(const Duration(seconds: 14));
      } on MissingPluginException {
        unavailable = true;
      } on Object {
        // Failed/timed-out art never replaces a readable chapter.
      }
    }
    var document = chapter.document;
    if (design != null) {
      if (image != null &&
          _validPng(image) &&
          total + image.length <= 128 * 1024 * 1024) {
        final name = '${sha256.convert(image)}.png';
        if (!assets.containsKey(name)) {
          assets[name] = image;
          total += image.length;
        }
        document = ReaderDocument([
          ReaderBlock(
            runs: [ReaderRun(chapter.content)],
            artworkUrl: epubAssetUrl(book.digest, name),
          ),
        ]);
      } else {
        fallback = true;
      }
    }
    chapters.add(
      EpubChapterData(
        title: chapter.title,
        href: chapter.href,
        content: chapter.content,
        document: document,
        fixedLayout: chapter.fixedLayout,
      ),
    );
  }
  return ParsedEpubBook(
    digest: book.digest,
    title: book.title,
    author: book.author,
    description: book.description,
    language: book.language,
    subjects: book.subjects,
    chapters: chapters,
    assets: assets,
    coverAssetName: book.coverAssetName,
    warnings: [...book.warnings, if (fallback) '部分特殊页面未能保留完整设计，已使用可阅读的文字排版。'],
    artworkNeedsRetry: fallback,
  );
}

bool _validPng(Uint8List bytes) {
  if (bytes.length < 33 || bytes.length > 8 * 1024 * 1024) return false;
  const magic = [137, 80, 78, 71, 13, 10, 26, 10];
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  final header = ByteData.sublistView(bytes);
  final width = header.getUint32(16), height = header.getUint32(20);
  return width > 0 &&
      width <= 1440 &&
      height > 0 &&
      height <= 8192 &&
      width * height <= 6 * 1024 * 1024;
}
