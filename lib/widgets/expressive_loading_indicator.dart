import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// The Android Material 3 Expressive loading shapes, with a circle added so
/// the first frame and each completed loop have a familiar resting shape.
final List<RoundedPolygon> _loadingShapes = [
  MaterialShapes.circle,
  MaterialShapes.softBurst,
  MaterialShapes.cookie9Sided,
  MaterialShapes.pentagon,
  MaterialShapes.pill,
  MaterialShapes.sunny,
  MaterialShapes.cookie4Sided,
  MaterialShapes.oval,
];

/// Matching the polygons is expensive; do it once rather than at every frame
/// or whenever a loading page is rebuilt.
final List<Morph> _loadingMorphs = [
  for (var i = 0; i < _loadingShapes.length; i++)
    Morph(
      _loadingShapes[i].normalized(),
      _loadingShapes[(i + 1) % _loadingShapes.length].normalized(),
    ),
];

/// A compact, uncontained loading indicator for full-page loading states.
/// Only this widget's 48 dp paint area changes on each display frame.
class ExpressiveLoadingIndicator extends StatefulWidget {
  const ExpressiveLoadingIndicator({super.key, this.size = 48, this.color});

  final double size;
  final Color? color;

  @override
  State<ExpressiveLoadingIndicator> createState() =>
      _ExpressiveLoadingIndicatorState();
}

class _ExpressiveLoadingIndicatorState extends State<ExpressiveLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final ValueNotifier<double> _elapsedSeconds = ValueNotifier(0);
  late final Ticker _ticker = createTicker((elapsed) {
    _elapsedSeconds.value =
        elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      _elapsedSeconds.value = 0;
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsedSeconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '正在加载',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(
            painter: _ExpressiveLoadingPainter(
              _elapsedSeconds,
              widget.color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The same loading state at the center of any remaining page body.
class CenteredLoadingIndicator extends StatelessWidget {
  const CenteredLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: ExpressiveLoadingIndicator());
}

class _ExpressiveLoadingPainter extends CustomPainter {
  _ExpressiveLoadingPainter(this.elapsedSeconds, this.color)
    : super(repaint: elapsedSeconds);

  final ValueListenable<double> elapsedSeconds;
  final Color color;
  final Path _path = Path();
  static const _morphIntervalSeconds = 0.65;
  static const _rotationPeriodSeconds = 4.666;

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = elapsedSeconds.value;
    final step = seconds / _morphIntervalSeconds;
    final completedSteps = step.floor();
    final fraction = step - completedSteps;
    // The shape settles briefly before the next morph, as on Android.
    final progress = Curves.easeInOutCubic.transform(
      (fraction / 0.82).clamp(0.0, 1.0),
    );
    final morph = _loadingMorphs[completedSteps % _loadingMorphs.length];
    final path = morph.toPath(progress: progress, path: _path);
    final rotation =
        (completedSteps + progress) * math.pi / 2 +
        seconds * 2 * math.pi / _rotationPeriodSeconds;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rotation);
    // Normalized Material polygons occupy a 1x1 box. Leave enough space for
    // their diagonals when rotated, avoiding clipped corners.
    final extent = size.shortestSide * 0.68;
    canvas.scale(extent, extent);
    canvas.translate(-0.5, -0.5);
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ExpressiveLoadingPainter oldDelegate) =>
      color != oldDelegate.color ||
      elapsedSeconds != oldDelegate.elapsedSeconds;
}
