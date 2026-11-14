typedef ReaderMarkChapter = ({String aid, String cid});
typedef ReaderMarkChapterText = ({String text, bool encoded});

enum ReaderMarkAxis { text, epubDom, page }

enum ReaderMarkColor {
  yellow('黄色', 0xffedc83e),
  green('绿色', 0xff86c465),
  blue('蓝色', 0xff79aaf1),
  pink('粉色', 0xffee86a7),
  purple('紫色', 0xffb29aeb);

  const ReaderMarkColor(this.label, this.argb);
  final String label;
  final int argb;
}

/// Offsets are UTF-16 positions in the chapter, independent of page layout.
/// Rasterized EPUB pages use their own DOM offset space.
class ReaderMarkLocation {
  const ReaderMarkLocation(
    this.chapter,
    this.title,
    this.axis,
    this.offset, {
    this.imageIndex,
  });

  final ReaderMarkChapter chapter;
  final String title;
  final ReaderMarkAxis axis;
  final int offset;
  final int? imageIndex;

  bool samePosition(ReaderMarkLocation other) =>
      chapter == other.chapter &&
      axis == other.axis &&
      offset == other.offset &&
      imageIndex == other.imageIndex;

  ReaderMarkLocation at(int newOffset) =>
      ReaderMarkLocation(chapter, title, axis, newOffset);

  Map<String, Object> toJson() => {
    'aid': chapter.aid,
    'cid': chapter.cid,
    'title': title,
    'axis': axis.name,
    'offset': offset,
    if (imageIndex != null) 'image': imageIndex!,
  };

  factory ReaderMarkLocation.fromJson(Map value) {
    final offset = value['offset'] as int;
    final imageIndex = value['image'] as int?;
    if (offset < 0 || (imageIndex != null && imageIndex < 0)) {
      throw const FormatException('invalid reader mark position');
    }
    return ReaderMarkLocation(
      (aid: value['aid'] as String, cid: value['cid'] as String),
      value['title'] as String,
      ReaderMarkAxis.values.byName(value['axis'] as String),
      offset,
      imageIndex: imageIndex,
    );
  }
}

class ReaderMark {
  const ReaderMark({
    required this.id,
    required this.location,
    required this.createdAt,
    this.quote = '',
    this.note = '',
    this.color,
    this.encodedQuote = false,
    this.pageNumber,
  });
  static const maxQuoteLength = 4096;
  static const maxNoteLength = 2000;

  final String id, quote, note;
  final ReaderMarkLocation location;
  final DateTime createdAt;
  final ReaderMarkColor? color;
  final bool encodedQuote;

  /// Chapter-local page at the last save in paginated mode, for display only.
  final int? pageNumber;
  bool get isBookmark => color == null;

  /// If a source edits the chapter, only relocate an unambiguous quotation.
  /// Never paint a stale character range over unrelated words.
  int? offsetIn(String text) {
    if (isBookmark) return location.offset;
    if (quote.isEmpty) return null;
    final start = location.offset;
    if (start <= text.length && text.startsWith(quote, start)) return start;
    final first = text.indexOf(quote);
    if (first < 0 || text.indexOf(quote, first + 1) >= 0) return null;
    return first;
  }

  ReaderMark withNote(String value) => ReaderMark(
    id: id,
    location: location,
    createdAt: createdAt,
    quote: quote,
    color: color,
    note: value,
    encodedQuote: encodedQuote,
    pageNumber: pageNumber,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'location': location.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (color != null) 'color': color!.name,
    if (quote.isNotEmpty) 'quote': quote,
    if (note.isNotEmpty) 'note': note,
    if (encodedQuote) 'encodedQuote': true,
    if (pageNumber != null) 'pageNumber': pageNumber!,
  };

  factory ReaderMark.fromJson(Map value) {
    final quote = value['quote'] as String? ?? '';
    final note = value['note'] as String? ?? '';
    final color = value['color'] as String?;
    final pageNumber = value['pageNumber'];
    if (quote.length > maxQuoteLength ||
        note.length > maxNoteLength ||
        (color != null && quote.trim().isEmpty)) {
      throw const FormatException('invalid reader mark text');
    }
    return ReaderMark(
      id: value['id'] as String,
      location: ReaderMarkLocation.fromJson(value['location'] as Map),
      createdAt: DateTime.fromMillisecondsSinceEpoch(value['createdAt'] as int),
      color: color == null ? null : ReaderMarkColor.values.byName(color),
      quote: quote,
      note: note,
      encodedQuote: value['encodedQuote'] == true,
      pageNumber: pageNumber is int && pageNumber > 0 ? pageNumber : null,
    );
  }
}
