import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps the old screen still while the new theme expands from the tapped icon.
/// Only one bitmap and a circular clip are painted during the transition.
class ThemeRevealHost extends StatefulWidget {
  const ThemeRevealHost({super.key, required this.child});

  final Widget child;

  static ThemeRevealHostState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ThemeRevealScope>()?.state;

  @override
  State<ThemeRevealHost> createState() => ThemeRevealHostState();
}

class ThemeRevealHostState extends State<ThemeRevealHost>
    with SingleTickerProviderStateMixin {
  final _pageKey = GlobalKey();
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  ui.Image? _oldFrame;
  Offset _origin = Offset.zero;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutSine,
    );
  }

  @override
  void dispose() {
    _oldFrame?.dispose();
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> revealFrom({
    required BuildContext triggerContext,
    required VoidCallback changeTheme,
  }) async {
    if (_busy) return;
    _busy = true;
    try {
      if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
        changeTheme();
        return;
      }

      final page = _pageKey.currentContext?.findRenderObject();
      final trigger = triggerContext.findRenderObject();
      if (page is! RenderRepaintBoundary ||
          trigger is! RenderBox ||
          !page.hasSize ||
          !trigger.hasSize) {
        changeTheme();
        return;
      }

      final buttonCenter = trigger.localToGlobal(
        trigger.size.center(Offset.zero),
      );
      final origin = page.globalToLocal(buttonCenter);
      ui.Image frame;
      try {
        final pixelRatio = math.min(
          MediaQuery.devicePixelRatioOf(context),
          2.0,
        );
        frame = await page.toImage(pixelRatio: pixelRatio);
      } catch (_) {
        // A not-yet-painted surface should still switch themes immediately.
        changeTheme();
        return;
      }
      if (!mounted) {
        frame.dispose();
        return;
      }

      // The previous reveal ends at 1.0. Reset before either theme rebuilds or
      // the overlay paints, otherwise the next tap exposes the entire new
      // theme for one frame and then snaps back to the start of the circle.
      _controller.value = 0;
      setState(() {
        _oldFrame = frame;
        _origin = origin;
      });
      changeTheme();
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await _controller.forward(from: 0).orCancel;
    } on TickerCanceled {
      // The route was disposed while the reveal was running.
    } finally {
      if (mounted && _oldFrame != null) {
        final frame = _oldFrame!;
        setState(() => _oldFrame = null);
        WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
      }
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => _ThemeRevealScope(
    state: this,
    child: Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _pageKey, child: widget.child),
        if (_oldFrame != null)
          Positioned.fill(
            child: AbsorbPointer(
              child: CustomPaint(
                key: const ValueKey('theme-reveal-overlay'),
                painter: _ThemeRevealPainter(
                  frame: _oldFrame!,
                  origin: _origin,
                  progress: _progress,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _ThemeRevealScope extends InheritedWidget {
  const _ThemeRevealScope({required this.state, required super.child});

  final ThemeRevealHostState state;

  @override
  bool updateShouldNotify(_ThemeRevealScope oldWidget) => false;
}

class _ThemeRevealPainter extends CustomPainter {
  _ThemeRevealPainter({
    required this.frame,
    required this.origin,
    required this.progress,
  }) : super(repaint: progress);

  final ui.Image frame;
  final Offset origin;
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final farX = math.max(origin.dx, size.width - origin.dx);
    final farY = math.max(origin.dy, size.height - origin.dy);
    final endRadius = math.sqrt(farX * farX + farY * farY);
    // Start at the pressed icon rather than growing invisibly from one pixel.
    final radius = 24.0 + (endRadius - 24.0) * progress.value;
    final outsideCircle =
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addOval(Rect.fromCircle(center: origin, radius: radius));
    canvas.save();
    canvas.clipPath(outsideCircle);
    canvas.drawImageRect(
      frame,
      Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThemeRevealPainter oldDelegate) =>
      frame != oldDelegate.frame || origin != oldDelegate.origin;
}
