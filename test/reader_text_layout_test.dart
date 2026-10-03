import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/services/reader_typography.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/widgets/reader_paper_view.dart';

// Uneven paragraphs and CJK punctuation expose wrapping at a page boundary;
// a monospace test font and identical paragraphs do not reproduce the reader.
final _content = List.generate(40, (i) {
  final sentence = switch (i % 4) {
    0 => '　　「您抱着断气的苏菲亚来到地下神殿，为了让苏菲亚死而复生成为第一个《女武神》。 」',
    1 => '　　兽耳无力地下垂。耳朵下面的脸孔也挂着痛苦的表情唉声叹气。',
    2 => '　　艾莉莎接着把视线投向苏菲亚。',
    _ =>
      '　　当中有超过一半的内容，都提到了我和苏菲亚的关系。'
          '还有 English words, 12345，标点「……！」和表情 👩🏽‍💻。',
  };
  return '【段$i】$sentence${sentence * (i % 3)}';
}).join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader(appFontFamily)
      ..addFont(rootBundle.load('lib/assets/fonts/LXGWNeoZhiSongPlus.ttf'));
    await loader.load();
  });

  for (final setting in [
    (
      size: const Size(1280, 905),
      scale: 1.0,
      font: 18.0,
      gap: 24.0,
      height: 1.3,
      bold: false,
    ),
    (
      size: const Size(1280, 905),
      scale: 1.4,
      font: 18.0,
      gap: 24.0,
      height: 1.3,
      bold: false,
    ),
    (
      size: const Size(1280, 905),
      scale: 2.0,
      font: 24.0,
      gap: 8.0,
      height: 1.5,
      bold: true,
    ),
    (
      size: const Size(800, 1200),
      scale: 1.4,
      font: 22.0,
      gap: 16.0,
      height: 1.3,
      bold: false,
    ),
    (
      size: const Size(920, 650),
      scale: 1.2,
      font: 18.0,
      gap: 0.0,
      height: 1.0,
      bold: false,
    ),
  ]) {
    testWidgets('CJK page bounds: $setting', (tester) async {
      final size = setting.size;
      final scaler = TextScaler.linear(setting.scale);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final layout = ReaderViewportLayout(
        size: size,
        systemPadding: EdgeInsets.zero,
        leftPadding: 16,
        rightPadding: 16,
        topBarHeight: 56,
        bottomBarHeight: 56,
        textScaler: scaler,
        boldText: setting.bold,
      );
      final pages = paginateReaderContent(
        content: _content,
        canvasWidth: layout.contentWidth,
        canvasHeight: layout.contentHeight,
        fontSize: setting.font,
        paragraphSpacing: setting.gap,
        lineHeight: setting.height,
        textScaler: scaler,
        boldText: setting.bold,
      );
      expect(
        pages.map((p) => p.content).join('').replaceAll('\n', ''),
        _content.replaceAll('\n', ''),
      );
      for (var spread = 0; spread < layout.viewCount(pages.length); spread++) {
        await tester.pumpWidget(
          MaterialApp(
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: scaler, boldText: setting.bold),
                  child: child!,
                ),
            home: Scaffold(
              body: ReaderPaperView(
                pages: pages,
                viewIndex: spread,
                layout: layout,
                chapterTitle: '第一话 前·底层村民开始和美少女们同居',
                source: SourceId.wenku8,
                textStyle: readerBodyStyle(
                  fontSize: setting.font,
                  lineHeight: setting.height,
                  boldText: setting.bold,
                ),
                paragraphSpacing: setting.gap,
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'spread $spread');
        final first = layout.firstPage(spread);
        for (
          var index = first;
          index < pages.length && index < first + (layout.isSpread ? 2 : 1);
          index++
        ) {
          final leaf = find.byKey(ValueKey('reader-leaf-$index'));
          final bottom = size.height - layout.insets.bottom;
          final renderedText = StringBuffer();
          for (final element
              in find
                  .descendant(of: leaf, matching: find.byType(RichText))
                  .evaluate()) {
            final paragraph = element.renderObject! as RenderParagraph;
            final rect = tester.getRect(find.byWidget(element.widget));
            expect(rect.bottom, lessThanOrEqualTo(bottom + .01));
            expect(paragraph.didExceedMaxLines, isFalse);
            final text = paragraph.text.toPlainText();
            if (text != '第一话 前·底层村民开始和美少女们同居') {
              renderedText.write(text);
            }
          }
          expect(
            renderedText.toString(),
            pages[index].content.replaceAll('\n', ''),
          );
        }
      }
    });
  }
}
