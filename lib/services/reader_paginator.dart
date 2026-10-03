import 'package:flutter/material.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_typography.dart';

/// Every iteration consumes content or flushes a nonempty page.
List<ReaderPage> paginateReaderContent({
  required String content,
  required double canvasWidth,
  required double canvasHeight,
  required double fontSize,
  required double paragraphSpacing,
  required double lineHeight,
  String? fontFamily,
  TextScaler textScaler = TextScaler.noScaling,
  bool boldText = false,
}) {
  if (canvasWidth <= 0 ||
      canvasHeight <= 0 ||
      !canvasWidth.isFinite ||
      !canvasHeight.isFinite ||
      fontSize <= 0 ||
      !fontSize.isFinite ||
      lineHeight <= 0 ||
      !lineHeight.isFinite ||
      !paragraphSpacing.isFinite ||
      paragraphSpacing < 0) {
    throw ArgumentError('阅读区域过小，请减小字号或页边距');
  }
  final pages = <ReaderPage>[];
  final currentPage = StringBuffer();
  var freeHeight = canvasHeight;
  final style = readerBodyStyle(
    fontSize: fontSize,
    lineHeight: lineHeight,
    fontFamily: fontFamily,
    boldText: boldText,
  );

  void flush() {
    if (currentPage.isNotEmpty) {
      pages.add(ReaderPage(content: currentPage.toString(), isImage: false));
      currentPage.clear();
    }
    freeHeight = canvasHeight;
  }

  void text(String paragraph) {
    while (paragraph.isNotEmpty) {
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        strutStyle: StrutStyle.fromTextStyle(style),
        text: TextSpan(text: paragraph, style: style),
      );
      try {
        painter.layout(maxWidth: canvasWidth);
        final gap = currentPage.isEmpty ? 0.0 : paragraphSpacing;
        final availableHeight = freeHeight - gap;
        if (painter.height <= availableHeight + 0.001) {
          currentPage.writeln(paragraph);
          freeHeight -= painter.height + gap;
          break;
        }
        // A caret nearest the bottom edge can belong to a partially visible
        // line. Only consider complete line boxes and remeasure the prefix:
        // CJK punctuation can wrap differently when a paragraph is shortened.
        final lineEnds = <int>[];
        for (final line in painter.computeLineMetrics()) {
          if (line.baseline + line.descent > availableHeight + 0.001) break;
          final position = painter.getPositionForOffset(
            Offset(line.left, line.baseline),
          );
          lineEnds.add(painter.getLineBoundary(position).end);
        }
        final firstLineEnd =
            painter.getLineBoundary(const TextPosition(offset: 0)).end;
        var split = 0;
        for (final end in lineEnds.reversed) {
          if (end <= 0) continue;
          painter.text = TextSpan(
            text: paragraph.substring(0, end),
            style: style,
          );
          painter.layout(maxWidth: canvasWidth);
          if (painter.height <= availableHeight + 0.001) {
            split = end;
            break;
          }
        }
        if (split <= 0) {
          if (currentPage.isNotEmpty) {
            flush();
            continue;
          }
          // Even when a line is taller than the viewport, never retry it forever.
          split = firstLineEnd;
          if (split <= 0) split = paragraph.characters.first.length;
        }
        split = split.clamp(1, paragraph.length);
        currentPage.write(paragraph.substring(0, split));
        paragraph = paragraph.substring(split);
        flush();
      } finally {
        painter.dispose();
      }
    }
  }

  final imageMarker = RegExp(r'<!--image-->([^<]+)<!--image-->');
  for (final paragraph in content.split('\n')) {
    var offset = 0;
    for (final match in imageMarker.allMatches(paragraph)) {
      text(paragraph.substring(offset, match.start));
      flush();
      pages.add(ReaderPage(content: match.group(1)!.trim(), isImage: true));
      offset = match.end;
    }
    text(paragraph.substring(offset));
  }
  flush();
  return pages.isEmpty ? [ReaderPage(content: '', isImage: false)] : pages;
}
