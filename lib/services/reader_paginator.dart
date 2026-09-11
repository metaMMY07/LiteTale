import 'package:flutter/material.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/theme/app_fonts.dart';

/// Every iteration consumes content or flushes a nonempty page.
List<ReaderPage> paginateReaderContent({
  required String content,
  required double canvasWidth,
  required double canvasHeight,
  required double fontSize,
  required double paragraphSpacing,
  required double lineHeight,
  String? fontFamily,
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
        strutStyle: StrutStyle(fontFamily: fontFamily ?? appFontFamily, height: lineHeight),
        text: TextSpan(
          text: paragraph,
          style: TextStyle(
            fontFamily: fontFamily ?? appFontFamily,
            fontSize: fontSize,
            height: lineHeight,
            letterSpacing: 0.5,
          ),
        ),
      );
      try {
        painter.layout(maxWidth: canvasWidth);
        if (painter.height <= freeHeight) {
          currentPage.writeln(paragraph);
          freeHeight -= painter.height + paragraphSpacing;
          break;
        }
        var split = painter.getPositionForOffset(Offset(0, freeHeight)).offset;
        if (split <= 0) {
          if (currentPage.isNotEmpty) {
            flush();
            continue;
          }
          // Even when a line is taller than the viewport, never retry it forever.
          split = painter.getLineBoundary(const TextPosition(offset: 0)).end;
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
