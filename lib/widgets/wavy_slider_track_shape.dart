import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PipelineOwner, RenderProxyBox;

class WavySlider extends StatefulWidget {
  const WavySlider({super.key, required this.flowing, required this.child});

  final bool flowing;
  final Widget child;

  @override
  State<WavySlider> createState() => _WavySliderState();
}

class _WavySliderState extends State<WavySlider>
    with SingleTickerProviderStateMixin {
  late final _phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  late final _track = WavySliderTrackShape(phase: _phase);

  void _syncMotion() {
    final run =
        widget.flowing &&
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        ModalRoute.isCurrentOf(context) != false;
    if (run && !_phase.isAnimating) _phase.repeat();
    if (!run && _phase.isAnimating) _phase.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant WavySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.flowing != oldWidget.flowing) _syncMotion();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _WaveRepaint(
      phase: _phase,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          // ignore: deprecated_member_use
          year2023: false,
          activeTrackColor: colors.primary,
          inactiveTrackColor: colors.secondaryContainer,
          trackShape: _track,
          trackHeight: 4,
        ),
        child: widget.child,
      ),
    );
  }
}

// Repaint just the slider. Changing SliderTheme on each tick lays it out again.
class _WaveRepaint extends SingleChildRenderObjectWidget {
  const _WaveRepaint({required this.phase, required super.child});
  final Animation<double> phase;

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _RenderWaveRepaint(phase);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderWaveRepaint renderObject,
  ) => renderObject.phase = phase;
}

class _RenderWaveRepaint extends RenderProxyBox {
  _RenderWaveRepaint(this._phase);
  Animation<double> _phase;

  set phase(Animation<double> value) {
    if (_phase == value) return;
    if (attached) _phase.removeListener(markNeedsPaint);
    _phase = value;
    if (attached) _phase.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _phase.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _phase.removeListener(markNeedsPaint);
    super.detach();
  }
}

/// The listening scrubber keeps the stock Slider's value and gesture mapping.
class WavySliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const WavySliderTrackShape({this.phase = kAlwaysDismissedAnimation});

  final Animation<double> phase;

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
    final offsetRadians = 2 * math.pi * phase.value * (rtl ? 1 : -1);
    _drawWave(
      canvas,
      track,
      left,
      thumbCenter.dx - gap,
      paint..color = rtl ? inactive : active,
      rtl ? 1.5 : 3,
      offsetRadians,
    );
    _drawWave(
      canvas,
      track,
      thumbCenter.dx + gap,
      right,
      paint..color = rtl ? active : inactive,
      rtl ? 3 : 1.5,
      offsetRadians,
    );
  }

  void _drawWave(
    Canvas canvas,
    Rect track,
    double start,
    double end,
    Paint paint,
    double amplitude,
    double offsetRadians,
  ) {
    if (end <= start) return;
    const wavelength = 24.0;
    final center = track.center.dy;
    final path = Path()..moveTo(start, center);
    for (var x = start + 2; x < end; x += 2) {
      // Flatten both ends so the wave meets the handle gap cleanly.
      final envelope = math.min(1.0, math.min(x - start, end - x) / 6);
      final angle = (x - track.left) * 2 * math.pi / wavelength + offsetRadians;
      path.lineTo(x, center + amplitude * envelope * math.sin(angle));
    }
    canvas.drawPath(path..lineTo(end, center), paint);
  }
}
