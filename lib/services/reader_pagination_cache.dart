import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/settings/settings_preferences.dart' show readerHanLocale;

/// Increment when pagination behavior changes in a way that affects page cuts.
const int readerPaginationAlgorithmVersion = 2;

/// Inputs needed to run the existing paginator. [hanLocale] is captured from
/// the same preference read by reader typography immediately before compute.
class ReaderPaginationInput {
  const ReaderPaginationInput({
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.sessionGeneration,
    required this.content,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.fontSize,
    required this.paragraphSpacing,
    required this.lineHeight,
    required this.fontFamily,
    required this.textScaler,
    required this.boldText,
    required this.hanLocale,
    required this.algorithmVersion,
    this.document,
  });

  final String sourceId;
  final String bookId;
  final String chapterId;
  final int sessionGeneration;
  final String content;
  final double canvasWidth;
  final double canvasHeight;
  final double fontSize;
  final double paragraphSpacing;
  final double lineHeight;
  final String? fontFamily;
  final TextScaler textScaler;
  final bool boldText;
  final Locale? hanLocale;
  final int algorithmVersion;
  final ReaderDocument? document;
}

typedef ReaderPaginationCompute =
    List<ReaderPage> Function(ReaderPaginationInput input);

/// A small LRU for measured page layouts. The original paginator remains the
/// only implementation of pagination; this wrapper only reuses exact inputs.
class ReaderPaginationCache {
  ReaderPaginationCache({
    int maxEntries = 3,
    int maxRetainedCodeUnits = 1000000,
    ReaderPaginationCompute? compute,
  }) : _maxEntries = maxEntries,
       _maxRetainedCodeUnits = maxRetainedCodeUnits,
       _compute = compute ?? _paginate {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
    if (maxRetainedCodeUnits < 1) {
      throw ArgumentError.value(
        maxRetainedCodeUnits,
        'maxRetainedCodeUnits',
        'must be positive',
      );
    }
  }

  static final instance = ReaderPaginationCache();

  final int _maxEntries;
  final int _maxRetainedCodeUnits;
  final ReaderPaginationCompute _compute;
  final LinkedHashMap<_ReaderPaginationKey, _CachedPages> _entries =
      LinkedHashMap<_ReaderPaginationKey, _CachedPages>();
  int _retainedCodeUnits = 0;

  int get length => _entries.length;
  int get retainedCodeUnits => _retainedCodeUnits;

  /// Returns an immutable list. A cache hit returns the same list instance.
  ///
  /// [sourceId] should be the stable source key; [bookId] may also carry the
  /// legacy source prefix. Both are included so equal numeric IDs from distinct
  /// sources cannot reuse pagination. The full [content] string participates
  /// in key equality, not just its hash.
  List<ReaderPage> paginate({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required int sessionGeneration,
    required String content,
    required double canvasWidth,
    required double canvasHeight,
    required double fontSize,
    required double paragraphSpacing,
    required double lineHeight,
    String? fontFamily,
    TextScaler textScaler = TextScaler.noScaling,
    bool boldText = false,
    int algorithmVersion = readerPaginationAlgorithmVersion,
    ReaderDocument? document,
  }) {
    // The paginator's TextStyle reads this same setting through
    // reader_typography.dart. Capture it synchronously before compute.
    final hanLocale = readerHanLocale;
    final key = _ReaderPaginationKey(
      sourceId: sourceId,
      bookId: bookId,
      chapterId: chapterId,
      sessionGeneration: sessionGeneration,
      content: content,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fontSize: fontSize,
      paragraphSpacing: paragraphSpacing,
      lineHeight: lineHeight,
      fontFamily: fontFamily,
      textScaler: textScaler,
      boldText: boldText,
      hanLocale: hanLocale,
      algorithmVersion: algorithmVersion,
      documentIdentity: document?.cacheIdentity,
    );

    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
      return hit.pages;
    }

    final input = ReaderPaginationInput(
      sourceId: sourceId,
      bookId: bookId,
      chapterId: chapterId,
      sessionGeneration: sessionGeneration,
      content: content,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fontSize: fontSize,
      paragraphSpacing: paragraphSpacing,
      lineHeight: lineHeight,
      fontFamily: fontFamily,
      textScaler: textScaler,
      boldText: boldText,
      hanLocale: hanLocale,
      algorithmVersion: algorithmVersion,
      document: document,
    );
    final pages = List<ReaderPage>.unmodifiable(_compute(input));
    final outputCodeUnits = pages.fold<int>(
      0,
      (total, page) => total + page.content.length,
    );
    final entryCodeUnits =
        content.length +
        outputCodeUnits +
        (document?.cacheIdentity.length ?? 0);

    // A large chapter is still paginated normally, but is not retained.
    if (entryCodeUnits > _maxRetainedCodeUnits) return pages;

    while (_entries.isNotEmpty &&
        (_entries.length >= _maxEntries ||
            _retainedCodeUnits + entryCodeUnits > _maxRetainedCodeUnits)) {
      final oldestKey = _entries.keys.first;
      _retainedCodeUnits -= _entries.remove(oldestKey)!.retainedCodeUnits;
    }
    _entries[key] = _CachedPages(pages, entryCodeUnits);
    _retainedCodeUnits += entryCodeUnits;
    return pages;
  }

  void clear() {
    _entries.clear();
    _retainedCodeUnits = 0;
  }

  void evictBook(String bookId) {
    for (final key
        in _entries.keys.where((key) => key.bookId == bookId).toList()) {
      _retainedCodeUnits -= _entries.remove(key)!.retainedCodeUnits;
    }
  }

  static List<ReaderPage> _paginate(ReaderPaginationInput input) =>
      paginateReaderContent(
        content: input.content,
        canvasWidth: input.canvasWidth,
        canvasHeight: input.canvasHeight,
        fontSize: input.fontSize,
        paragraphSpacing: input.paragraphSpacing,
        lineHeight: input.lineHeight,
        fontFamily: input.fontFamily,
        textScaler: input.textScaler,
        boldText: input.boldText,
        document: input.document,
      );
}

class _CachedPages {
  const _CachedPages(this.pages, this.retainedCodeUnits);

  final List<ReaderPage> pages;
  final int retainedCodeUnits;
}

class _ReaderPaginationKey {
  const _ReaderPaginationKey({
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.sessionGeneration,
    required this.content,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.fontSize,
    required this.paragraphSpacing,
    required this.lineHeight,
    required this.fontFamily,
    required this.textScaler,
    required this.boldText,
    required this.hanLocale,
    required this.algorithmVersion,
    this.documentIdentity,
  });

  final String sourceId;
  final String bookId;
  final String chapterId;
  final int sessionGeneration;
  final String content;
  final double canvasWidth;
  final double canvasHeight;
  final double fontSize;
  final double paragraphSpacing;
  final double lineHeight;
  final String? fontFamily;
  final TextScaler textScaler;
  final bool boldText;
  final Locale? hanLocale;
  final int algorithmVersion;
  final String? documentIdentity;

  @override
  bool operator ==(Object other) =>
      other is _ReaderPaginationKey &&
      sourceId == other.sourceId &&
      bookId == other.bookId &&
      chapterId == other.chapterId &&
      sessionGeneration == other.sessionGeneration &&
      content == other.content &&
      documentIdentity == other.documentIdentity &&
      canvasWidth == other.canvasWidth &&
      canvasHeight == other.canvasHeight &&
      fontSize == other.fontSize &&
      paragraphSpacing == other.paragraphSpacing &&
      lineHeight == other.lineHeight &&
      fontFamily == other.fontFamily &&
      (identical(textScaler, other.textScaler) ||
          textScaler == other.textScaler) &&
      boldText == other.boldText &&
      hanLocale == other.hanLocale &&
      algorithmVersion == other.algorithmVersion;

  @override
  int get hashCode => Object.hashAll([
    sourceId,
    bookId,
    chapterId,
    sessionGeneration,
    content,
    documentIdentity,
    canvasWidth,
    canvasHeight,
    fontSize,
    paragraphSpacing,
    lineHeight,
    fontFamily,
    textScaler,
    boldText,
    hanLocale,
    algorithmVersion,
  ]);
}
