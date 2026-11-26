import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wild/models/reader_mark.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/widgets/reader_mark_selection.dart';
import 'package:wild/widgets/reader_raster_readiness.dart';
import 'package:wild/widgets/reader_styled_paragraph.dart';

/// Rasterized EPUB retains the original CSS layout. Ask the offline browser
/// for glyph geometry only for marked pages or after a long press.
class ReaderCssMarks extends StatefulWidget {
  const ReaderCssMarks({
    super.key,
    required this.page,
    required this.selection,
    required this.location,
    required this.group,
  });
  final ReaderCssPage page;
  final ReaderMarkSelection selection;
  final ReaderMarkLocation location;
  final int group;

  @override
  State<ReaderCssMarks> createState() => _ReaderCssMarksState();
}

class _ReaderCssMarksState extends State<ReaderCssMarks> {
  List<ReaderCssMarkGlyph>? _glyphs;
  Future<void>? _pending;
  bool _failed = false;
  int _generation = 0;
  ReaderRasterReadiness? _readiness;

  @override
  void initState() {
    super.initState();
    widget.selection.store.addListener(_warm);
    widget.selection.registerGeometryLoader(this, _loadAt);
    _warm();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final readiness = ReaderRasterScope.maybeOf(context);
    if (readiness == _readiness) return;
    _readiness?.complete(this);
    _readiness = readiness;
    if (_pending != null) _readiness?.waitFor(this);
  }

  @override
  void didUpdateWidget(ReaderCssMarks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection.store, widget.selection.store)) {
      oldWidget.selection.store.removeListener(_warm);
      widget.selection.store.addListener(_warm);
    }
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection.unregisterGeometryLoader(this);
      widget.selection.registerGeometryLoader(this, _loadAt);
    }
    if (oldWidget.page.key != widget.page.key ||
        oldWidget.page.index != widget.page.index ||
        !identical(oldWidget.selection, widget.selection)) {
      _generation++;
      _readiness?.complete(this);
      _glyphs = null;
      _pending = null;
      _failed = false;
      _warm();
    }
  }

  @override
  void dispose() {
    widget.selection.store.removeListener(_warm);
    widget.selection.unregisterGeometryLoader(this);
    _readiness?.complete(this);
    super.dispose();
  }

  void _warm() {
    if (!_failed &&
        _glyphs == null &&
        widget.selection.hasHighlight(widget.location, widget.page.domEnd)) {
      _load();
    }
  }

  Future<void> _load() {
    final read = widget.page.readMarkGlyphs;
    if (read == null || _glyphs != null) return Future.value();
    _readiness?.waitFor(this);
    final generation = _generation;
    return _pending ??= Future.sync(read)
        .then(
          (glyphs) {
            if (mounted && generation == _generation) {
              setState(() => _glyphs = glyphs);
            }
          },
          onError: (Object _) {
            if (mounted && generation == _generation) _failed = true;
          },
        )
        .whenComplete(() {
          if (generation == _generation) {
            _pending = null;
            _readiness?.complete(this);
          }
        });
  }

  Future<bool> _loadAt(Offset global, Object group) async {
    if (!mounted || widget.group != group) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.hasSize ||
        !(Offset.zero & box.size).contains(box.globalToLocal(global))) {
      return false;
    }
    final generation = _generation,
        selection = widget.selection,
        intent = selection.intent;
    await _load();
    if (!mounted ||
        generation != _generation ||
        intent != selection.intent ||
        _glyphs == null) {
      return false;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation || intent != selection.intent) {
      return false;
    }
    return selection.beginAt(global, group);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.page.markText;
    final start = widget.page.domStart, end = widget.page.domEnd;
    if (text == null ||
        start >= text.length ||
        end <= start ||
        widget.page.readMarkGlyphs == null) {
      return const SizedBox.shrink();
    }
    final glyphs = _glyphs;
    if (glyphs == null) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart:
            (details) => _loadAt(details.globalPosition, widget.group),
        child: const SizedBox.expand(),
      );
    }
    if (glyphs.isEmpty) return const SizedBox.shrink();
    return ReaderMarkedRegion(
      selection: widget.selection,
      location: widget.location,
      group: widget.group,
      text: text.substring(start, math.min(end, text.length)),
      child: _GlyphBox(glyphs, start),
    );
  }
}

class _GlyphBox extends LeafRenderObjectWidget {
  const _GlyphBox(this.glyphs, this.base);
  final List<ReaderCssMarkGlyph> glyphs;
  final int base;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _GlyphRenderBox(glyphs, base);
  @override
  void updateRenderObject(BuildContext context, covariant _GlyphRenderBox box) {
    box.glyphs = glyphs;
    box.base = base;
  }
}

class _GlyphRenderBox extends RenderBox implements ReaderStyledTextGeometry {
  _GlyphRenderBox(this.glyphs, this.base);
  List<ReaderCssMarkGlyph> glyphs;
  int base;

  @override
  void performLayout() => size = constraints.biggest;

  Rect _rect(Rect r) => Rect.fromLTRB(
    r.left * size.width,
    r.top * size.height,
    r.right * size.width,
    r.bottom * size.height,
  );

  @override
  TextPosition textPosition(Offset point) {
    ReaderCssMarkGlyph? nearest;
    Rect? box;
    var distance = double.infinity;
    for (final glyph in glyphs) {
      final rect = _rect(glyph.rect);
      final p = Offset(
        point.dx.clamp(rect.left, rect.right),
        point.dy.clamp(rect.top, rect.bottom),
      );
      final d = (point - p).distanceSquared;
      if (d < distance) {
        nearest = glyph;
        box = rect;
        distance = d;
        if (d == 0) break;
      }
    }
    if (nearest == null || box == null) return const TextPosition(offset: 0);
    return TextPosition(
      offset: (point.dx > box.center.dx ? nearest.end : nearest.start) - base,
      affinity:
          point.dx > box.center.dx
              ? TextAffinity.upstream
              : TextAffinity.downstream,
    );
  }

  @override
  TextRange wordBoundary(TextPosition position) {
    final offset =
        position.offset +
        base -
        (position.affinity == TextAffinity.upstream ? 1 : 0);
    for (final glyph in glyphs) {
      if (offset >= glyph.start && offset < glyph.end) {
        return TextRange(
          start: glyph.wordStart - base,
          end: glyph.wordEnd - base,
        );
      }
    }
    return TextRange.empty;
  }

  @override
  List<Rect> textRects(TextSelection selection) {
    final result = <Rect>[];
    for (final glyph in glyphs) {
      if (glyph.start >= selection.end + base ||
          glyph.end <= selection.start + base) {
        continue;
      }
      final rect = _rect(glyph.rect);
      final last = result.lastOrNull;
      if (last != null &&
          (last.top - rect.top).abs() < 1.3 &&
          (last.bottom - rect.bottom).abs() < 1.3 &&
          last.left - 1.3 <= rect.right &&
          rect.left <= last.right + 1.3) {
        result[result.length - 1] = last.expandToInclude(rect);
      } else {
        result.add(rect);
      }
    }
    return result;
  }
}
