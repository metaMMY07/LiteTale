import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// List gestures use Flutter's normal sheet/scroll handoff. The header handle
/// resizes the same sheet directly, even with the current chapter far down the
/// list; expanding must not first scroll all the way back to chapter one.
class ReaderDraggableSheet extends StatefulWidget {
  const ReaderDraggableSheet({
    super.key,
    this.initialChildSize = .55,
    this.snapToPages = false,
    required this.handleKey,
    required this.builder,
  });
  final double initialChildSize;

  /// Android's half/full presentation. Keep other platforms' existing motion.
  final bool snapToPages;
  final Key handleKey;
  final Widget Function(BuildContext, ScrollController, Widget) builder;
  @override
  State<ReaderDraggableSheet> createState() => _ReaderDraggableSheetState();
}

class _ReaderDraggableSheetState extends State<ReaderDraggableSheet> {
  final _controller = DraggableScrollableController();
  static const _min = .35, _half = .5;
  static const _snapDuration = Duration(milliseconds: 250);
  static const _drawerCurve = Cubic(.32, .72, 0, 1);
  double _handleStartSize = _half;
  double _handleDistance = 0;
  double get _max => widget.snapToPages ? 1 : .94;

  void _settle(double target) {
    if (!mounted ||
        !_controller.isAttached ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(target);
    } else {
      // animateTo starts at the displayed extent and can be interrupted by
      // another handle/list gesture. Do not wait for it to accept new input.
      unawaited(
        _controller.animateTo(
          target,
          duration: _snapDuration,
          curve: _drawerCurve,
        ),
      );
    }
  }

  void _finishHandleDrag(DragEndDetails details) {
    if (!widget.snapToPages || !_controller.isAttached) return;
    final velocity = details.primaryVelocity ?? 0;
    final direction =
        velocity.abs() >= kMinFlingVelocity ? -velocity : -_handleDistance;
    if (direction > 0) {
      _settle(_max);
    } else if (direction < 0) {
      _settle(
        _handleStartSize > _half + precisionErrorTolerance ? _half : _min,
      );
    } else {
      _settle(_controller.size > (_half + _max) / 2 ? _max : _half);
    }
  }

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
          initialChildSize:
              widget.snapToPages ? _half : widget.initialChildSize,
          minChildSize: _min,
          maxChildSize: _max,
          snap: widget.snapToPages,
          snapSizes: widget.snapToPages ? const [_half] : null,
          snapAnimationDuration:
              widget.snapToPages
                  ? (MediaQuery.disableAnimationsOf(context)
                      ? const Duration(milliseconds: 1)
                      : _snapDuration)
                  : null,
          builder:
              (context, scrollController) => widget.builder(
                context,
                scrollController,
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) {
                    if (_controller.isAttached) {
                      _handleStartSize = _controller.size;
                      _handleDistance = 0;
                      _controller.jumpTo(_controller.size);
                    }
                  },
                  onVerticalDragUpdate: (details) {
                    final height = constraints.maxHeight;
                    if (!_controller.isAttached ||
                        !height.isFinite ||
                        height <= 0) {
                      return;
                    }
                    _handleDistance += details.delta.dy;
                    _controller.jumpTo(
                      (_controller.size - details.delta.dy / height).clamp(
                        _min,
                        _max,
                      ),
                    );
                  },
                  onVerticalDragEnd: _finishHandleDrag,
                  onVerticalDragCancel: () {
                    if (widget.snapToPages && _controller.isAttached) {
                      _settle(
                        _controller.size > (_half + _max) / 2 ? _max : _half,
                      );
                    }
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
