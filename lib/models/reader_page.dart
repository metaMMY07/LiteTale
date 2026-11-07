import 'package:wild/models/reader_document.dart';
import 'dart:typed_data';
import 'package:flutter/painting.dart';

class ReaderCssImageRegion {
  const ReaderCssImageRegion({
    required this.key,
    required this.rect,
    required this.read,
  });
  final String key;

  /// Normalized coordinates in the same complete leaf as the captured bitmap.
  final Rect rect;
  final Future<Uint8List> Function() read;
}

/// A grapheme and its word in the chapter's DOM text coordinate space.
class ReaderCssMarkGlyph {
  const ReaderCssMarkGlyph(
    this.start,
    this.end,
    this.wordStart,
    this.wordEnd,
    this.rect,
  );
  final int start, end, wordStart, wordEnd;
  final Rect rect;
}

class ReaderCssPage {
  const ReaderCssPage({
    required this.key,
    required this.index,
    required this.domStart,
    required this.domEnd,
    required this.read,
    this.fixedLayout = false,
    this.semanticText = '',
    this.readImages,
    this.markText,
    this.readMarkGlyphs,
  });
  final String key;
  final int index, domStart, domEnd;
  final Future<Uint8List> Function() read;
  final bool fixedLayout;
  final String semanticText;
  final Future<List<ReaderCssImageRegion>> Function()? readImages;
  final String? markText;
  final Future<List<ReaderCssMarkGlyph>> Function()? readMarkGlyphs;
}

class ReaderFragment {
  const ReaderFragment({
    required this.block,
    required this.start,
    required this.end,
    required this.first,
    required this.last,
    this.gapBefore = 0,
    this.gapAfter = 0,
    this.tableAsText = false,
    this.sourceOffset,
  });
  final ReaderBlock block;
  final int start, end;
  final bool first, last;
  final double gapBefore, gapAfter;
  final bool tableAsText;

  /// Chapter offset of the first character in this displayed fragment.
  final int? sourceOffset;
  String get text => block.text.substring(start, end);
}

class ReaderPage {
  final String content;
  final bool isImage;

  const ReaderPage({
    required this.content,
    required this.isImage,
    this.fragments,
    this.textStart,
    this.textEnd,
    this.chapterId,
    this.chapterTitle,
    this.artworkText,
    this.cssPage,
    this.sourceStart,
    this.sourceEnd,
    this.paragraphOffsets,
  });
  final List<ReaderFragment>? fragments;
  // Rich pages use stable source-character offsets, never CSS/JSON/spacers.
  final int? textStart, textEnd;
  final String? chapterId, chapterTitle;
  final String? artworkText;
  final ReaderCssPage? cssPage;
  // Plain pagination inserts its own line breaks. Keep the original offsets
  // separately so marking does not change legacy reading-history semantics.
  final int? sourceStart, sourceEnd;
  final List<int>? paragraphOffsets;
  int? get markStart => sourceStart ?? textStart;
  int? get markEnd => sourceEnd ?? textEnd;
}
