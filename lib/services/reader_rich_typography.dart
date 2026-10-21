import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/models/reader_document.dart';

TextAlign readerBlockAlignment(String value) => switch (value) {
  'center' => TextAlign.center,
  'right' || 'end' => TextAlign.right,
  'justify' => TextAlign.justify,
  _ => TextAlign.left,
};

/// Both pagination and painting use this exact painter, including the first
/// line's placeholder. The placeholder is visual only, never a source character.
class ReaderParagraphLayout {
  ReaderParagraphLayout({
    required ReaderFragment fragment,
    required TextStyle baseStyle,
    required double width,
    required TextScaler textScaler,
  }) : _fragment = fragment,
       _baseStyle = baseStyle {
    final style = baseStyle.copyWith(height: fragment.block.style.lineHeight);
    final fontSize = style.fontSize ?? 16;
    left = fragment.block.style.marginLeft
        .resolve(fontSize, referenceWidth: width)
        .clamp(0, width * .35);
    final right = fragment.block.style.marginRight
        .resolve(fontSize, referenceWidth: width)
        .clamp(0, width * .35);
    _boxWidth = math.max(1.0, width - left - right);
    final box = fragment.block.style.box;
    double padding(ReaderLength length) => length
        .resolve(fontSize, referenceWidth: _boxWidth)
        .clamp(0, math.min(fontSize * 4, _boxWidth * .25));
    double border(ReaderBorderStyle side) =>
        side.width.resolve(fontSize).clamp(0, 8);
    _textLeft = padding(box.paddingLeft) + border(box.left);
    textTop = fragment.first ? padding(box.paddingTop) + border(box.top) : 0;
    _bottom =
        fragment.last ? padding(box.paddingBottom) + border(box.bottom) : 0;
    final textWidth = math.max(
      1.0,
      _boxWidth - _textLeft - padding(box.paddingRight) - border(box.right),
    );
    final indent =
        fragment.first
            ? fragment.block.style.indent
                .resolve(fontSize)
                .clamp(0.0, textWidth * .65)
            : 0.0;
    prefixLength = indent > 0 ? 1 : 0;
    final sliced = fragment.block.slice(fragment.start, fragment.end);
    final background = _palette(box.background, box.darkBackground);
    final defaultInk = _readable(style.color ?? Colors.black, background);
    final span = TextSpan(
      style: style,
      children: [
        if (indent > 0)
          const WidgetSpan(
            child: SizedBox.shrink(),
            alignment: PlaceholderAlignment.bottom,
          ),
        for (final run in sliced.flatRuns)
          TextSpan(
            text: run.text,
            style: style.copyWith(
              fontSize: fontSize * run.style.scale,
              fontWeight: run.style.bold ? FontWeight.bold : style.fontWeight,
              fontStyle: run.style.italic ? FontStyle.italic : FontStyle.normal,
              letterSpacing: run.style.letterSpacing.resolve(fontSize),
              color: _readable(
                _palette(run.style.color, run.style.darkColor) ?? defaultInk,
                _palette(run.style.background, run.style.darkBackground) ??
                    background,
              ),
              backgroundColor: _palette(
                run.style.background,
                run.style.darkBackground,
              ),
              decoration: TextDecoration.combine([
                if (run.style.underline) TextDecoration.underline,
                if (run.style.strike) TextDecoration.lineThrough,
              ]),
            ),
          ),
      ],
    );
    painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textAlign: readerBlockAlignment(fragment.block.style.align),
      textScaler: textScaler,
      strutStyle: StrutStyle.fromTextStyle(style),
    );
    if (indent > 0) {
      painter.setPlaceholderDimensions([
        PlaceholderDimensions(
          size: Size(indent, 0),
          alignment: PlaceholderAlignment.bottom,
        ),
      ]);
    }
    // Alignment needs the available paragraph width, including short final
    // lines. A loose minimum shrinks TextPainter to the longest line and makes
    // a one-line center/right paragraph appear left aligned when painted.
    painter.layout(minWidth: textWidth, maxWidth: textWidth);
    if (fragment.block.cells.isNotEmpty && !fragment.tableAsText) {
      final cellWidth = textWidth / fragment.block.cells.length;
      for (final cell in fragment.block.cells) {
        final cellBlock = ReaderBlock(runs: cell.runs, style: cell.style);
        _cells.add(
          ReaderParagraphLayout(
            fragment: ReaderFragment(
              block: cellBlock,
              start: 0,
              end: cellBlock.text.length,
              first: true,
              last: true,
            ),
            baseStyle: style.copyWith(color: defaultInk),
            width: cellWidth,
            textScaler: textScaler,
          ),
        );
      }
      _cellWidth = cellWidth;
    }
  }

  final ReaderFragment _fragment;
  final TextStyle _baseStyle;
  final _cells = <ReaderParagraphLayout>[];
  double _cellWidth = 0;
  late final double _boxWidth, _textLeft, _bottom;
  late final double textTop;
  late final TextPainter painter;
  late final double left;
  late final int prefixLength;
  bool get isTable => _cells.isNotEmpty;
  double get height =>
      textTop +
      _bottom +
      (_cells.isEmpty
          ? painter.height
          : _cells.map((c) => c.height).reduce(math.max));
  Color? _palette(int? light, int? dark) {
    final isDark = (_baseStyle.color ?? Colors.black).computeLuminance() > .5;
    final value = isDark ? dark ?? light : light;
    return value == null ? null : Color(value);
  }

  Color _readable(Color ink, Color? background) {
    if (background == null || background.a < .65) return ink;
    final a = ink.computeLuminance(), b = background.computeLuminance();
    if ((math.max(a, b) + .05) / (math.min(a, b) + .05) >= 3) return ink;
    return b > .4 ? Colors.black : Colors.white;
  }

  void paint(Canvas canvas, Offset offset, {double? fillHeight}) {
    final origin = offset + Offset(left, 0);
    final h = fillHeight ?? height;
    final box = _fragment.block.style.box;
    final rect = Rect.fromLTWH(origin.dx, origin.dy, _boxWidth, h);
    final radius = Radius.circular(
      box.radius
          .resolve(_baseStyle.fontSize ?? 16)
          .clamp(0, math.min(_boxWidth, h) / 2),
    );
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: _fragment.first ? radius : Radius.zero,
      topRight: _fragment.first ? radius : Radius.zero,
      bottomLeft: _fragment.last ? radius : Radius.zero,
      bottomRight: _fragment.last ? radius : Radius.zero,
    );
    final bg = _palette(box.background, box.darkBackground);
    if (bg != null) canvas.drawRRect(rrect, Paint()..color = bg);
    final font = _baseStyle.fontSize ?? 16;
    final borders = [box.top, box.right, box.bottom, box.left];
    final widths = [
      for (final b in borders) b.width.resolve(font).clamp(0.0, 8.0),
    ];
    if (!_fragment.first) widths[0] = 0;
    if (!_fragment.last) widths[2] = 0;
    final colors = [
      for (final b in borders)
        _palette(b.color, b.darkColor) ?? _baseStyle.color ?? Colors.black,
    ];
    if (widths[0] > 0 &&
        widths.every((w) => w == widths[0]) &&
        colors.every((c) => c == colors[0])) {
      canvas.drawRRect(
        rrect.deflate(widths[0] / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = widths[0]
          ..color = colors[0],
      );
    } else {
      final starts = [
        rect.topLeft,
        rect.topRight,
        rect.bottomRight,
        rect.bottomLeft,
      ];
      final ends = [
        rect.topRight,
        rect.bottomRight,
        rect.bottomLeft,
        rect.topLeft,
      ];
      for (var i = 0; i < 4; i++) {
        if (widths[i] > 0) {
          canvas.drawLine(
            starts[i],
            ends[i],
            Paint()
              ..color = colors[i]
              ..strokeWidth = widths[i],
          );
        }
      }
    }
    final textOrigin = origin + Offset(_textLeft, textTop);
    if (_cells.isEmpty) {
      painter.paint(canvas, textOrigin);
    } else {
      for (var i = 0; i < _cells.length; i++) {
        _cells[i].paint(
          canvas,
          textOrigin + Offset(_cellWidth * i, 0),
          fillHeight: h - textTop - _bottom,
        );
      }
    }
  }

  void dispose() {
    painter.dispose();
    for (final cell in _cells) {
      cell.dispose();
    }
  }
}
