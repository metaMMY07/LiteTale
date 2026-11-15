import 'package:wild/models/reader_document.dart';

typedef ReaderPlainPart = ({int offset, String text, bool image, bool mixed});
final _documents = Expando<String>('reader mark text');
const _imageMarker = '<!--image-->';
const _anchorGap = r'[\s\u00a0\u3000]*';
final _anchorWhitespace = RegExp(r'[\s\u00a0\u3000]+');

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

/// Resolve an EPUB position between its paginated DOM and its plain transcript.
/// The two layouts can insert different whitespace around the same characters.
int? matchEpubTextOffset(String source, int offset, String target) {
  if (source == target) return offset.clamp(0, target.length);
  if (source.isEmpty || target.isEmpty) return null;

  final center = offset.clamp(0, source.length - 1);
  final priorLine = center == 0 ? -1 : source.lastIndexOf('\n', center - 1);
  final priorImage = source.lastIndexOf(_imageMarker, center);
  final start = (center - 18).clamp(priorLine + 1, center);
  final prefixStart =
      priorImage < start
          ? start
          : (priorImage + _imageMarker.length).clamp(start, center);
  var end = (center + 24).clamp(center, source.length);
  final nextImage = source.indexOf(_imageMarker, center);
  if (nextImage >= 0 && nextImage < end) end = nextImage;

  String pattern(String text) => text
      .replaceAll(_anchorWhitespace, '')
      .runes
      .map((rune) => RegExp.escape(String.fromCharCode(rune)))
      .join(_anchorGap);

  final prefix = pattern(source.substring(prefixStart, center));
  final suffix = pattern(source.substring(center, end));
  if (suffix.isEmpty) return null;
  final gap = prefix.isEmpty ? '' : _anchorGap;
  final estimate = (center * target.length / source.length).round();
  final matches = RegExp('($prefix$gap)$suffix').allMatches(target);
  int? best;
  for (final match in matches) {
    final at = match.start + match[1]!.length;
    if (best == null || (at - estimate).abs() < (best - estimate).abs()) {
      best = at;
    }
  }
  return best;
}
