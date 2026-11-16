import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The listening scrubber keeps the stock Slider's value and gesture mapping.
class WavySliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const WavySliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final stroke = track.height;
    final cap = stroke / 2;
    final gap = (sliderTheme.trackGap ?? 6) + cap;
    final rtl = textDirection == TextDirection.rtl;
    final active =
        Color.lerp(
          sliderTheme.disabledActiveTrackColor,
          sliderTheme.activeTrackColor,
          enableAnimation.value,
        )!;
    final inactive =
        Color.lerp(
          sliderTheme.disabledInactiveTrackColor,
          sliderTheme.inactiveTrackColor,
          enableAnimation.value,
        )!;
    final paint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    final canvas = context.canvas;
    final left = track.left + cap;
    final right = track.right - cap;
    _drawWave(
      canvas,
      track,
      left,
      thumbCenter.dx - gap,
      paint..color = rtl ? inactive : active,
      rtl ? 1.5 : 3,
    );
    _drawWave(
      canvas,
      track,
      thumbCenter.dx + gap,
      right,
      paint..color = rtl ? active : inactive,
      rtl ? 3 : 1.5,
    );
  }

  void _drawWave(
    Canvas canvas,
    Rect track,
    double start,
    double end,
    Paint paint,
    double amplitude,
  ) {
    if (end <= start) return;
    const wavelength = 24.0;
    final center = track.center.dy;
    final path = Path()..moveTo(start, center);
    for (var x = start + 2; x < end; x += 2) {
      // Flatten both ends so the wave meets the handle gap cleanly.
      final envelope = math.min(1.0, math.min(x - start, end - x) / 6);
      final angle = (x - track.left) * 2 * math.pi / wavelength;
      path.lineTo(x, center + amplitude * envelope * math.sin(angle));
    }
    canvas.drawPath(path..lineTo(end, center), paint);
  }
}
