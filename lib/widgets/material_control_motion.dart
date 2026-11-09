import 'dart:math' as math;

import 'package:flutter/material.dart';

const _pressDuration = Duration(milliseconds: 120);
const _stateDuration = Duration(milliseconds: 200);
const _easeOut = Cubic(.23, 1, .32, 1);

enum MaterialReaderMotion { catalog, settings }

/// A Material button owns the gesture, state layer, focus and callback. Its
/// glyph moves within the original hit area and never holds up navigation.
class MaterialReaderMotionButton extends StatefulWidget {
  const MaterialReaderMotionButton({
    super.key,
    required this.motion,
    required this.label,
    required this.onPressed,
  });

  final MaterialReaderMotion motion;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<MaterialReaderMotionButton> createState() =>
      _MaterialReaderMotionButtonState();
}

class _MaterialReaderMotionButtonState extends State<MaterialReaderMotionButton>
    with SingleTickerProviderStateMixin {
  final _states = WidgetStatesController();
  late final _motion = AnimationController(vsync: this);
  bool _enabled = false;
  bool _pressed = false;
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_pressChanged);
    _motion.addStatusListener((status) {
      if (status == AnimationStatus.completed && _confirmed) _atPeak();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled =
        !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context);
    if (!_enabled) {
      _confirmed = false;
      _motion.value = 0;
    }
  }

  void _pressChanged() {
    final pressed = _states.value.contains(WidgetState.pressed);
    if (_pressed == pressed) return;
    _pressed = pressed;
    if (!_enabled) return;
    if (pressed) {
      _confirmed = false;
      _moveTo(1);
    } else if (!_confirmed) {
      _moveTo(0);
    }
  }

  void _moveTo(double target) {
    _motion.animateTo(target, duration: _pressDuration, curve: _easeOut);
  }

  void _atPeak() {
    _confirmed = false;
    if (!_pressed) _moveTo(0);
  }

  void _activate() {
    if (_enabled) {
      _confirmed = true;
      if (_motion.value == 1) {
        _atPeak();
      } else {
        _moveTo(1);
      }
    }
    widget.onPressed?.call();
  }

  @override
  void dispose() {
    _states.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.label,
    child: FilledButton.tonal(
      statesController: _states,
      onPressed: widget.onPressed == null ? null : _activate,
      style: FilledButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        shape: const CircleBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: _MotionGlyph(
        animation: _motion,
        glyph: switch (widget.motion) {
          MaterialReaderMotion.catalog => _Glyph.catalog,
          MaterialReaderMotion.settings => _Glyph.settings,
        },
      ),
    ),
  );
}

/// Fills the ribbon only when the actual bookshelf state changes.
class MaterialBookmarkGlyph extends StatefulWidget {
  const MaterialBookmarkGlyph({super.key, required this.selected});

  final bool selected;

  @override
  State<MaterialBookmarkGlyph> createState() => _MaterialBookmarkGlyphState();
}

class _MaterialBookmarkGlyphState extends State<MaterialBookmarkGlyph>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      _motion.value = widget.selected ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant MaterialBookmarkGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) return;
    final target = widget.selected ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      _motion.value = target;
    } else {
      _motion.animateTo(target, duration: _stateDuration, curve: _easeOut);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _MotionGlyph(animation: _motion, glyph: _Glyph.bookmark);
}

enum _Glyph { bookmark, catalog, settings }

class _MotionGlyph extends StatelessWidget {
  const _MotionGlyph({required this.animation, required this.glyph});

  final Animation<double> animation;
  final _Glyph glyph;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(
          animation,
          glyph,
          theme.color ?? Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.motion, this.glyph, this.color) : super(repaint: motion);

  final Animation<double> motion;
  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final fill = Paint()..color = color;
    final stroke =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round;
    final p = motion.value;
    switch (glyph) {
      case _Glyph.bookmark:
        final tail = 20.2 + 1.1 * math.sin(p * math.pi);
        final ribbon =
            Path()
              ..moveTo(7, 4)
              ..lineTo(17, 4)
              ..quadraticBezierTo(18, 4, 18, 5)
              ..lineTo(18, tail)
              ..lineTo(12, tail - 3.4)
              ..lineTo(6, tail)
              ..lineTo(6, 5)
              ..quadraticBezierTo(6, 4, 7, 4)
              ..close();
        if (p > 0) {
          canvas.save();
          canvas.clipRect(Rect.fromLTRB(0, 0, 24, 4 + (tail - 4) * p));
          canvas.drawPath(ribbon, fill);
          canvas.restore();
        }
        canvas.drawPath(ribbon, stroke);
      case _Glyph.catalog:
        for (var row = 0; row < 3; row++) {
          final y = 6.0 + row * 6;
          final step =
              row == 0 ? 0.0 : ((p - (row - 1) * .24) / .76).clamp(0.0, 1.0);
          final dx = 3.0 * step;
          canvas.drawCircle(Offset(4.5 + dx, y), 1.2, fill);
          canvas.drawLine(Offset(8.5 + dx, y), Offset(20.5, y), stroke);
        }
      case _Glyph.settings:
        canvas.translate(12, 12);
        canvas.save();
        canvas.rotate(p * math.pi / 4);
        canvas.drawPath(_gear, stroke);
        canvas.restore();
        canvas.drawCircle(Offset.zero, 2.7 - p * .35, stroke);
    }
    canvas.restore();
  }

  static final Path _gear = () {
    final path = Path();
    const step = math.pi / 4;
    const tooth = [
      (-.5, 7.1),
      (-.27, 7.1),
      (-.16, 9.2),
      (.16, 9.2),
      (.27, 7.1),
    ];
    for (var i = 0; i < 8; i++) {
      for (var point = 0; point < tooth.length; point++) {
        final (phase, radius) = tooth[point];
        final angle = (i + phase) * step - math.pi / 2;
        final x = math.cos(angle) * radius, y = math.sin(angle) * radius;
        if (i == 0 && point == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
    }
    return path..close();
  }();

  @override
  bool shouldRepaint(covariant _GlyphPainter oldDelegate) =>
      oldDelegate.motion != motion ||
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color;
}
