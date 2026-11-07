import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:wild/models/reader_mark.dart';
import 'package:wild/src/rust/api/database.dart' as db;

/// A book's marks are one atomic SQLite property. Serialize read-modify-write
/// across reader routes, and publish changes only after a successful write.
class ReaderMarkStore extends ChangeNotifier {
  ReaderMarkStore({
    Future<String> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  }) : _read = read ?? ((key) => db.loadProperty(key: key)),
       _write =
           write ?? ((key, value) => db.saveProperty(key: key, value: value));

  static final instance = ReaderMarkStore();
  static const _maxBooksInMemory = 8;
  static const _maxMarksPerBook = 2000;
  static const _maxRecordBytes = 4 * 1024 * 1024;
  final Future<String> Function(String) _read;
  final Future<void> Function(String, String) _write;
  final _cache = <String, List<ReaderMark>>{};
  final _pending = <String, Future<void>>{};
  final _random = Random.secure();

  List<ReaderMark> marks(String book) => _cache[book] ?? const [];
  bool isLoaded(String book) => _cache.containsKey(book);

  String _key(String book) =>
      'reader_marks_v1:${sha256.convert(utf8.encode(book))}';

  Future<void> _serialize(String book, Future<void> Function() action) {
    final previous = _pending[book] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((Object _) {})
        .then((_) => action())
        .whenComplete(() {
          if (identical(_pending[book], next)) _pending.remove(book);
        });
    _pending[book] = next;
    return next;
  }

  void _remember(String book, List<ReaderMark> value) {
    _cache.remove(book);
    _cache[book] = List.unmodifiable(value);
    while (_cache.length > _maxBooksInMemory) {
      _cache.remove(_cache.keys.first);
    }
    notifyListeners();
  }

  Future<void> _load(String book) async {
    if (isLoaded(book)) return;
    final encoded = await _read(_key(book));
    if (encoded.isEmpty) {
      _remember(book, const []);
      return;
    }
    if (encoded.length > _maxRecordBytes) {
      throw const FormatException('reader marks too large');
    }
    final value = jsonDecode(encoded);
    if (value is! Map ||
        value['version'] != 1 ||
        value['book'] != book ||
        value['marks'] is! List ||
        (value['marks'] as List).length > _maxMarksPerBook) {
      throw const FormatException('unsupported reader marks');
    }
    final ids = <String>{};
    final marks =
        (value['marks'] as List).map((entry) {
          final mark = ReaderMark.fromJson(entry as Map);
          if (!ids.add(mark.id)) {
            throw const FormatException('duplicate reader mark');
          }
          return mark;
        }).toList();
    _remember(book, marks);
  }

  Future<void> load(String book) =>
      isLoaded(book) ? Future.value() : _serialize(book, () => _load(book));

  Future<void> _edit(String book, bool Function(List<ReaderMark>) edit) =>
      _serialize(book, () async {
        await _load(book);
        final next = marks(book).toList();
        if (!edit(next)) return;
        final encoded = jsonEncode({
          'version': 1,
          'book': book,
          'marks': next.map((mark) => mark.toJson()).toList(),
        });
        if (next.length > _maxMarksPerBook ||
            utf8.encode(encoded).length > _maxRecordBytes) {
          throw StateError('此书的标记已达上限');
        }
        await _write(_key(book), encoded);
        _remember(book, next);
      });

  String _id() =>
      List.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<void> addBookmark(
    String book,
    ReaderMarkLocation location, {
    String quote = '',
  }) => _edit(book, (next) {
    if (next.any(
      (mark) => mark.isBookmark && mark.location.samePosition(location),
    )) {
      return false;
    }
    next.insert(
      0,
      ReaderMark(
        id: _id(),
        location: location,
        createdAt: DateTime.now(),
        quote: quote,
      ),
    );
    return true;
  });

  Future<void> saveHighlight(
    String book,
    ReaderMarkLocation location, {
    required String quote,
    required ReaderMarkColor color,
    String? note,
    bool encodedQuote = false,
    String? matchId,
  }) => _edit(book, (next) {
    if (quote.trim().isEmpty ||
        quote.length > ReaderMark.maxQuoteLength ||
        (note?.length ?? 0) > ReaderMark.maxNoteLength) {
      throw ArgumentError('选区或笔记无效');
    }
    final index = next.indexWhere(
      (mark) =>
          !mark.isBookmark &&
          (mark.id == matchId ||
              mark.location.samePosition(location) && mark.quote == quote),
    );
    final existing = index < 0 ? null : next[index];
    final mark = ReaderMark(
      id: existing?.id ?? _id(),
      location: location,
      createdAt: existing?.createdAt ?? DateTime.now(),
      quote: quote,
      color: color,
      note: note ?? existing?.note ?? '',
      encodedQuote: encodedQuote,
    );
    if (index < 0) {
      next.insert(0, mark);
    } else {
      next[index] = mark;
    }
    return true;
  });

  Future<void> editNote(String book, String id, String note) => _edit(book, (
    next,
  ) {
    if (note.length > ReaderMark.maxNoteLength) throw ArgumentError('笔记过长');
    final index = next.indexWhere((mark) => mark.id == id && !mark.isBookmark);
    if (index < 0) return false;
    next[index] = next[index].withNote(note);
    return true;
  });

  Future<void> remove(String book, String id) => _edit(book, (next) {
    final index = next.indexWhere((mark) => mark.id == id);
    if (index < 0) return false;
    next.removeAt(index);
    return true;
  });
}
