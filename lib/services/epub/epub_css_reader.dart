import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../models/reader_page.dart';
import '../read_result_cache.dart';
import 'local_epub_library.dart';

/// Readers share a bounded, revision-keyed layout/bitmap cache. A short idle
/// grace period makes leaving and reopening a book reuse its prepared paper.
class EpubCssReader {
  EpubCssReader({LocalEpubLibrary? library})
    : library = library ?? LocalEpubLibrary.instance {
    _libraryId = _libraryIds[this.library] ??= _sequence++;
    _activeReaders++;
    _idleTimer?.cancel();
  }
  final LocalEpubLibrary library;
  static const _channel = MethodChannel('litetale/epub_pages');
  static Future<void> _tail = Future.value();
  static int _sequence = 0;
  static final _libraryIds = Expando<int>();
  static final _fontHashes = Expando<Future<String>>();
  late final int _libraryId;
  static int _activeReaders = 0;
  static Timer? _idleTimer;
  static final _layouts = ReadResultCache<String, Map>(
    // Metadata is much smaller than a live WebView. Retain it independently
    // so preloading a fourth section does not discard the visible cover's map.
    maxEntries: 8,
    maxWeight: 32 * 1024 * 1024,
    ttl: const Duration(minutes: 10),
    weightOf:
        (info) =>
            (info['text'] as String).length * 2 +
            (info['ranges'] as List).length * 32,
  );
  static final _images = ReadResultCache<String, Uint8List>(
    maxEntries: 10,
    maxWeight: 16 * 1024 * 1024,
    ttl: const Duration(minutes: 10),
    weightOf: (bytes) => bytes.length,
  );
  bool _closed = false;

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _check() {
    if (_closed) throw StateError('阅读器已更新');
  }

  void _checkSource(_Chapter recipe) {
    if (!library.contains(recipe.book) ||
        library.revisionFor(recipe.book) != recipe.revision) {
      throw StateError('本地书籍已更新');
    }
  }

  Future<Map> _ensure(_Chapter recipe, {bool sharedLoad = false}) async {
    if (!sharedLoad) _check();
    _checkSource(recipe);
    final info = await _layouts.getOrLoad(recipe.id, () async {
      // Work may outlive its original reader, but never the book revision. A
      // newly opened reader can use that completed work rather than start over.
      final doc = await library.publication(recipe.book, recipe.chapter);
      _checkSource(recipe);
      final response = await _channel
          .invokeMapMethod<String, dynamic>('prepare', {
            'id': recipe.id,
            'cacheScope': _libraryId,
            'revision': recipe.revision,
            'html': doc.html,
            'resources': doc.resources,
            'userFont': recipe.userFont,
            'options': {...recipe.options, 'fixed': doc.fixedLayout},
          })
          .timeout(const Duration(seconds: 20));
      _checkSource(recipe);
      if (response == null ||
          response['text'] is! String ||
          (response['text'] as String).length > 12 * 1024 * 1024 ||
          response['ranges'] is! List ||
          response['count'] is! int ||
          response['count'] < 1 ||
          response['count'] > 12000 ||
          (response['ranges'] as List).length != response['count']) {
        throw StateError('本地 CSS 分页结果无效');
      }
      for (final range in response['ranges'] as List) {
        if (range is! Map ||
            range['start'] is! int ||
            range['end'] is! int ||
            range['start'] < 0 ||
            range['end'] < range['start'] ||
            range['end'] > 32 * 1024 * 1024) {
          throw StateError('本地 CSS 阅读位置无效');
        }
      }
      response['fixedLayout'] = doc.fixedLayout;
      return response;
    });
    if (!sharedLoad) _check();
    _checkSource(recipe);
    return info;
  }

  Future<List<ReaderPage>> paginate({
    required String book,
    required String chapter,
    required String content,
    required Map<String, Object> options,
    Uint8List? userFont,
  }) async {
    final revision = library.revisionFor(book);
    final fontHash =
        userFont == null
            ? ''
            : await (_fontHashes[userFont] ??= compute(_fontHash, userFont));
    _check();
    final id =
        sha256
            .convert(
              utf8.encode(
                'css-v1:$_libraryId:$book:$chapter:$revision:$fontHash:${jsonEncode(options)}',
              ),
            )
            .toString();
    final recipe = _Chapter(
      id,
      book,
      chapter,
      revision,
      Map.unmodifiable(options),
      userFont,
    );
    final info = await _exclusive(() => _ensure(recipe));
    final ranges = info['ranges'] as List;
    final text = info['text'] as String;
    final total = (info['textLength'] as int? ?? 0).clamp(1, 32 * 1024 * 1024);
    return List.generate(ranges.length, (index) {
      final range = ranges[index] as Map;
      final domStart = range['start'] as int, domEnd = range['end'] as int;
      // Legacy history offsets remain usable by older readers. New positions
      // also carry a DOM offset, independent of viewport and page count.
      final start = (content.length * domStart / total).floor().clamp(
        0,
        content.length,
      );
      final end =
          index == ranges.length - 1
              ? content.length
              : (content.length * domEnd / total).ceil().clamp(
                start,
                content.length,
              );
      return ReaderPage(
        content: content.substring(start, end),
        isImage: false,
        textStart: start,
        textEnd: end,
        cssPage: ReaderCssPage(
          key: id,
          index: index,
          domStart: domStart,
          domEnd: domEnd,
          fixedLayout: info['fixedLayout'] == true,
          semanticText:
              text
                  .substring(
                    domStart.clamp(0, text.length),
                    domEnd.clamp(domStart.clamp(0, text.length), text.length),
                  )
                  .trim(),
          read: () => _image(recipe, index),
        ),
      );
    });
  }

  Future<Uint8List> _image(_Chapter recipe, int index) async {
    _check();
    _checkSource(recipe);
    final result = await _images.getOrLoad(
      '${recipe.id}:$index',
      () => _exclusive(() async {
        _checkSource(recipe);
        await _ensure(recipe, sharedLoad: true);
        Future<Uint8List?> capture() => _channel
            .invokeMethod<Uint8List>('capture', {
              'id': recipe.id,
              'page': index,
            })
            .timeout(const Duration(seconds: 20));
        Uint8List? bytes;
        try {
          bytes = await capture();
        } on PlatformException catch (error) {
          if (error.code != 'missing_session') rethrow;
          _layouts.clear();
          await _ensure(recipe, sharedLoad: true);
          bytes = await capture();
        }
        _checkSource(recipe);
        if (bytes == null || !_isPageImage(bytes)) {
          throw StateError('本地页面绘制失败');
        }
        return bytes;
      }),
    );
    _check();
    _checkSource(recipe);
    return result;
  }

  static Future<void> warm(
    List<ReaderPage> pages,
    int index, {
    int count = 4,
    bool strict = false,
  }) async {
    for (var i = index; i < pages.length && i < index + count; i++) {
      try {
        final page = pages[i].cssPage;
        if (page == null) continue;
        final status = PaintingBinding.instance.imageCache.statusForKey(
          EpubCssImageProvider(page),
        );
        // A decoded paper is already usable by the image provider. Recreating
        // its encoded image here can needlessly rebuild an evicted chapter.
        if (!status.pending && (status.keepAlive || status.live)) continue;
        await page.read();
      } on Object {
        if (strict) rethrow;
        return;
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _activeReaders--;
    if (_activeReaders == 0) {
      _idleTimer?.cancel();
      _idleTimer = Timer(const Duration(seconds: 45), () {
        unawaited(clearUnusedCache());
      });
    }
  }

  /// Also used by tests to release the bounded native pool deterministically.
  static Future<void> clearUnusedCache() async {
    if (_activeReaders != 0) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    _images.clear();
    _layouts.clear();
    await _exclusive(() async {
      if (_activeReaders != 0) return;
      try {
        await _channel
            .invokeMethod<void>('close', {'all': true})
            .timeout(const Duration(seconds: 3));
      } on Object {
        /* Activity disposal also owns cleanup. */
      }
    });
  }
}

class _Chapter {
  const _Chapter(
    this.id,
    this.book,
    this.chapter,
    this.revision,
    this.options,
    this.userFont,
  );
  final String id, book, chapter;
  final int revision;
  final Map<String, Object> options;
  final Uint8List? userFont;
}

String _fontHash(Uint8List bytes) => sha256.convert(bytes).toString();

// Native captures use fast lossless WebP on Android 11+, PNG on older devices.
// This is a bounded header check; Flutter's codec validates the image itself.
bool _isPageImage(Uint8List bytes) {
  if (bytes.length < 20 || bytes.length > 8 * 1024 * 1024) return false;
  if (bytes.length >= 33 &&
      listEquals(bytes.sublist(0, 8), const [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ])) {
    return true;
  }
  return listEquals(bytes.sublist(0, 4), const [82, 73, 70, 70]) &&
      listEquals(bytes.sublist(8, 12), const [87, 69, 66, 80]) &&
      ByteData.sublistView(bytes).getUint32(4, Endian.little) ==
          bytes.length - 8 &&
      (listEquals(bytes.sublist(12, 16), const [86, 80, 56, 76]) ||
          listEquals(bytes.sublist(12, 16), const [86, 80, 56, 88]));
}

class EpubCssImageProvider extends ImageProvider<EpubCssImageProvider> {
  const EpubCssImageProvider(this.page);
  final ReaderCssPage page;
  @override
  Future<EpubCssImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    EpubCssImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);
  Future<ui.Codec> _load(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await page.read()));
  @override
  bool operator ==(Object other) =>
      other is EpubCssImageProvider &&
      other.page.key == page.key &&
      other.page.index == page.index;
  @override
  int get hashCode => Object.hash(page.key, page.index);
}
