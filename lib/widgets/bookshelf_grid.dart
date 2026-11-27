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
    this.gridDelegate,
  });

  final List<String> ids;
  final bool showSource, reordering;
  final Widget Function(BuildContext, String) tile;
  final ValueChanged<List<String>> onReorder;
  final SliverGridDelegate? gridDelegate;

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

  SliverGridDelegate _coverGrid(BuildContext context, double width) {
    const gap = 10.0;
    final columns = (width / 145).floor().clamp(width < 282 ? 2 : 3, 8);
    final tileWidth = (width - (columns - 1) * gap) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: gap,
      mainAxisSpacing: gap,
      mainAxisExtent:
          tileWidth * 1.5 +
          BookshelfTile.captionHeight(context, widget.showSource),
    );
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final delegate =
          widget.gridDelegate ??
          _coverGrid(context, constraints.crossAxisExtent);
      final dragLayout =
          widget.reordering ? delegate.getLayout(constraints) : null;
      final order = _preview ?? widget.ids;
      final indices = {for (var i = 0; i < order.length; i++) order[i]: i};
      return SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final id = order[index];
            final tile = widget.tile(context, id);
            final dragTile = dragLayout?.getGeometryForChildIndex(index);
            return KeyedSubtree(
              key: ValueKey(id),
              child:
                  dragTile != null
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
                                    width: dragTile.crossAxisExtent,
                                    height: dragTile.mainAxisExtent,
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
