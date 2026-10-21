import 'package:flutter/material.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/widgets/reader_raster_readiness.dart';
import 'package:wild/widgets/reader_styled_paragraph.dart';
import 'package:wild/services/epub/epub_css_reader.dart';

/// A real spread contains two independently paginated leaves. Text continues
/// from the left leaf to the right, rather than being laid out across the seam.
class ReaderPaperView extends StatelessWidget {
  const ReaderPaperView({
    super.key,
    required this.pages,
    required this.viewIndex,
    required this.layout,
    required this.chapterTitle,
    required this.source,
    required this.textStyle,
    required this.paragraphSpacing,
    this.titleFontFamily = appFontFamily,
  });

  final List<ReaderPage> pages;
  final int viewIndex;
  final ReaderViewportLayout layout;
  final String chapterTitle;
  final SourceId source;
  final TextStyle textStyle;
  final double paragraphSpacing;
  // Catalog titles are normal Unicode, never chapter-obfuscated glyph codes.
  final String titleFontFamily;

  Widget _leaf(int index, {required bool showTitle}) => ReaderPaperLeaf(
    key: ValueKey('reader-leaf-$index'),
    page: index < pages.length ? pages[index] : null,
    layout: layout,
    chapterTitle:
        showTitle
            ? (index < pages.length
                ? pages[index].chapterTitle ?? chapterTitle
                : '')
            : '',
    source: source,
    textStyle: textStyle,
    paragraphSpacing: paragraphSpacing,
    titleFontFamily: titleFontFamily,
  );

  @override
  Widget build(BuildContext context) {
    final first = layout.firstPage(viewIndex);
    if (!layout.isSpread) return _leaf(first, showTitle: false);
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          children: [
            Expanded(child: _leaf(first, showTitle: true)),
            Expanded(
              child: _leaf(
                first + 1,
                showTitle:
                    first + 1 < pages.length &&
                    pages[first + 1].chapterId != pages[first].chapterId,
              ),
            ),
          ],
        ),
        Center(
          child: IgnorePointer(
            child: Container(
              width: 16,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.035),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class ReaderPaperLeaf extends StatelessWidget {
  const ReaderPaperLeaf({
    super.key,
    required this.page,
    required this.layout,
    required this.chapterTitle,
    required this.source,
    required this.textStyle,
    required this.paragraphSpacing,
    this.titleFontFamily = appFontFamily,
  });

  final ReaderPage? page;
  final ReaderViewportLayout layout;
  final String chapterTitle;
  final SourceId source;
  final TextStyle textStyle;
  final double paragraphSpacing;
  final String titleFontFamily;

  @override
  Widget build(BuildContext context) {
    // An odd chapter ends with a blank right-hand leaf, never duplicated text.
    if (page == null) return const SizedBox.expand();
    if (page!.cssPage != null) {
      return Semantics(
        label:
            page!.cssPage!.semanticText.isEmpty
                ? '插图'
                : page!.cssPage!.semanticText,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ReaderRasterImage(
              image: EpubCssImageProvider(page!.cssPage!),
              errorChild: Center(
                child: Text('页面加载失败，请重新打开本章', style: textStyle),
              ),
            ),
            if (chapterTitle.isNotEmpty &&
                layout.headerHeight > 0 &&
                !page!.cssPage!.fixedLayout)
              Positioned(
                left: layout.insets.left,
                right: layout.insets.right,
                top: layout.insets.top,
                child: Text(
                  chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle.copyWith(
                    fontFamily: titleFontFamily,
                    fontSize: 12,
                    color: textStyle.color?.withValues(alpha: .6),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (page!.artworkText != null) {
      return Semantics(
        label: page!.artworkText,
        child: ColoredBox(
          color: Colors.white,
          child: ReaderRasterImage(
            image: CachedImageProvider(page!.content, source: source),
            errorChild: Center(child: Text('特殊页面加载失败', style: textStyle)),
          ),
        ),
      );
    }
    final content = page!.content;
    final paragraphs = (content.endsWith('\n')
            ? content.substring(0, content.length - 1)
            : content)
        .split('\n');
    final titleColor = textStyle.color?.withValues(
      alpha: layout.isSpread ? 0.60 : 0.30,
    );
    return Padding(
      padding: layout.insets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (layout.isSpread)
            SizedBox(
              height: layout.headerHeight,
              child: Text(
                chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: layout.textScaler,
                style: textStyle.copyWith(
                  fontFamily: titleFontFamily,
                  fontFamilyFallback: const [appFontFamily],
                  fontSize: 12,
                  height: 1.2,
                  color: titleColor,
                ),
              ),
            ),
          SizedBox(
            height: layout.contentHeight,
            width: layout.contentWidth,
            child:
                page!.isImage
                    ? ReaderRasterImage(
                      image: CachedImageProvider(content, source: source),
                      errorChild: Center(
                        child: Text(
                          '图片加载失败',
                          style: textStyle.copyWith(fontSize: 14),
                        ),
                      ),
                    )
                    : page!.fragments != null
                    ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final fragment in page!.fragments!)
                          ReaderStyledParagraph(
                            fragment: fragment,
                            style: textStyle,
                            textScaler: layout.textScaler,
                          ),
                      ],
                    )
                    : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < paragraphs.length; i++) ...[
                          RichText(
                            text: TextSpan(
                              text: paragraphs[i],
                              style: textStyle,
                            ),
                            textDirection: TextDirection.ltr,
                            textScaler: layout.textScaler,
                            strutStyle: StrutStyle.fromTextStyle(textStyle),
                          ),
                          if (i + 1 < paragraphs.length)
                            SizedBox(height: paragraphSpacing),
                        ],
                      ],
                    ),
          ),
        ],
      ),
    );
  }
}
