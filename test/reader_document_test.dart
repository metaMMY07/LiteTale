import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_pagination_cache.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/services/reader_rich_typography.dart';
import 'package:wild/services/reader_typography.dart';
import 'package:wild/widgets/reader_styled_paragraph.dart';

ReaderDocument _story({double scale = 1}) => ReaderDocument([
  ReaderBlock(
    runs: [
      ReaderRun(
        '第一章 · A new journey',
        style: ReaderInlineStyle(bold: true, scale: scale),
      ),
    ],
    style: const ReaderBlockStyle(
      align: 'center',
      hasMargins: true,
      marginBottom: ReaderLength(em: 1),
    ),
  ),
  for (var i = 0; i < 12; i++)
    ReaderBlock(
      runs: [
        ReaderRun('段落$i：清晨的站台与远方的旅途。'),
        const ReaderRun(
          'Bold, italic and underlined. ',
          style: ReaderInlineStyle(
            italic: true,
            bold: true,
            underline: true,
            scale: 1.2,
          ),
        ),
        ReaderRun('我们沿着海边的小路走向下一站。' * 8),
      ],
      style: const ReaderBlockStyle(
        indent: ReaderLength(em: 2),
        lineHeight: 1.65,
        marginLeft: ReaderLength(em: .5),
        marginRight: ReaderLength(px: 6),
      ),
    ),
]);

List<ReaderPage> _pages(
  ReaderDocument document, {
  double width = 300,
  double height = 450,
  double fontSize = 16,
  TextScaler textScaler = TextScaler.noScaling,
  bool bold = false,
}) => paginateReaderContent(
  content: document.content,
  document: document,
  canvasWidth: width,
  canvasHeight: height,
  fontSize: fontSize,
  paragraphSpacing: 12,
  lineHeight: 1.5,
  textScaler: textScaler,
  boldText: bold,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('short lines align within the full width between CSS side margins', () {
    for (final align in ['left', 'center', 'right']) {
      final block = ReaderBlock(
        runs: const [ReaderRun('short')],
        style: ReaderBlockStyle(
          align: align,
          marginLeft: const ReaderLength(px: 20),
          marginRight: const ReaderLength(px: 30),
        ),
      );
      final layout = ReaderParagraphLayout(
        fragment: ReaderFragment(
          block: block,
          start: 0,
          end: block.text.length,
          first: true,
          last: true,
        ),
        baseStyle: const TextStyle(fontSize: 16),
        width: 300,
        textScaler: TextScaler.noScaling,
      );
      final line = layout.painter.computeLineMetrics().single;
      expect(layout.left, 20);
      expect(layout.painter.width, 250);
      if (align == 'center') {
        expect(line.left + line.width / 2, closeTo(125, .01));
      } else if (align == 'right') {
        expect(line.left + line.width, closeTo(250, .01));
      } else {
        expect(line.left, closeTo(0, .01));
      }
      layout.dispose();
    }
  });

  test(
    'rich document round-trips styles and slices UTF16 runs without markup',
    () {
      final doc = _story(scale: 1.8);
      final restored = ReaderDocument.fromJson(doc.toJson());
      expect(restored.cacheIdentity, doc.cacheIdentity);
      expect(restored.content, doc.content);
      final sample = ReaderDocument([
        ReaderBlock(
          runs: const [
            ReaderRun('abc'),
            ReaderRun('def', style: ReaderInlineStyle(italic: true)),
          ],
        ),
      ]);
      final slice = sample.slice(1, 5);
      expect(slice.content, 'bcde');
      expect(slice.blocks.single.runs.last.style.italic, isTrue);
      expect(
        () => ReaderDocument.fromJson({
          'schema': 1,
          'blocks': [
            {
              'runs': [],
              'style': {'lineHeight': double.nan},
            },
          ],
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'measured rich fragments paint within each page and keep every character',
    (tester) async {
      final doc = _story(scale: 1.7);
      for (final (width, height, scaler, bold) in [
        (300.0, 450.0, TextScaler.noScaling, false),
        (450.0, 300.0, const TextScaler.linear(1.35), true),
      ]) {
        final pages = _pages(
          doc,
          width: width,
          height: height,
          textScaler: scaler,
          bold: bold,
        );
        expect(pages.length, greaterThan(3));
        expect(
          pages.expand((p) => p.fragments!).map((f) => f.text).join(),
          doc.blocks.map((b) => b.text).join(),
        );
        final style = readerBodyStyle(
          fontSize: 16,
          lineHeight: 1.5,
          boldText: bold,
          color: Colors.black,
        );
        for (final page in pages) {
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final fragment in page.fragments!)
                        ReaderStyledParagraph(
                          fragment: fragment,
                          style: style,
                          textScaler: scaler,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          final boxes =
              tester
                  .renderObjectList<RenderBox>(
                    find.byType(ReaderStyledParagraph),
                  )
                  .toList();
          expect(
            boxes.fold<double>(0, (sum, box) => sum + box.size.height),
            lessThanOrEqualTo(height + .001),
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  test(
    'indent applies only to the first fragment and font scaling changes pagination',
    () {
      final doc = _story();
      final pages = _pages(doc);
      final fragments =
          pages
              .expand((p) => p.fragments!)
              .where((f) => f.block.style.indent.em > 0)
              .toList();
      final first = fragments.firstWhere((f) => f.first);
      final continuation = fragments.firstWhere((f) => !f.first);
      final style = readerBodyStyle(fontSize: 16, lineHeight: 1.5);
      final a = ReaderParagraphLayout(
        fragment: first,
        baseStyle: style,
        width: 300,
        textScaler: TextScaler.noScaling,
      );
      final b = ReaderParagraphLayout(
        fragment: continuation,
        baseStyle: style,
        width: 300,
        textScaler: TextScaler.noScaling,
      );
      expect(a.prefixLength, 1);
      expect(b.prefixLength, 0);
      a.dispose();
      b.dispose();
      expect(_pages(doc, fontSize: 22).length, greaterThan(pages.length));
    },
  );

  test('break rules produce real page boundaries without blank pages', () {
    final doc = ReaderDocument([
      ReaderBlock(
        runs: const [ReaderRun('before')],
        style: const ReaderBlockStyle(breakAfter: true),
      ),
      ReaderBlock(
        runs: const [ReaderRun('after')],
        style: const ReaderBlockStyle(breakBefore: true),
      ),
    ]);
    final pages = _pages(doc);
    expect(pages.map((page) => page.content).toList(), ['before', 'after']);
  });

  test('rich anchors remain tied to text after repeated reflow', () {
    final doc = _story();
    final portrait = _pages(doc);
    final landscape = _pages(doc, width: 500, height: 300);
    final anchor = ReaderPosition.at(portrait, 3);
    for (var i = 0; i < 5; i++) {
      final index = anchor.pageIn(landscape);
      expect(landscape[index].textStart!, lessThanOrEqualTo(anchor.textOffset));
      expect(landscape[index].textEnd!, greaterThan(anchor.textOffset));
      expect(anchor.pageIn(portrait), 3);
    }
    expect(ReaderPageOffsets(portrait).at(3).textOffset, anchor.textOffset);
  });

  test('pagination cache distinguishes equal text with different CSS', () {
    final cache = ReaderPaginationCache();
    final a = _story(scale: 1);
    final b = _story(scale: 2.5);
    expect(a.content, b.content);
    List<ReaderPage> request(ReaderDocument doc) => cache.paginate(
      sourceId: 'localEpub',
      bookId: 'book',
      chapterId: 'chapter',
      sessionGeneration: 1,
      content: doc.content,
      document: doc,
      canvasWidth: 300,
      canvasHeight: 450,
      fontSize: 16,
      paragraphSpacing: 12,
      lineHeight: 1.5,
    );
    final first = request(a);
    expect(identical(request(a), first), isTrue);
    expect(identical(request(b), first), isFalse);
    expect(cache.length, 2);
  });
}
