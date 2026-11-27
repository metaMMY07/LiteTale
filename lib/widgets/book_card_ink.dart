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
  final _states = WidgetStatesController();

  @override
  void initState() {
    super.initState();
    _states.addListener(_statesChanged);
  }

  void _statesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant BookCardInk oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onTap == null && widget.onLongPress == null) {
      _states.value = <WidgetState>{};
    }
  }

  @override
  void dispose() {
    _states.removeListener(_statesChanged);
    _states.dispose();
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
    final colors = Theme.of(context).colorScheme;
    final tint = colors.onSurface;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final states = _states.value;
    final pressed = states.contains(WidgetState.pressed);
    final active =
        pressed ||
        states.contains(WidgetState.focused) ||
        states.contains(WidgetState.hovered);
    final layerAlpha =
        !active
            ? 0.0
            : pressed || states.contains(WidgetState.focused)
            ? .10
            : .08;
    return InkWell(
      statesController: _states,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      borderRadius: widget.borderRadius,
      splashFactory: reduceMotion ? NoSplash.splashFactory : null,
      highlightColor: reduceMotion ? Colors.transparent : null,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: pressed && !reduceMotion ? 1 : 0),
        duration:
            reduceMotion
                ? Duration.zero
                : Duration(milliseconds: pressed ? 100 : 160),
        curve: Curves.easeOutCubic,
        builder:
            (context, press, child) => Transform.scale(
              scale: 1 - .015 * press,
              transformHitTests: false,
              child: child,
            ),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRRect(
                  borderRadius: widget.borderRadius,
                  child: AnimatedContainer(
                    duration:
                        reduceMotion
                            ? Duration.zero
                            : Duration(milliseconds: active ? 90 : 150),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: layerAlpha),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
