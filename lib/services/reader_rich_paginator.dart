import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_rich_typography.dart';

List<ReaderPage> paginateReaderDocument({
  required ReaderDocument document,
  required double width,
  required double height,
  required TextStyle style,
  required TextScaler textScaler,
  required double paragraphSpacing,
}) {
  final pages = <ReaderPage>[];
  final fragments = <ReaderFragment>[];
  var usedHeight = 0.0;
  var pendingBottom = 0.0;
  var offset = 0;
  var startOffset = 0;
  var endOffset = 0;

  void flush() {
    if (fragments.isNotEmpty) {
      pages.add(
        ReaderPage(
          content: fragments.map((item) => item.text).join('\n'),
          isImage: false,
          fragments: List.unmodifiable(fragments),
          textStart: startOffset,
          textEnd: endOffset,
        ),
      );
      fragments.clear();
    }
    usedHeight = 0;
    pendingBottom = 0;
  }

  for (final block in document.blocks) {
    if (block.style.breakBefore) flush();
    if (block.imageUrl != null || block.artworkUrl != null) {
      flush();
      pages.add(
        ReaderPage(
          content: block.artworkUrl ?? block.imageUrl!,
          isImage: true,
          textStart: offset,
          textEnd: offset + (block.artworkUrl != null ? block.text.length : 0),
          artworkText: block.artworkUrl != null ? block.text : null,
        ),
      );
      offset += block.plainText.length + 1;
      continue;
    }
    final text = block.text;
    if (text.isEmpty) continue;
    var start = 0;
    var tableAsText = false;
    if (block.cells.isNotEmpty) {
      final row = ReaderParagraphLayout(
        fragment: ReaderFragment(
          block: block,
          start: 0,
          end: text.length,
          first: true,
          last: true,
        ),
        baseStyle: style,
        width: width,
        textScaler: textScaler,
      );
      tableAsText = row.height > height;
      row.dispose();
    }
    while (start < text.length) {
      final first = start == 0;
      final top =
          first
              ? block.style.marginTop
                  .resolve(style.fontSize!, referenceWidth: width)
                  .clamp(0.0, height * .4)
              : 0.0;
      final gap = first ? math.max(pendingBottom, top) : 0.0;
      ReaderFragment fragment(int end) => ReaderFragment(
        block: block,
        start: start,
        end: end,
        first: first,
        last: end == text.length,
        gapBefore: gap,
        tableAsText: tableAsText,
      );
      final full = ReaderParagraphLayout(
        fragment: fragment(text.length),
        baseStyle: style,
        width: width,
        textScaler: textScaler,
      );
      try {
        final available = height - usedHeight - gap;
        if (full.height <= available + .001) {
          if (fragments.isEmpty) startOffset = offset + start;
          fragments.add(fragment(text.length));
          endOffset = offset + text.length + 1;
          usedHeight += full.height + gap;
          pendingBottom =
              block.style.hasMargins
                  ? block.style.marginBottom
                      .resolve(style.fontSize!, referenceWidth: width)
                      .clamp(0.0, height * .4)
                  : paragraphSpacing;
          start = text.length;
          break;
        }
        if ((block.style.keepTogether || full.isTable) &&
            fragments.isNotEmpty &&
            full.height <= height) {
          flush();
          continue;
        }
        // Use complete line boxes, then remeasure each candidate prefix with
        // identical run styles. CJK wrapping may change at the split itself.
        final ends = <int>[];
        for (final line in full.painter.computeLineMetrics()) {
          if (line.baseline + line.descent + full.textTop > available + .001) {
            break;
          }
          final position = full.painter.getPositionForOffset(
            Offset(line.left, line.baseline),
          );
          final end =
              start +
              full.painter.getLineBoundary(position).end -
              full.prefixLength;
          if (end > start) ends.add(end.clamp(start + 1, text.length));
        }
        var split = start;
        for (final end in ends.reversed) {
          final candidate = ReaderParagraphLayout(
            fragment: fragment(end),
            baseStyle: style,
            width: width,
            textScaler: textScaler,
          );
          try {
            if (candidate.height <= available + .001) {
              split = end;
              break;
            }
          } finally {
            candidate.dispose();
          }
        }
        if (split <= start) {
          if (fragments.isNotEmpty) {
            flush();
            continue;
          }
          // A reader viewport smaller than one styled line must not silently
          // clip content or retry forever. Leave the book usable after settings
          // are adjusted, with the same error as the ordinary reader.
          throw ArgumentError('阅读区域过小，请减小字号或页边距');
        }
        if (fragments.isEmpty) startOffset = offset + start;
        fragments.add(fragment(split));
        endOffset = offset + split;
        start = split;
        flush();
      } finally {
        full.dispose();
      }
    }
    offset += text.length + 1;
    if (block.style.breakAfter) flush();
  }
  flush();
  return pages.isEmpty
      ? [
        const ReaderPage(
          content: '',
          isImage: false,
          fragments: [],
          textStart: 0,
          textEnd: 0,
        ),
      ]
      : pages;
}
