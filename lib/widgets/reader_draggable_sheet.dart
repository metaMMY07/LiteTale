import 'package:flutter/material.dart';

/// List gestures use Flutter's normal sheet/scroll handoff. The header handle
/// resizes the same sheet directly, even with the current chapter far down the
/// list; expanding must not first scroll all the way back to chapter one.
class ReaderDraggableSheet extends StatefulWidget {
  const ReaderDraggableSheet({
    super.key,
    this.initialChildSize = .55,
    required this.handleKey,
    required this.builder,
  });
  final double initialChildSize;
  final Key handleKey;
  final Widget Function(BuildContext, ScrollController, Widget) builder;
  @override
  State<ReaderDraggableSheet> createState() => _ReaderDraggableSheetState();
}

class _ReaderDraggableSheetState extends State<ReaderDraggableSheet> {
  final _controller = DraggableScrollableController();
  static const _min = .35, _max = .94;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:
        (context, constraints) => DraggableScrollableSheet(
          controller: _controller,
          expand: false,
          initialChildSize: widget.initialChildSize,
          minChildSize: _min,
          maxChildSize: _max,
          builder:
              (context, scrollController) => widget.builder(
                context,
                scrollController,
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) {
                    if (_controller.isAttached)
                      _controller.jumpTo(_controller.size);
                  },
                  onVerticalDragUpdate: (details) {
                    final height = constraints.maxHeight;
                    if (!_controller.isAttached ||
                        !height.isFinite ||
                        height <= 0)
                      return;
                    _controller.jumpTo(
                      (_controller.size - details.delta.dy / height).clamp(
                        _min,
                        _max,
                      ),
                    );
                  },
                  child: SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: Center(
                      child: Container(
                        key: widget.handleKey,
                        width: 36,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ),
  );
}
