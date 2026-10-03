import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/widgets/reader_paper_view.dart';

void main() {
  for (final family in <String?>[null, 'ImportedReaderKai']) {
    testWidgets(
      'catalog title uses ${family ?? 'default'} outside the encoded body',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const title = '第一章「正常 Unicode 标题」';
        final layout = ReaderViewportLayout(
          size: const Size(1200, 800),
          systemPadding: EdgeInsets.zero,
          leftPadding: 16,
          rightPadding: 16,
          topBarHeight: 48,
          bottomBarHeight: 48,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderPaperView(
                pages: const [
                  ReaderPage(content: 'encoded text', isImage: false),
                ],
                viewIndex: 0,
                layout: layout,
                chapterTitle: title,
                source: SourceId.lightNovelShelf,
                titleFontFamily: family ?? appFontFamily,
                textStyle: const TextStyle(
                  fontFamily: 'ShelfObfuscation',
                  fontSize: 18,
                  height: 1.3,
                  color: Colors.black,
                ),
                paragraphSpacing: 24,
              ),
            ),
          ),
        );
        final header = tester.widget<Text>(find.text(title));
        expect(header.style!.fontFamily, family ?? appFontFamily);
        expect(header.style!.fontFamilyFallback, [appFontFamily]);
        final body = tester.widget<RichText>(
          find.text('encoded text', findRichText: true),
        );
        expect(body.text.style!.fontFamily, 'ShelfObfuscation');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
