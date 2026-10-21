import 'dart:async';
import 'dart:convert';

import 'package:wild/services/reader_position.dart';
import 'package:wild/src/rust/api/database.dart' as db;

/// Restores a local EPUB's last content anchor independently of page size.
/// The ordinary history row remains authoritative for the selected chapter;
/// this optional record is usable only when both book and chapter match.
class EpubReaderPositionStore {
  EpubReaderPositionStore({
    Future<String> Function(String key)? readProperty,
    Future<void> Function(String key, String value)? writeProperty,
    this.readTimeout = const Duration(milliseconds: 150),
    int cacheEntries = 64,
  }) : _readProperty = readProperty ?? ((key) => db.loadProperty(key: key)),
       _writeProperty =
           writeProperty ??
           ((key, value) => db.saveProperty(key: key, value: value)),
       _cacheEntries = cacheEntries.clamp(0, 64);

  static final instance = EpubReaderPositionStore();
  static final _bookPattern = RegExp(r'^epub:[a-f0-9]{64}$');
  static final _chapterSuffix = RegExp(r'^c(?:0|[1-9][0-9]{0,5})$');
  static const _maxTextOffset = 32 * 1024 * 1024;
  static const _maxPrecedingImages = 100000;
  static const _maxRecordLength = 2048;

  final Future<String> Function(String key) _readProperty;
  final Future<void> Function(String key, String value) _writeProperty;
  final Duration readTimeout;
  final int _cacheEntries;
  final _cache = <String, _SavedPosition?>{};
  final _loading = <String, Future<_SavedPosition?>>{};
  Future<void> _pendingWrite = Future.value();
  int _revision = 0;

  static bool isLocalBook(String bookId) =>
      bookId.length == 69 && _bookPattern.hasMatch(bookId);

  static bool _validChapter(String bookId, String chapterId) {
    if (!isLocalBook(bookId) || !chapterId.startsWith('$bookId:')) {
      return false;
    }
    final suffix = chapterId.substring(bookId.length + 1);
    return _chapterSuffix.firstMatch(suffix)?.end == suffix.length;
  }

  static bool _validPosition(ReaderPosition position) =>
      position.textOffset >= 0 &&
      position.textOffset <= _maxTextOffset &&
      position.precedingImages >= 0 &&
      position.precedingImages <= _maxPrecedingImages &&
      (position.epubOffset == null ||
          position.epubOffset! >= 0 && position.epubOffset! <= _maxTextOffset);

  String _key(String bookId) =>
      'epub_reader_position_v1:${bookId.substring(5)}';

  Future<ReaderPosition?> read(String bookId, String chapterId) async {
    if (!_validChapter(bookId, chapterId)) return null;
    final revision = _revision;
    if (_cache.containsKey(bookId)) {
      final cached = _cache.remove(bookId);
      _cache[bookId] = cached;
      return cached?.chapterId == chapterId ? cached?.position : null;
    }

    var loading = _loading[bookId];
    if (loading == null) {
      // A wedged platform read must not accumulate one request per book or
      // delay a chapter already available from its private EPUB files.
      if (_loading.length >= 64) return null;
      late final Future<_SavedPosition?> pending;
      pending = _load(bookId, _revision).whenComplete(() {
        if (identical(_loading[bookId], pending)) _loading.remove(bookId);
      });
      _loading[bookId] = loading = pending;
    }
    try {
      final saved = await loading.timeout(readTimeout);
      if (revision != _revision) return null;
      return saved?.chapterId == chapterId ? saved?.position : null;
    } on TimeoutException {
      // The original read stays shared. It may warm RAM later, but a write or
      // clear invalidates its result before it can restore a stale anchor.
      return null;
    }
  }

  Future<_SavedPosition?> _load(String bookId, int revision) async {
    try {
      final encoded = await _readProperty(_key(bookId));
      if (revision != _revision) return null;
      final saved = _decode(bookId, encoded);
      _remember(bookId, saved);
      return saved;
    } catch (_) {
      // Corrupt, old or unavailable optional position data uses normal history.
      return null;
    }
  }

  _SavedPosition? _decode(String bookId, String encoded) {
    if (encoded.isEmpty || encoded.length > _maxRecordLength) return null;
    final value = jsonDecode(encoded);
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['bookId'] != bookId ||
        value['chapterId'] is! String ||
        value['textOffset'] is! int ||
        value['precedingImages'] is! int ||
        value['onImage'] is! bool) {
      return null;
    }
    final chapterId = value['chapterId'] as String;
    if (value['epubOffset'] != null && value['epubOffset'] is! int) return null;
    final position = ReaderPosition(
      value['textOffset'] as int,
      value['precedingImages'] as int,
      value['onImage'] as bool,
      epubOffset: value['epubOffset'] as int?,
    );
    return _validChapter(bookId, chapterId) && _validPosition(position)
        ? _SavedPosition(chapterId, position)
        : null;
  }

  Future<void> write(String bookId, String chapterId, ReaderPosition position) {
    if (!_validChapter(bookId, chapterId) || !_validPosition(position)) {
      return Future.error(ArgumentError('本地阅读位置无效'));
    }
    _revision++;
    _cache.remove(bookId);
    final encoded = jsonEncode({
      'version': 1,
      'bookId': bookId,
      'chapterId': chapterId,
      'textOffset': position.textOffset,
      'precedingImages': position.precedingImages,
      'onImage': position.onImage,
      if (position.epubOffset != null) 'epubOffset': position.epubOffset,
    });
    return _serialize(() async {
      await _writeProperty(_key(bookId), encoded);
      _remember(bookId, _SavedPosition(chapterId, position));
    });
  }

  Future<void> clear(String bookId) {
    if (!isLocalBook(bookId)) {
      return Future.error(ArgumentError('本地书籍编号无效'));
    }
    _revision++;
    _cache.remove(bookId);
    return _serialize(() async {
      // Property storage has no delete method. An empty value is explicitly
      // treated as absent by this versioned, local-book-only reader.
      await _writeProperty(_key(bookId), '');
      _remember(bookId, null);
    });
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _pendingWrite.then((_) => action());
    _pendingWrite = next.catchError((Object _) {});
    return next;
  }

  void _remember(String bookId, _SavedPosition? value) {
    if (_cacheEntries == 0) return;
    _cache.remove(bookId);
    _cache[bookId] = value;
    while (_cache.length > _cacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }
}

class _SavedPosition {
  const _SavedPosition(this.chapterId, this.position);
  final String chapterId;
  final ReaderPosition position;
}
