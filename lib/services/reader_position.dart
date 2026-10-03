import 'package:wild/models/reader_page.dart';

/// Preserve a content anchor until the reader actually turns a page. Using
/// the newly paginated page's beginning as the next anchor drifts backwards
/// each time the device rotates. Image positions also need their own ordinal.
class ReaderPosition {
  const ReaderPosition(this.textOffset, this.precedingImages, this.onImage);
  final int textOffset;
  final int precedingImages;
  final bool onImage;

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
    return ReaderPosition(characters, images, pages[index].isImage);
  }

  int pageIn(List<ReaderPage> pages) {
    var characters = 0;
    var images = 0;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (page.isImage) {
        if (onImage && images == precedingImages) return i;
        images++;
      } else {
        characters += page.content.length;
        if (!onImage && characters > textOffset && images >= precedingImages) {
          return i;
        }
      }
    }
    return pages.length - 1;
  }
}
