import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wild/models/reader_mark.dart';
import 'package:wild/services/reader_mark_store.dart';
import 'package:wild/widgets/reader_styled_paragraph.dart';

typedef ReaderMarkTextLookup =
    ReaderMarkChapterText? Function(
      ReaderMarkChapter chapter,
      ReaderMarkAxis axis,
    );
typedef _MarkRange = ({int start, int end, ReaderMark mark});

class ReaderTextSelection {
  const ReaderTextSelection(
    this.location,
    this.end,
    this.quote,
    this.group,
    this.boxes,
    this.encoded,
  );
  final ReaderMarkLocation location;
  final int end;
  final String quote;
  final Object group;
  final List<Rect> boxes;
  final bool encoded;
}

/// Queries the actual glyph layout, so marks never change the page breaks.
class ReaderMarkSelection extends ValueNotifier<ReaderTextSelection?> {
  ReaderMarkSelection({
    required this.viewport,
    required this.book,
    required this.chapterText,
    required this.canSelect,
    this.onStart,
    ReaderMarkStore? store,
  }) : store = store ?? ReaderMarkStore.instance,
       super(null);

  final GlobalKey viewport;
  final String book;
  final ReaderMarkTextLookup chapterText;
  final bool Function(Object group) canSelect;
  final VoidCallback? onStart;
  final ReaderMarkStore store;
  final _regions = <_MarkedRegionState>{};
  final _byChapter = <(ReaderMarkChapter, ReaderMarkAxis), List<ReaderMark>>{};
  final _resolved =
      <(ReaderMarkChapter, ReaderMarkAxis), (String, List<_MarkRange>)>{};
  List<ReaderMark>? _revision;
  ReaderMarkColor lastColor = ReaderMarkColor.green;
  int _intent = 0;
  int get intent => _intent;

  Rect? get _view {
    final box = viewport.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
  }

  bool clear() {
    _intent++;
    if (value == null) return false;
    value = null;
    return true;
  }

  Iterable<_MarkedRegionState> _visible(Object group) sync* {
    final view = _view;
    if (view == null) return;
    final seen = <(ReaderMarkChapter, ReaderMarkAxis, int, int)>{};
    for (final region in _regions) {
      if (region.widget.group == group &&
          region.bounds?.overlaps(view) == true) {
        final location = region.widget.location;
        if (seen.add((
          location.chapter,
          location.axis,
          location.offset,
          region.widget.text.length,
        ))) {
          yield region;
        }
      }
    }
  }

  bool beginAt(Offset global, Object group) {
    if (!canSelect(group)) return false;
    for (final region in _visible(group)) {
      if (!region.widget.selectable ||
          region.bounds?.contains(global) != true) {
        continue;
      }
      final target = region.widget.location;
      // Reopen the entire saved range when a hold lands on its painted text.
      // A word within a multi-line highlight must still offer Remove.
      for (final saved in _ranges(target).reversed) {
        if (!region
            .globalRects(saved.start, saved.end)
            .any((rect) => rect.contains(global))) {
          continue;
        }
        final reopened = _make(target.at(saved.start), saved.end, group);
        if (reopened == null) continue;
        onStart?.call();
        value = reopened;
        return true;
      }
      final position = region.position(global);
      if (position == null) continue;
      final word = region.box?.word(position);
      if (word == null || !word.isValid || word.isCollapsed) continue;
      final start = target.offset + word.start, end = target.offset + word.end;
      if (!region
          .globalRects(start, end)
          .any((r) => r.inflate(4).contains(global))) {
        continue;
      }
      final next = _make(target.at(start), end, group);
      if (next == null) continue;
      onStart?.call();
      value = next;
      return true;
    }
    return false;
  }

  void moveHandle(Offset global, {required bool leading}) {
    final selection = value;
    if (selection == null || !canSelect(selection.group)) return;
    _MarkedRegionState? closest;
    var distance = double.infinity;
    for (final region in _visible(selection.group)) {
      if (!region.widget.selectable ||
          !_sameChapter(selection.location, region.widget.location)) {
        continue;
      }
      final rect = region.bounds!;
      final nearest = Offset(
        global.dx.clamp(rect.left, rect.right),
        global.dy.clamp(rect.top, rect.bottom),
      );
      final d = (nearest - global).distanceSquared;
      if (d < distance) {
        closest = region;
        distance = d;
      }
    }
    final point = closest?.position(global);
    if (point == null || closest == null) return;
    final offset = closest.widget.location.offset + point.offset;
    final next = _make(
      leading ? selection.location.at(offset) : selection.location,
      leading ? selection.end : offset,
      selection.group,
    );
    if (next != null) value = next;
  }

  ReaderTextSelection? _make(
    ReaderMarkLocation location,
    int end,
    Object group,
  ) {
    final chapter = chapterText(location.chapter, location.axis);
    final start = location.offset;
    final clip = _view;
    if (clip == null ||
        chapter == null ||
        start < 0 ||
        end > chapter.text.length ||
        end <= start ||
        end - start > ReaderMark.maxQuoteLength) {
      return null;
    }
    final quote = chapter.text.substring(start, end);
    if (quote.trim().isEmpty) return null;
    final regions =
        _visible(group)
            .where(
              (r) =>
                  r.widget.selectable &&
                  _sameChapter(location, r.widget.location),
            )
            .toList()
          ..sort(
            (a, b) =>
                a.widget.location.offset.compareTo(b.widget.location.offset),
          );
    final boxes = [
      for (final region in regions)
        for (final rect in region.globalRects(start, end))
          if (rect.overlaps(clip)) rect.intersect(clip),
    ];
    return boxes.isEmpty
        ? null
        : ReaderTextSelection(
          location,
          end,
          quote,
          group,
          boxes,
          chapter.encoded,
        );
  }

  ReaderMark? matching(ReaderTextSelection selection) {
    for (final range in _ranges(selection.location).reversed) {
      if (range.start == selection.location.offset &&
          range.end == selection.end &&
          range.mark.quote == selection.quote) {
        return range.mark;
      }
    }
    return null;
  }

  bool hasHighlight(ReaderMarkLocation location, int end) => _ranges(
    location,
  ).any((range) => range.start < end && range.end > location.offset);

  List<_MarkRange> _ranges(ReaderMarkLocation location) {
    final marks = store.marks(book);
    if (!identical(marks, _revision)) {
      _revision = marks;
      _resolved.clear();
      _byChapter.clear();
      for (final mark in marks.reversed) {
        if (mark.isBookmark) continue;
        final key = (mark.location.chapter, mark.location.axis);
        (_byChapter[key] ??= []).add(mark);
      }
    }
    final key = (location.chapter, location.axis);
    final chapterMarks = _byChapter[key];
    if (chapterMarks == null) return const [];
    final chapter = chapterText(location.chapter, location.axis);
    if (chapter == null) return const [];
    final cached = _resolved[key];
    if (cached != null && identical(cached.$1, chapter.text)) return cached.$2;
    final ranges = <_MarkRange>[];
    for (final mark in chapterMarks) {
      final start = mark.offsetIn(chapter.text);
      if (start != null) {
        ranges.add((start: start, end: start + mark.quote.length, mark: mark));
      }
    }
    if (_resolved.length >= 3) _resolved.remove(_resolved.keys.first);
    _resolved[key] = (chapter.text, ranges);
    return ranges;
  }

  ({RenderBox box, Rect rect})? renderedPosition(ReaderMarkLocation location) {
    for (final region in _regions) {
      final start = region.widget.location.offset,
          length = region.widget.text.length;
      if (!_sameChapter(location, region.widget.location) ||
          location.offset < start ||
          location.offset > start + length) {
        continue;
      }
      final box = region.box;
      if (box == null) continue;
      final local = location.offset - start;
      final rects = box.rects(local, math.min(local + 1, length));
      return (
        box: box,
        rect: rects.isEmpty ? Offset.zero & box.size : rects.first,
      );
    }
    return null;
  }

  ReaderMarkLocation? visiblePosition(Object group, double topInset) {
    final view = _view;
    if (view == null) return null;
    final top = view.top + topInset;
    _MarkedRegionState? region;
    Rect? rect;
    for (final candidate in _regions) {
      if (candidate.widget.group != group) continue;
      final bounds = candidate.bounds;
      if (bounds == null || bounds.bottom <= top || !bounds.overlaps(view)) {
        continue;
      }
      if (rect == null || bounds.top < rect.top) {
        region = candidate;
        rect = bounds;
      }
    }
    if (region == null || rect == null) return null;
    final point = region.position(Offset(rect.left, math.max(top, rect.top)));
    final location = region.widget.location;
    return location.at(location.offset + (point?.offset ?? 0));
  }
}

bool _sameChapter(ReaderMarkLocation a, ReaderMarkLocation b) =>
    a.chapter == b.chapter && a.axis == b.axis;

class ReaderMarkedRegion extends StatefulWidget {
  const ReaderMarkedRegion({
    super.key,
    required this.selection,
    required this.location,
    required this.text,
    required this.group,
    required this.child,
    this.selectable = true,
  });
  final ReaderMarkSelection selection;
  final ReaderMarkLocation location;
  final String text;
  final Object group;
  final Widget child;
  final bool selectable;

  @override
  State<ReaderMarkedRegion> createState() => _MarkedRegionState();
}

class _MarkedRegionState extends State<ReaderMarkedRegion> {
  final _key = GlobalKey();
  _MarkRenderBox? get box {
    final render = _key.currentContext?.findRenderObject();
    return render is _MarkRenderBox && render.attached && render.hasSize
        ? render
        : null;
  }

  Rect? get bounds {
    final render = box;
    return render == null
        ? null
        : render.localToGlobal(Offset.zero) & render.size;
  }

  TextPosition? position(Offset global) {
    final render = box;
    return render?.position(render.globalToLocal(global));
  }

  Iterable<Rect> globalRects(int start, int end) sync* {
    final render = box;
    if (render == null) return;
    final base = widget.location.offset, length = widget.text.length;
    for (final rect in render.rects(
      (start - base).clamp(0, length),
      (end - base).clamp(0, length),
    )) {
      if (rect.width > 0 && rect.height > 0) {
        yield Rect.fromPoints(
          render.localToGlobal(rect.topLeft),
          render.localToGlobal(rect.bottomRight),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.selection._regions.add(this);
  }

  @override
  void didUpdateWidget(ReaderMarkedRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection._regions.remove(this);
      widget.selection._regions.add(this);
    }
  }

  @override
  void dispose() {
    widget.selection._regions.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _MarkPaint(
      key: _key,
      selection: widget.selection,
      location: widget.location,
      length: widget.text.length,
      child: widget.child,
    );
    return !widget.selectable || widget.text.trim().isEmpty
        ? content
        : GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart:
              (details) => widget.selection.beginAt(
                details.globalPosition,
                widget.group,
              ),
          child: content,
        );
  }
}

class _MarkPaint extends SingleChildRenderObjectWidget {
  const _MarkPaint({
    super.key,
    required this.selection,
    required this.location,
    required this.length,
    required super.child,
  });
  final ReaderMarkSelection selection;
  final ReaderMarkLocation location;
  final int length;

  @override
  _MarkRenderBox createRenderObject(BuildContext context) =>
      _MarkRenderBox(selection, location, length);
  @override
  void updateRenderObject(BuildContext context, _MarkRenderBox box) =>
      box.update(selection, location, length);
}

class _MarkRenderBox extends RenderProxyBox {
  _MarkRenderBox(this._selection, this._location, this._length);
  ReaderMarkSelection _selection;
  ReaderMarkLocation _location;
  int _length;

  void update(
    ReaderMarkSelection selection,
    ReaderMarkLocation location,
    int length,
  ) {
    if (attached && !identical(selection.store, _selection.store)) {
      _selection.store.removeListener(markNeedsPaint);
      selection.store.addListener(markNeedsPaint);
    }
    if (!identical(selection, _selection) ||
        !_location.samePosition(location) ||
        length != _length) {
      _selection = selection;
      _location = location;
      _length = length;
      markNeedsPaint();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _selection.store.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _selection.store.removeListener(markNeedsPaint);
    super.detach();
  }

  TextPosition? position(Offset offset) => switch (child) {
    RenderParagraph text => text.getPositionForOffset(offset),
    ReaderStyledTextGeometry text => text.textPosition(offset),
    _ => null,
  };
  TextRange? word(TextPosition position) {
    if (_length == 0) return null;
    final inside = TextPosition(
      offset: position.offset.clamp(0, _length - 1),
      affinity: position.affinity,
    );
    return switch (child) {
      RenderParagraph text => text.getWordBoundary(inside),
      ReaderStyledTextGeometry text => text.wordBoundary(inside),
      _ => null,
    };
  }

  List<Rect> rects(int start, int end) {
    if (start >= end) return const [];
    final range = TextSelection(baseOffset: start, extentOffset: end);
    return switch (child) {
      RenderParagraph text =>
        text
            .getBoxesForSelection(range, boxHeightStyle: BoxHeightStyle.max)
            .map((box) => box.toRect())
            .toList(),
      ReaderStyledTextGeometry text => text.textRects(range),
      _ => const [],
    };
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final base = _location.offset, styled = child is ReaderStyledTextGeometry;
    if (styled) super.paint(context, offset);
    if (_length > 0) {
      for (final range in _selection._ranges(_location)) {
        final boxes = rects(
          (range.start - base).clamp(0, _length),
          (range.end - base).clamp(0, _length),
        );
        final color = Color(range.mark.color!.argb);
        final fill =
            Paint()..color = color.withValues(alpha: styled ? .32 : .48);
        for (final rect in boxes) {
          if (rect.width > 0) {
            context.canvas.drawRRect(
              RRect.fromRectAndRadius(
                rect.shift(offset),
                const Radius.circular(3),
              ),
              fill,
            );
          }
        }
        if (range.mark.note.isNotEmpty &&
            range.start >= base &&
            boxes.isNotEmpty) {
          context.canvas.drawCircle(
            boxes.first.topLeft + offset,
            3.5,
            Paint()..color = color,
          );
        }
      }
    }
    if (!styled) super.paint(context, offset);
  }
}
