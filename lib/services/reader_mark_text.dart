import 'package:wild/models/reader_document.dart';

typedef ReaderPlainPart = ({int offset, String text, bool image, bool mixed});
final _documents = Expando<String>('reader mark text');

/// Image markers do not become selectable text, but retain their position so
/// both layouts can locate the surrounding content and bookmark artwork.
Iterable<ReaderPlainPart> readerPlainParts(String content) sync* {
  final image = RegExp(r'<!--image-->([^<]+)<!--image-->');
  var lineStart = 0;
  for (final line in content.split('\n')) {
    var offset = 0;
    final matches = image.allMatches(line);
    for (final match in matches) {
      if (match.start > offset) {
        yield (
          offset: lineStart + offset,
          text: line.substring(offset, match.start),
          image: false,
          mixed: true,
        );
      }
      yield (
        offset: lineStart + match.start,
        text: match.group(1)!.trim(),
        image: true,
        mixed: true,
      );
      offset = match.end;
    }
    if (offset < line.length) {
      yield (
        offset: lineStart + offset,
        text: line.substring(offset),
        image: false,
        mixed: offset > 0,
      );
    }
    lineStart += line.length + 1;
  }
}

/// The same chapter-wide coordinates as the styled paginator.
String readerMarkText(String content, ReaderDocument? document) {
  if (document == null) return content;
  final cached = _documents[document];
  if (cached != null) return cached;
  final text = StringBuffer();
  for (final block in document.blocks) {
    if (block.imageUrl != null || block.artworkUrl != null) {
      text.writeln(block.plainText);
    } else if (block.text.isNotEmpty) {
      text.writeln(block.text);
    }
  }
  return _documents[document] = text.toString();
}
