import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/reader_paper_view.dart';

ReaderViewportLayout layout(Size size) => ReaderViewportLayout(
  size: size,
  systemPadding: EdgeInsets.zero,
  leftPadding: 16,
  rightPadding: 16,
  topBarHeight: 56,
  bottomBarHeight: 56,
);

void main() {
  test(
    'content anchor survives repeated reflow and identifies consecutive images',
    () {
      const landscape = [
        ReaderPage(content: 'abcd', isImage: false),
        ReaderPage(content: 'efgh', isImage: false),
        ReaderPage(content: 'ijkl', isImage: false),
      ];
      const portrait = [
        ReaderPage(content: 'abcdef', isImage: false),
        ReaderPage(content: 'ghijkl', isImage: false),
      ];
      final anchor = ReaderPosition.at(landscape, 2);
      expect(anchor.pageIn(portrait), 1);
      expect(anchor.pageIn(landscape), 2);
      const illustrated = [
        ReaderPage(content: 'abcd', isImage: false),
        ReaderPage(content: 'a.jpg', isImage: true),
        ReaderPage(content: 'a.jpg', isImage: true),
        ReaderPage(content: 'efgh', isImage: false),
      ];
      const reflowed = [
        ReaderPage(content: 'ab', isImage: false),
        ReaderPage(content: 'cd', isImage: false),
        ReaderPage(content: 'a.jpg', isImage: true),
        ReaderPage(content: 'a.jpg', isImage: true),
        ReaderPage(content: 'efgh', isImage: false),
      ];
      expect(ReaderPosition.at(illustrated, 2).pageIn(reflowed), 3);
      expect(ReaderPosition.at(illustrated, 3).pageIn(reflowed), 4);
    },
  );
  test(
    'tablet landscape pairs leaves; phones and narrow windows stay single',
    () {
      expect(layout(const Size(1200, 800)).isSpread, isTrue);
      expect(layout(const Size(800, 1200)).isSpread, isFalse);
      expect(layout(const Size(800, 400)).isSpread, isFalse);
      expect(layout(const Size(580, 720)).isSpread, isFalse);
      final book = layout(const Size(1200, 800));
      expect(book.viewCount(5), 3);
      expect(book.viewIndex(3), 1);
      expect(book.firstPage(2), 4);
      expect(book.contentWidth, lessThan(600));
    },
  );

  testWidgets(
    'both leaves fit measured pages and keep every character in order',
    (tester) async {
      const size = Size(1200, 800);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final book = layout(size);
      final content = List.generate(
        90,
        (i) => '　　第$i段：这是用来检查双页排版和阅读顺序的正文。' * 4,
      ).join('\n');
      final pages = paginateReaderContent(
        content: content,
        canvasWidth: book.contentWidth,
        canvasHeight: book.contentHeight,
        fontSize: 18,
        paragraphSpacing: 24,
        lineHeight: 1.3,
      );
      expect(
        pages.map((p) => p.content).join('').replaceAll('\n', ''),
        content.replaceAll('\n', ''),
      );
      for (var i = 0; i < book.viewCount(pages.length); i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderPaperView(
                pages: pages,
                viewIndex: i,
                layout: book,
                chapterTitle: '双页测试',
                source: SourceId.wenku8,
                textStyle: const TextStyle(
                  fontSize: 18,
                  height: 1.3,
                  letterSpacing: .5,
                ),
                paragraphSpacing: 24,
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'spread $i overflows');
        final first = i * 2;
        expect(find.text('${first + 1}/${pages.length}'), findsNothing);
        if (first + 1 < pages.length) {
          expect(find.text('${first + 2}/${pages.length}'), findsNothing);
          final left = tester.getRect(
            find.byKey(ValueKey('reader-leaf-$first')),
          );
          final right = tester.getRect(
            find.byKey(ValueKey('reader-leaf-${first + 1}')),
          );
          expect(left.right, right.left);
          expect(left.width, 600);
        }
      }
    },
  );

  testWidgets(
    'odd final spread has a blank right leaf without a fake page number',
    (tester) async {
      const size = Size(1200, 800);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPaperView(
              pages: const [ReaderPage(content: '左页唯一正文', isImage: false)],
              viewIndex: 0,
              layout: layout(size),
              chapterTitle: '末页',
              source: SourceId.wenku8,
              textStyle: const TextStyle(
                fontSize: 18,
                height: 1.3,
                letterSpacing: .5,
              ),
              paragraphSpacing: 24,
            ),
          ),
        ),
      );
      expect(find.text('左页唯一正文', findRichText: true), findsOneWidget);
      expect(find.text('1/1'), findsNothing);
      expect(find.text('2/1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
