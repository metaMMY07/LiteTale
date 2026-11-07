import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/models/reader_mark.dart';
import 'package:wild/services/reader_mark_store.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_mark_selection.dart';

const _markEaseOut = Cubic(.23, 1, .32, 1);
const _markMotion = Duration(milliseconds: 180);

String readerMarkExcerpt(String quote, {bool encoded = false}) =>
    encoded
        ? '原文选区'
        : quote
            .replaceAll(RegExp(r'<!--image-->[^<]+<!--image-->'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

Future<String?> _editNote(BuildContext context, String initial, String quote) =>
    showAdaptiveDialog<String>(
      context: context,
      builder: (context) => _NoteEditor(initial: initial, quote: quote),
    );

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({required this.initial, required this.quote});
  final String initial, quote;
  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog.adaptive(
    title: Text(widget.initial.isEmpty ? '添加笔记' : '编辑笔记'),
    content: Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.quote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  widget.quote,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              maxLength: ReaderMark.maxNoteLength,
              decoration: const InputDecoration(hintText: '写下你的想法'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      AppButton.text(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      ValueListenableBuilder(
        valueListenable: _controller,
        builder:
            (context, value, _) => AppButton.text(
              onPressed:
                  value.text.trim().isEmpty && widget.initial.isEmpty
                      ? null
                      : () => Navigator.pop(context, value.text.trim()),
              child: const Text('保存'),
            ),
      ),
    ],
  );
}

void showReaderMarkError(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// Draws selection and draggable grips above the paper. Saved marks themselves
/// are drawn in the text layer so they are also included in a curled page.
class ReaderMarkLayer extends StatefulWidget {
  const ReaderMarkLayer({super.key, required this.selection});
  final ReaderMarkSelection selection;
  @override
  State<ReaderMarkLayer> createState() => _ReaderMarkLayerState();
}

class _ReaderMarkLayerState extends State<ReaderMarkLayer> {
  ReaderTextSelection? _palette;
  bool _busy = false;
  ReaderMarkSelection get _selection => widget.selection;

  Future<void> _highlight(
    ReaderTextSelection target,
    ReaderMarkColor color,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _palette = target;
    });
    try {
      await _save(target, color);
      _selection.lastColor = color;
    } catch (_) {
      if (mounted) {
        setState(() => _palette = null);
        showReaderMarkError(context, '高亮保存失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(
    ReaderTextSelection target,
    ReaderMarkColor color, {
    String? note,
  }) => _selection.store.saveHighlight(
    _selection.book,
    target.location,
    quote: target.quote,
    color: color,
    note: note,
    encodedQuote: target.encoded,
    matchId: _selection.matching(target)?.id,
  );

  Future<void> _note(ReaderTextSelection target) async {
    if (_busy) return;
    final existing = _selection.matching(target);
    _selection.clear();
    setState(() => _busy = true);
    try {
      final note = await _editNote(
        context,
        existing?.note ?? '',
        readerMarkExcerpt(target.quote, encoded: target.encoded),
      );
      if (note != null && mounted) {
        await _save(
          target,
          existing?.color ?? _selection.lastColor,
          note: note,
        );
      }
    } catch (_) {
      if (mounted) showReaderMarkError(context, '笔记保存失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _selection,
    builder: (context, target, _) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      return AnimatedSwitcher(
        duration: reduceMotion ? Duration.zero : _markMotion,
        switchInCurve: _markEaseOut,
        switchOutCurve: Curves.easeOut,
        layoutBuilder:
            (current, previous) => Stack(
              fit: StackFit.expand,
              children: [
                for (final child in previous)
                  IgnorePointer(child: ExcludeSemantics(child: child)),
                if (current != null) current,
              ],
            ),
        child:
            target == null
                ? const SizedBox.shrink()
                : _buildSelection(context, target, reduceMotion),
      );
    },
  );

  Widget _buildSelection(
    BuildContext context,
    ReaderTextSelection target,
    bool reduceMotion,
  ) {
    final viewport = _selection.viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) {
      return const SizedBox.shrink();
    }
    final origin = viewport.localToGlobal(Offset.zero);
    final boxes = target.boxes.map((r) => r.shift(-origin)).toList();
    final hasPalette = identical(_palette, target);
    final colors = Theme.of(context).colorScheme;
    final accent =
        usesAppleGlass
            ? CupertinoColors.activeBlue.resolveFrom(context)
            : colors.primary;
    final bounds = boxes.reduce((a, b) => a.expandToInclude(b));
    final media = MediaQuery.of(context);
    return Stack(
      key: const ValueKey('reader-text-selection'),
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (!hasPalette) ...[
          IgnorePointer(
            child: CustomPaint(painter: _SelectionPaint(boxes, accent)),
          ),
          _grip(boxes.first.topLeft, accent, leading: true),
          _grip(boxes.last.bottomRight, accent, leading: false),
        ],
        CustomSingleChildLayout(
          delegate: _MenuPosition(bounds, media.padding),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: reduceMotion ? 1 : .95, end: 1),
            duration: reduceMotion ? Duration.zero : _markMotion,
            curve: _markEaseOut,
            builder:
                (_, scale, child) => Transform.scale(
                  alignment:
                      bounds.top > 106
                          ? Alignment.bottomCenter
                          : Alignment.topCenter,
                  scale: scale,
                  child: child,
                ),
            child: _menu(context, target, hasPalette, reduceMotion),
          ),
        ),
      ],
    );
  }

  Widget _grip(Offset point, Color color, {required bool leading}) {
    const size = 38.0;
    final center = point + Offset(0, leading ? -5 : 5);
    return Positioned(
      left: center.dx - size / 2,
      top: center.dy - size / 2,
      width: size,
      height: size,
      child: GestureDetector(
        key: ValueKey(
          leading ? 'selection-start-handle' : 'selection-end-handle',
        ),
        behavior: HitTestBehavior.opaque,
        onPanUpdate:
            (details) => _selection.moveHandle(
              details.globalPosition + Offset(0, leading ? 9 : -9),
              leading: leading,
            ),
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  Widget _menu(
    BuildContext context,
    ReaderTextSelection target,
    bool palette,
    bool reduced,
  ) {
    final color = _selection.matching(target)?.color ?? _selection.lastColor;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final content = SizedBox(
      width: 224,
      height: 48,
      child: AnimatedSwitcher(
        duration: reduced ? Duration.zero : _markMotion,
        switchInCurve: _markEaseOut,
        layoutBuilder:
            (current, previous) => Stack(
              fit: StackFit.expand,
              children: [
                for (final child in previous)
                  IgnorePointer(child: ExcludeSemantics(child: child)),
                if (current != null) current,
              ],
            ),
        child:
            palette
                ? Row(
                  key: const ValueKey('highlight-colors'),
                  children: [
                    for (final option in ReaderMarkColor.values)
                      Expanded(
                        child: IconButton(
                          tooltip: option.label,
                          isSelected: option == color,
                          onPressed:
                              _busy ? null : () => _highlight(target, option),
                          icon: Icon(
                            Icons.circle,
                            color: Color(option.argb),
                            size: 22,
                          ),
                          selectedIcon: Icon(
                            Icons.check_circle_rounded,
                            color: Color(option.argb),
                            size: 24,
                          ),
                        ),
                      ),
                  ],
                )
                : Row(
                  key: const ValueKey('highlight-actions'),
                  children: [
                    Expanded(
                      child: AppButton.text(
                        onPressed:
                            _busy ? null : () => _highlight(target, color),
                        child: Text('高亮', style: TextStyle(color: ink)),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      indent: 13,
                      endIndent: 13,
                      color: ink.withValues(alpha: .16),
                    ),
                    Expanded(
                      child: AppButton.text(
                        onPressed: _busy ? null : () => _note(target),
                        child: Text('添加笔记', style: TextStyle(color: ink)),
                      ),
                    ),
                  ],
                ),
      ),
    );
    return usesAppleGlass
        ? AppleGlassSurface(
          capsule: true,
          tint: theme.colorScheme.surface.withValues(alpha: .48),
          child: Material(type: MaterialType.transparency, child: content),
        )
        : Material(
          color: theme.colorScheme.surfaceContainerHighest,
          elevation: 4,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: content,
        );
  }
}

class _MenuPosition extends SingleChildLayoutDelegate {
  const _MenuPosition(this.anchor, this.safe);
  final Rect anchor;
  final EdgeInsets safe;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - safe.horizontal - 16),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = safe.left + 8, top = safe.top + 8;
    final maxX = math.max(left, size.width - safe.right - childSize.width - 8);
    final maxY = math.max(
      top,
      size.height - safe.bottom - childSize.height - 8,
    );
    final above = anchor.top - childSize.height - 16;
    final below = anchor.bottom + 16;
    return Offset(
      (anchor.center.dx - childSize.width / 2).clamp(left, maxX),
      (above >= top ? above : below).clamp(top, maxY),
    );
  }

  @override
  bool shouldRelayout(_MenuPosition oldDelegate) =>
      anchor != oldDelegate.anchor || safe != oldDelegate.safe;
}

class _SelectionPaint extends CustomPainter {
  const _SelectionPaint(this.boxes, this.color);
  final List<Rect> boxes;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: .28);
    for (final box in boxes) {
      canvas.drawRect(box, fill);
    }
    final caret =
        Paint()
          ..color = color
          ..strokeWidth = 2;
    canvas.drawLine(boxes.first.topLeft, boxes.first.bottomLeft, caret);
    canvas.drawLine(boxes.last.topRight, boxes.last.bottomRight, caret);
  }

  @override
  bool shouldRepaint(_SelectionPaint oldDelegate) =>
      oldDelegate.boxes != boxes || oldDelegate.color != color;
}

Future<ReaderMark?> showReaderMarks(
  BuildContext context, {
  required ReaderMarkSelection selection,
  required ReaderMarkLocation current,
  String bookmarkExcerpt = '',
  bool Function(ReaderMarkLocation)? onCurrentPage,
}) {
  final sheet = _ReaderMarksPanel(
    store: selection.store,
    book: selection.book,
    current: current,
    bookmarkExcerpt: bookmarkExcerpt,
    onCurrentPage: onCurrentPage,
  );
  if (usesAppleGlass) {
    return showCupertinoModalPopup<ReaderMark>(
      context: context,
      useRootNavigator: false,
      builder: (_) => sheet,
    );
  }
  return showModalBottomSheet<ReaderMark>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (_) => sheet,
  );
}

class _ReaderMarksPanel extends StatefulWidget {
  const _ReaderMarksPanel({
    required this.store,
    required this.book,
    required this.current,
    required this.bookmarkExcerpt,
    this.onCurrentPage,
  });
  final ReaderMarkStore store;
  final String book, bookmarkExcerpt;
  final ReaderMarkLocation current;
  final bool Function(ReaderMarkLocation)? onCurrentPage;
  @override
  State<_ReaderMarksPanel> createState() => _ReaderMarksPanelState();
}

class _ReaderMarksPanelState extends State<_ReaderMarksPanel> {
  late Future<void> _loaded = widget.store.load(widget.book);
  bool _bookmarks = true, _busy = false;

  Future<void> _change(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) showReaderMarkError(context, '无法保存标记，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _actions(ReaderMark mark) async {
    final action = await showAdaptiveDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog.adaptive(
            title: Text(mark.isBookmark ? '书签' : '高亮'),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              if (!mark.isBookmark)
                AppButton.text(
                  onPressed: () => Navigator.pop(context, 'note'),
                  child: Text(mark.note.isEmpty ? '添加笔记' : '编辑笔记'),
                ),
              AppButton.text(
                onPressed: () => Navigator.pop(context, 'remove'),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (!mounted) return;
    if (action == 'remove') {
      await _change(() => widget.store.remove(widget.book, mark.id));
    } else if (action == 'note') {
      final note = await _editNote(
        context,
        mark.note,
        readerMarkExcerpt(mark.quote, encoded: mark.encodedQuote),
      );
      if (note != null && mounted) {
        await _change(() => widget.store.editNote(widget.book, mark.id, note));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      bottom: false,
      child: FractionallySizedBox(
        heightFactor: .89,
        widthFactor: 1,
        child: Material(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('高亮与书签', style: theme.textTheme.titleLarge),
                      ),
                      AppIconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: AppSegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('书签')),
                      ButtonSegment(value: false, label: Text('高亮')),
                    ],
                    selected: {_bookmarks},
                    onSelectionChanged:
                        (value) => setState(() => _bookmarks = value.single),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<void>(
                    future: _loaded,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: AppButton.text(
                            onPressed:
                                () => setState(
                                  () =>
                                      _loaded = widget.store.load(widget.book),
                                ),
                            child: const Text('无法读取标记，点此重试'),
                          ),
                        );
                      }
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return ListenableBuilder(
                        listenable: widget.store,
                        builder: (context, _) => _list(context),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final items =
        widget.store
            .marks(widget.book)
            .where((mark) => mark.isBookmark == _bookmarks)
            .toList();
    ReaderMark? here;
    if (_bookmarks) {
      for (final mark in items) {
        if (widget.onCurrentPage?.call(mark.location) ??
            mark.location.samePosition(widget.current)) {
          here = mark;
          break;
        }
      }
    }
    final existing = here;
    return ListView(
      key: ValueKey(_bookmarks),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        if (_bookmarks)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppButton.tonal(
              onPressed:
                  _busy
                      ? null
                      : () => _change(
                        () =>
                            existing == null
                                ? widget.store.addBookmark(
                                  widget.book,
                                  widget.current,
                                  quote: widget.bookmarkExcerpt,
                                )
                                : widget.store.remove(widget.book, existing.id),
                      ),
              child: Text(existing == null ? '添加当前位置书签' : '移除当前位置书签'),
            ),
          ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Text(
              _bookmarks ? '还没有书签' : '长按正文，可添加高亮或笔记',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        for (final mark in items)
          ListTile(
            key: ValueKey(mark.id),
            leading:
                mark.color == null
                    ? const Icon(Icons.bookmark_border_rounded)
                    : Icon(
                      Icons.circle,
                      color: Color(mark.color!.argb),
                      size: 16,
                    ),
            title: Text(
              mark.isBookmark
                  ? mark.location.title
                  : readerMarkExcerpt(mark.quote, encoded: mark.encodedQuote),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if (!mark.isBookmark)
                  mark.location.title
                else if (mark.quote.isNotEmpty)
                  mark.quote,
                if (mark.note.isNotEmpty) mark.note,
              ].join('\n'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: AppIconButton(
              tooltip: '管理标记',
              onPressed: _busy ? null : () => _actions(mark),
              icon: const Icon(Icons.more_horiz),
            ),
            onTap: _busy ? null : () => Navigator.pop(context, mark),
          ),
      ],
    );
  }
}
