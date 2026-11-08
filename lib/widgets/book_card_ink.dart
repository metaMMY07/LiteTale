import 'package:flutter/material.dart';

/// Put the Material press feedback above an opaque cover while keeping the
/// original InkWell gesture arena (including the cover's own retry button).
class BookCardInk extends StatefulWidget {
  const BookCardInk({
    super.key,
    required this.borderRadius,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final VoidCallback? onTap, onLongPress;

  @override
  State<BookCardInk> createState() => _BookCardInkState();
}

class _BookCardInkState extends State<BookCardInk> {
  final _pressed = ValueNotifier(false);

  @override
  void dispose() {
    _pressed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null && widget.onLongPress == null) return widget.child;
    if (Theme.of(context).platform != TargetPlatform.android) {
      return InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: widget.child,
      );
    }
    final tint = Theme.of(context).colorScheme.onSurface;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      borderRadius: widget.borderRadius,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      onHighlightChanged: (pressed) {
        if (mounted) _pressed.value = pressed;
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<bool>(
                valueListenable: _pressed,
                builder:
                    (context, pressed, _) => AnimatedContainer(
                      duration:
                          pressed || reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 120),
                      curve: Curves.easeOutQuad,
                      decoration: BoxDecoration(
                        borderRadius: widget.borderRadius,
                        color: tint.withValues(alpha: pressed ? .10 : 0),
                      ),
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
