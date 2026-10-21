import 'dart:convert';

/// Native-reader styles, independent of Flutter so EPUB conversion can run in
/// an isolate. Fonts and paper colors remain controlled by reader settings.
class ReaderLength {
  const ReaderLength({this.em = 0, this.px = 0, this.fraction = 0});
  final double em, px, fraction;
  double resolve(double fontSize, {double referenceWidth = 0}) =>
      em * fontSize + px + fraction * referenceWidth;
  Map<String, Object> toJson() => {'em': em, 'px': px, 'fraction': fraction};
  factory ReaderLength.fromJson(Object? value) {
    if (value == null) return const ReaderLength();
    final map = value as Map;
    return ReaderLength(
      em: _number(map['em'], 0, -16, 16),
      px: _number(map['px'], 0, -256, 256),
      fraction: _number(map['fraction'], 0, -.9, .9),
    );
  }
}

class ReaderInlineStyle {
  const ReaderInlineStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.scale = 1,
    this.letterSpacing = const ReaderLength(),
    this.color,
    this.darkColor,
    this.background,
    this.darkBackground,
  });
  final bool bold, italic, underline, strike;
  final double scale;
  final ReaderLength letterSpacing;
  final int? color, darkColor, background, darkBackground;
  ReaderInlineStyle withPalette(ReaderInlineStyle dark) => ReaderInlineStyle(
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    scale: scale,
    letterSpacing: letterSpacing,
    color: color,
    darkColor: dark.color,
    background: background,
    darkBackground: dark.background,
  );
  Map<String, Object?> toJson() => {
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'strike': strike,
    'scale': scale,
    'letterSpacing': letterSpacing.toJson(),
    'color': color,
    'darkColor': darkColor,
    'background': background,
    'darkBackground': darkBackground,
  };
  factory ReaderInlineStyle.fromJson(Object? value) {
    final map = value as Map;
    return ReaderInlineStyle(
      bold: map['bold'] == true,
      italic: map['italic'] == true,
      underline: map['underline'] == true,
      strike: map['strike'] == true,
      scale: _number(map['scale'], 1, .5, 3),
      letterSpacing: ReaderLength.fromJson(map['letterSpacing']),
      color: _color(map['color']),
      darkColor: _color(map['darkColor']),
      background: _color(map['background']),
      darkBackground: _color(map['darkBackground']),
    );
  }
}

class ReaderRun {
  const ReaderRun(this.text, {this.style = const ReaderInlineStyle()});
  final String text;
  final ReaderInlineStyle style;
  Map<String, Object> toJson() => {'text': text, 'style': style.toJson()};
  factory ReaderRun.fromJson(Object? value) {
    final map = value as Map;
    if (map['text'] is! String) {
      throw const FormatException('invalid reader run');
    }
    return ReaderRun(
      map['text'] as String,
      style: ReaderInlineStyle.fromJson(map['style']),
    );
  }
}

class ReaderBlockStyle {
  const ReaderBlockStyle({
    this.align = 'start',
    this.indent = const ReaderLength(),
    this.marginTop = const ReaderLength(),
    this.marginBottom = const ReaderLength(),
    this.marginLeft = const ReaderLength(),
    this.marginRight = const ReaderLength(),
    this.lineHeight,
    this.breakBefore = false,
    this.breakAfter = false,
    this.keepTogether = false,
    this.hasMargins = false,
    this.box = const ReaderBoxStyle(),
  });
  final String align;
  final ReaderLength indent, marginTop, marginBottom, marginLeft, marginRight;
  final double? lineHeight;
  final bool breakBefore, breakAfter, keepTogether;
  final bool hasMargins;
  final ReaderBoxStyle box;
  Map<String, Object?> toJson() => {
    'align': align,
    'indent': indent.toJson(),
    'marginTop': marginTop.toJson(),
    'marginBottom': marginBottom.toJson(),
    'marginLeft': marginLeft.toJson(),
    'marginRight': marginRight.toJson(),
    'lineHeight': lineHeight,
    'breakBefore': breakBefore,
    'breakAfter': breakAfter,
    'keepTogether': keepTogether,
    'hasMargins': hasMargins,
    'box': box.toJson(),
  };
  factory ReaderBlockStyle.fromJson(Object? value) {
    final map = value as Map;
    final align = map['align'] ?? 'start';
    if (!const [
      'start',
      'left',
      'center',
      'right',
      'end',
      'justify',
    ].contains(align)) {
      throw const FormatException('invalid paragraph alignment');
    }
    return ReaderBlockStyle(
      align: align as String,
      indent: ReaderLength.fromJson(map['indent']),
      marginTop: ReaderLength.fromJson(map['marginTop']),
      marginBottom: ReaderLength.fromJson(map['marginBottom']),
      marginLeft: ReaderLength.fromJson(map['marginLeft']),
      marginRight: ReaderLength.fromJson(map['marginRight']),
      lineHeight:
          map['lineHeight'] == null
              ? null
              : _number(map['lineHeight'], 1.5, .8, 4),
      breakBefore: map['breakBefore'] == true,
      breakAfter: map['breakAfter'] == true,
      keepTogether: map['keepTogether'] == true,
      hasMargins: map['hasMargins'] == true,
      box: ReaderBoxStyle.fromJson(map['box']),
    );
  }
}

class ReaderBlock {
  ReaderBlock({
    List<ReaderRun> runs = const [],
    this.style = const ReaderBlockStyle(),
    this.imageUrl,
    this.artworkUrl,
    List<ReaderTableCell> cells = const [],
  }) : runs = List.unmodifiable(runs),
       cells = List.unmodifiable(cells);
  final List<ReaderRun> runs;
  final ReaderBlockStyle style;
  final String? imageUrl;

  /// [text] remains original text, retaining positions and accessible content
  /// while this facsimile paints the book's designed page.
  final String? artworkUrl;
  final List<ReaderTableCell> cells;
  List<ReaderRun> get flatRuns =>
      cells.isEmpty
          ? runs
          : [
            for (var i = 0; i < cells.length; i++) ...[
              if (i > 0) const ReaderRun('\t'),
              ...cells[i].runs,
            ],
          ];
  String get text =>
      cells.isEmpty
          ? runs.map((run) => run.text).join()
          : cells.map((cell) => cell.text).join('\t');
  String get plainText =>
      imageUrl == null ? text : '<!--image-->$imageUrl<!--image-->';

  ReaderBlock slice(int start, int end) {
    if (imageUrl != null) return this;
    if (artworkUrl != null && start == 0 && end == text.length) return this;
    if (cells.isNotEmpty) {
      if (start == 0 && end == text.length) return this;
      return ReaderBlock(runs: flatRuns, style: style).slice(start, end);
    }
    final sliced = <ReaderRun>[];
    var offset = 0;
    for (final run in runs) {
      final from = (start - offset).clamp(0, run.text.length);
      final to = (end - offset).clamp(0, run.text.length);
      if (to > from) {
        sliced.add(ReaderRun(run.text.substring(from, to), style: run.style));
      }
      offset += run.text.length;
      if (offset >= end) break;
    }
    return ReaderBlock(runs: sliced, style: style);
  }

  Map<String, Object?> toJson() => {
    'runs': runs.map((run) => run.toJson()).toList(),
    'style': style.toJson(),
    'image': imageUrl,
    'artwork': artworkUrl,
    'cells': cells.map((cell) => cell.toJson()).toList(),
  };
  factory ReaderBlock.fromJson(Object? value) {
    final map = value as Map;
    final runs = map['runs'] as List;
    final cells = map['cells'] as List? ?? const [];
    if (cells.length > 24) {
      throw const FormatException('too many table columns');
    }
    if (runs.length > 100000) {
      throw const FormatException('too many reader runs');
    }
    final image = map['image'];
    final artwork = map['artwork'];
    for (final resource in [image, artwork]) {
      if (resource != null &&
          (resource is! String ||
              !RegExp(
                r'^epub-asset:[a-f0-9]{64}/[a-f0-9]{64}\.(?:png|jpg|gif|webp|bmp|avif)$',
              ).hasMatch(resource))) {
        throw const FormatException('invalid reader image');
      }
    }
    if (image != null && artwork != null) {
      throw const FormatException('ambiguous reader image');
    }
    return ReaderBlock(
      runs: runs.map(ReaderRun.fromJson).toList(),
      imageUrl: image as String?,
      artworkUrl: artwork as String?,
      style: ReaderBlockStyle.fromJson(map['style']),
      cells: cells.map(ReaderTableCell.fromJson).toList(),
    );
  }
}

class ReaderDocument {
  ReaderDocument(List<ReaderBlock> blocks) : blocks = List.unmodifiable(blocks);
  final List<ReaderBlock> blocks;
  String get content => blocks.map((block) => block.plainText).join('\n');
  late final String cacheIdentity = jsonEncode(toJson());
  Map<String, Object> toJson() => {
    'schema': 1,
    'blocks': blocks.map((block) => block.toJson()).toList(),
  };
  factory ReaderDocument.fromJson(Object? value) {
    final map = value as Map;
    final blocks = map['blocks'] as List;
    if (map['schema'] != 1 || blocks.length > 100000) {
      throw const FormatException('invalid reader document');
    }
    return ReaderDocument(blocks.map(ReaderBlock.fromJson).toList());
  }

  /// Slice by the same UTF-16 offsets as [content], retaining run boundaries.
  ReaderDocument slice(int start, int end) {
    final result = <ReaderBlock>[];
    var offset = 0;
    for (final block in blocks) {
      final length = block.plainText.length;
      final from = (start - offset).clamp(0, length);
      final to = (end - offset).clamp(0, length);
      if (to > from) result.add(block.slice(from, to));
      offset += length + 1;
      if (offset >= end) break;
    }
    return ReaderDocument(result);
  }
}

class ReaderBorderStyle {
  const ReaderBorderStyle({
    this.width = const ReaderLength(),
    this.color,
    this.darkColor,
  });
  final ReaderLength width;
  final int? color, darkColor;
  Map<String, Object?> toJson() => {
    'width': width.toJson(),
    'color': color,
    'darkColor': darkColor,
  };
  factory ReaderBorderStyle.fromJson(Object? value) {
    if (value == null) return const ReaderBorderStyle();
    final map = value as Map;
    return ReaderBorderStyle(
      width: ReaderLength.fromJson(map['width']),
      color: _color(map['color']),
      darkColor: _color(map['darkColor']),
    );
  }
  ReaderBorderStyle withPalette(ReaderBorderStyle dark) =>
      ReaderBorderStyle(width: width, color: color, darkColor: dark.color);
}

class ReaderBoxStyle {
  const ReaderBoxStyle({
    this.paddingTop = const ReaderLength(),
    this.paddingBottom = const ReaderLength(),
    this.paddingLeft = const ReaderLength(),
    this.paddingRight = const ReaderLength(),
    this.top = const ReaderBorderStyle(),
    this.bottom = const ReaderBorderStyle(),
    this.left = const ReaderBorderStyle(),
    this.right = const ReaderBorderStyle(),
    this.radius = const ReaderLength(),
    this.background,
    this.darkBackground,
  });
  final ReaderLength paddingTop,
      paddingBottom,
      paddingLeft,
      paddingRight,
      radius;
  final ReaderBorderStyle top, bottom, left, right;
  final int? background, darkBackground;
  Map<String, Object?> toJson() => {
    'paddingTop': paddingTop.toJson(),
    'paddingBottom': paddingBottom.toJson(),
    'paddingLeft': paddingLeft.toJson(),
    'paddingRight': paddingRight.toJson(),
    'top': top.toJson(),
    'bottom': bottom.toJson(),
    'left': left.toJson(),
    'right': right.toJson(),
    'radius': radius.toJson(),
    'background': background,
    'darkBackground': darkBackground,
  };
  factory ReaderBoxStyle.fromJson(Object? value) {
    if (value == null) return const ReaderBoxStyle();
    final m = value as Map;
    return ReaderBoxStyle(
      paddingTop: ReaderLength.fromJson(m['paddingTop']),
      paddingBottom: ReaderLength.fromJson(m['paddingBottom']),
      paddingLeft: ReaderLength.fromJson(m['paddingLeft']),
      paddingRight: ReaderLength.fromJson(m['paddingRight']),
      top: ReaderBorderStyle.fromJson(m['top']),
      bottom: ReaderBorderStyle.fromJson(m['bottom']),
      left: ReaderBorderStyle.fromJson(m['left']),
      right: ReaderBorderStyle.fromJson(m['right']),
      radius: ReaderLength.fromJson(m['radius']),
      background: _color(m['background']),
      darkBackground: _color(m['darkBackground']),
    );
  }
  ReaderBoxStyle withPalette(ReaderBoxStyle dark) => ReaderBoxStyle(
    paddingTop: paddingTop,
    paddingBottom: paddingBottom,
    paddingLeft: paddingLeft,
    paddingRight: paddingRight,
    top: top.withPalette(dark.top),
    bottom: bottom.withPalette(dark.bottom),
    left: left.withPalette(dark.left),
    right: right.withPalette(dark.right),
    radius: radius,
    background: background,
    darkBackground: dark.background,
  );
}

class ReaderTableCell {
  ReaderTableCell({
    required List<ReaderRun> runs,
    this.style = const ReaderBlockStyle(),
  }) : runs = List.unmodifiable(runs);
  final List<ReaderRun> runs;
  final ReaderBlockStyle style;
  String get text => runs.map((run) => run.text).join();
  Map<String, Object?> toJson() => {
    'runs': runs.map((run) => run.toJson()).toList(),
    'style': style.toJson(),
  };
  factory ReaderTableCell.fromJson(Object? value) {
    final map = value as Map;
    final runs = map['runs'] as List;
    if (runs.length > 10000) throw const FormatException('too many cell runs');
    return ReaderTableCell(
      runs: runs.map(ReaderRun.fromJson).toList(),
      style: ReaderBlockStyle.fromJson(map['style']),
    );
  }
}

int? _color(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0 || value > 0xffffffff) {
    throw const FormatException('invalid reader color');
  }
  return value;
}

double _number(Object? value, double fallback, double minimum, double maximum) {
  if (value == null) return fallback;
  if (value is! num || !value.isFinite || value < minimum || value > maximum) {
    throw const FormatException('invalid reader style value');
  }
  return value.toDouble();
}
