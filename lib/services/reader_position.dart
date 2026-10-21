import 'package:wild/models/reader_page.dart';

/// Build once per pagination, then query text/image offsets in constant time.
class ReaderPageOffsets {
  ReaderPageOffsets(List<ReaderPage> pages) : pages = List.unmodifiable(pages) {
    for (final page in pages) {
      _characters.add(
        page.textEnd ??
            (_characters.last + (page.isImage ? 0 : page.content.length)),
      );
      _images.add(_images.last + (page.isImage ? 1 : 0));
    }
  }
  final List<ReaderPage> pages;
  final _characters = <int>[0];
  final _images = <int>[0];
  ReaderPosition at(int index) => ReaderPosition(
    pages[index].textStart ?? _characters[index],
    _images[index],
    pages[index].isImage,
    epubOffset: pages[index].cssPage?.domStart,
  );
  int charactersThrough(int index) => _characters[index + 1];
}

/// Preserve a content anchor until the reader actually turns a page. Using
/// the newly paginated page's beginning as the next anchor drifts backwards
/// each time the device rotates. Image positions also need their own ordinal.
class ReaderPosition {
  const ReaderPosition(
    this.textOffset,
    this.precedingImages,
    this.onImage, {
    this.epubOffset,
  });
  final int textOffset;
  final int precedingImages;
  final bool onImage;
  final int? epubOffset;

  factory ReaderPosition.at(List<ReaderPage> pages, int index) {
    var characters = 0;
    var images = 0;
    for (var i = 0; i < index; i++) {
      if (pages[i].isImage) {
        images++;
      } else {
        characters += pages[i].content.length;
      }
    }
    return ReaderPosition(
      pages[index].textStart ?? characters,
      images,
      pages[index].isImage,
      epubOffset: pages[index].cssPage?.domStart,
    );
  }

  int pageIn(List<ReaderPage> pages) {
    if (epubOffset != null && pages.any((p) => p.cssPage != null)) {
      var selected = 0;
      for (var i = 0; i < pages.length; i++) {
        final p = pages[i].cssPage;
        if (p != null && p.domStart <= epubOffset!) selected = i;
      }
      return selected;
    }
    var characters = 0;
    var images = 0;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (page.isImage) {
        if (onImage && images == precedingImages) return i;
        images++;
      } else {
        characters = page.textEnd ?? (characters + page.content.length);
        if (!onImage && characters > textOffset && images >= precedingImages) {
          return i;
        }
      }
    }
    return pages.length - 1;
  }
}
