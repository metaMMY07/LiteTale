import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/bookshelf_tile.dart';

class BookshelfGrid extends StatefulWidget {
  const BookshelfGrid({
    super.key,
    required this.ids,
    required this.showSource,
    required this.reordering,
    required this.tile,
    required this.onReorder,
  });

  final List<String> ids;
  final bool showSource, reordering;
  final Widget Function(BuildContext, String) tile;
  final ValueChanged<List<String>> onReorder;

  @override
  State<BookshelfGrid> createState() => _BookshelfGridState();
}

class _BookshelfGridState extends State<BookshelfGrid> {
  String? _dragged;
  List<String>? _preview;
  EdgeDraggingAutoScroller? _autoScroller;

  @override
  void didUpdateWidget(covariant BookshelfGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragged != null &&
        (!widget.reordering || !listEquals(oldWidget.ids, widget.ids))) {
      _clearDrag();
    }
  }

  @override
  void dispose() {
    _clearDrag();
    super.dispose();
  }

  void _clearDrag() {
    _dragged = null;
    _preview = null;
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
  }

  void _hover(String target) {
    final dragged = _dragged;
    final order = _preview;
    if (dragged == null || order == null || dragged == target) return;
    final index = order.indexOf(target);
    if (index == -1) return;
    setState(() {
      order.remove(dragged);
      order.insert(index, dragged);
    });
  }

  void _finish(bool accepted) {
    if (!mounted || _dragged == null) return;
    final order = _preview;
    setState(_clearDrag);
    if (accepted && order != null && !listEquals(order, widget.ids)) {
      widget.onReorder(order);
    }
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      const gap = 10.0;
      final width = constraints.crossAxisExtent;
      final columns = (width / 145).floor().clamp(width < 282 ? 2 : 3, 8);
      final tileWidth = (width - (columns - 1) * gap) / columns;
      final tileHeight =
          tileWidth * 1.5 +
          BookshelfTile.captionHeight(context, widget.showSource);
      final order = _preview ?? widget.ids;
      final indices = {for (var i = 0; i < order.length; i++) order[i]: i};
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
          mainAxisExtent: tileHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final id = order[index];
            final tile = widget.tile(context, id);
            return KeyedSubtree(
              key: ValueKey(id),
              child:
                  widget.reordering
                      ? DragTarget<String>(
                        onWillAcceptWithDetails:
                            (details) => _dragged == details.data,
                        onMove: (_) => _hover(id),
                        builder:
                            (_, __, ___) => LongPressDraggable<String>(
                              data: id,
                              maxSimultaneousDrags: _dragged == null ? 1 : 0,
                              onDragStarted: () {
                                _autoScroller = EdgeDraggingAutoScroller(
                                  Scrollable.of(context),
                                  velocityScalar: 12,
                                );
                                setState(() {
                                  _dragged = id;
                                  _preview = widget.ids.toList();
                                });
                              },
                              onDragUpdate: (details) {
                                _autoScroller?.startAutoScrollIfNecessary(
                                  Rect.fromCenter(
                                    center: details.globalPosition,
                                    width: 32,
                                    height: 48,
                                  ),
                                );
                              },
                              onDragEnd:
                                  (details) => _finish(details.wasAccepted),
                              childWhenDragging: Opacity(
                                opacity: .2,
                                child: tile,
                              ),
                              feedback: Material(
                                type: MaterialType.transparency,
                                child: Transform.scale(
                                  scale:
                                      MediaQuery.disableAnimationsOf(context)
                                          ? 1
                                          : 1.04,
                                  child: SizedBox(
                                    width: tileWidth,
                                    height: tileHeight,
                                    child: tile,
                                  ),
                                ),
                              ),
                              child: tile,
                            ),
                      )
                      : tile,
            );
          },
          childCount: order.length,
          findChildIndexCallback:
              (key) => key is ValueKey<String> ? indices[key.value] : null,
        ),
      );
    },
  );
}
