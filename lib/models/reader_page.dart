import 'package:wild/models/reader_document.dart';
import 'dart:typed_data';

class ReaderCssPage {
  const ReaderCssPage({
    required this.key,
    required this.index,
    required this.domStart,
    required this.domEnd,
    required this.read,
    this.fixedLayout = false,
    this.semanticText = '',
  });
  final String key;
  final int index, domStart, domEnd;
  final Future<Uint8List> Function() read;
  final bool fixedLayout;
  final String semanticText;
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
  });
  final ReaderBlock block;
  final int start, end;
  final bool first, last;
  final double gapBefore, gapAfter;
  final bool tableAsText;
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
  });
  final List<ReaderFragment>? fragments;
  // Rich pages use stable source-character offsets, never CSS/JSON/spacers.
  final int? textStart, textEnd;
  final String? chapterId, chapterTitle;
  final String? artworkText;
  final ReaderCssPage? cssPage;
}
