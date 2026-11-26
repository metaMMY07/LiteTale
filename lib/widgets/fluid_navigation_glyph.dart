import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

enum FluidNavSymbol { compass, ribbonBook, history, person }

const fluidNavGlyphSize = 25.0;
const _turnDuration = Duration(milliseconds: 420);
const _turnCurve = Curves.easeInOutCubic;
const _circle = 2 * math.pi;

/// Each mark animates its own geometry within a fixed icon slot. Labels and
/// touch targets don't participate in its paint ticks.
class FluidNavigationGlyph extends StatefulWidget {
  const FluidNavigationGlyph({
    super.key,
    required this.symbol,
    required this.selected,
    required this.color,
  });

  final FluidNavSymbol symbol;
  final bool selected;
  final Animation<Color> color;

  @override
  State<FluidNavigationGlyph> createState() => _FluidNavigationGlyphState();
}

class _FluidNavigationGlyphState extends State<FluidNavigationGlyph>
    with TickerProviderStateMixin {
  // Material 3 Expressive fast spatial spring. Carry velocity when a second
  // selection reverses the book or avatar before its first motion settles.
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 800,
    ratio: .6,
  );
  late final _pose = AnimationController.unbounded(vsync: this, value: _target);
  AnimationController? _turn;
  bool _animate = true;

  double get _target => widget.selected ? 1 : 0;
  bool get _isHistory => widget.symbol == FluidNavSymbol.history;
  bool get _isCompass => widget.symbol == FluidNavSymbol.compass;

  @override
  void initState() {
    super.initState();
    _createTurn();
  }

  void _createTurn() {
    if (_isHistory || _isCompass) {
      _turn = AnimationController(
        vsync: this,
        duration: _turnDuration,
        value: _isHistory ? _target : 1,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context);
    if (!_animate) _settle();
  }

  @override
  void didUpdateWidget(covariant FluidNavigationGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol) {
      _turn?.dispose();
      _turn = null;
      _createTurn();
      _settle();
      return;
    }
    if (widget.selected == oldWidget.selected) return;
    if (!_animate) {
      _settle();
      return;
    }
    if (_isHistory) {
      if (widget.selected) {
        // A nearly invisible arrow can start over. An arrow still on screen
        // resumes its interrupted sweep instead of jumping back to the start.
        if (_pose.value < .02) {
          _turn!.forward(from: 0);
        } else if (_turn!.value < 1) {
          _turn!.forward();
        }
      } else {
        _turn!.stop();
      }
      _pose.animateTo(
        _target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    } else if (_isCompass) {
      // Zero and one are the same angle. Rapid selections finish the active
      // turn rather than resetting the needle mid-flight.
      if (widget.selected && !_turn!.isAnimating) _turn!.forward(from: 0);
    } else {
      _pose.animateWith(
        SpringSimulation(
          _spring,
          _pose.value,
          _target,
          _pose.velocity,
          snapToEnd: true,
          tolerance: const Tolerance(distance: .002, velocity: .04),
        ),
      );
    }
  }

  void _settle() {
    _pose.value = _target;
    _turn?.value = _isHistory ? _target : 1;
  }

  @override
  void dispose() {
    _pose.dispose();
    _turn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: const Size.square(fluidNavGlyphSize),
      painter: _NavigationGlyphPainter(
        widget.symbol,
        _pose,
        _turn,
        widget.color,
      ),
    ),
  );
}

class _NavigationGlyphPainter extends CustomPainter {
  _NavigationGlyphPainter(this.symbol, this.pose, this.turn, this.ink)
    : super(repaint: Listenable.merge([pose, turn, ink]));

  final FluidNavSymbol symbol;
  final Animation<double> pose;
  final Animation<double>? turn;
  final Animation<Color> ink;

  static const _center = Offset(12, 12);
  static const _book = RRect.fromLTRBXY(4.4, 1.6, 19.6, 22.4, 1.8, 1.8);
  static const _clock = Rect.fromLTWH(3.5, 3.5, 17, 17);
  static final _needleNorth =
      Path()
        ..moveTo(5.25, -5.5)
        ..lineTo(2, 1.95)
        ..lineTo(-1.95, -2)
        ..close();
  static final _needleSouth =
      Path()
        ..moveTo(-4.5, 4.75)
        ..lineTo(-1.95, -2)
        ..lineTo(2, 1.95)
        ..close();

  static Paint _fill(Color color, [double opacity = 1]) =>
      Paint()..color = color.withValues(alpha: opacity);

  static Paint _stroke(Color color, [double opacity = 1]) =>
      _fill(color, opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.85
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final selected = pose.value.clamp(0.0, 1.0);
    final sweep = _turnCurve.transform(turn?.value ?? 0);
    final color = ink.value;
    switch (symbol) {
      case FluidNavSymbol.compass:
        canvas.drawCircle(_center, 9.15, _stroke(color));
        canvas.translate(_center.dx, _center.dy);
        canvas.rotate(_circle * sweep);
        canvas.drawPath(_needleSouth, _fill(color, .55));
        canvas.drawPath(_needleNorth, _fill(color));
      case FluidNavSymbol.ribbonBook:
        _paintBook(canvas, color, selected);
      case FluidNavSymbol.history:
        _paintHistory(canvas, color, selected, sweep);
      case FluidNavSymbol.person:
        _paintPerson(canvas, color, selected);
    }
    canvas.restore();
  }

  void _paintBook(Canvas canvas, Color color, double selected) {
    // The cover changes from outline to solid. The ribbon remains a separate
    // shape and lengthens before settling into the cutout in the filled cover.
    final stretch = 4 * selected * (1 - selected);
    final rebound = (pose.value - selected).clamp(-.15, .15);
    final top = lerpDouble(2.55, 4, selected)!;
    final tail = lerpDouble(9.65, 9.1, selected)! + 6 * stretch - 9 * rebound;
    final ribbon =
        Path()
          ..moveTo(9.25, top)
          ..lineTo(14.75, top)
          ..lineTo(14.75, tail)
          ..lineTo(12, tail - 1.9)
          ..lineTo(9.25, tail)
          ..close();
    final solid = Curves.easeOut.transform(
      ((selected - .15) / .65).clamp(0.0, 1.0),
    );
    if (solid > 0) {
      final filledCover =
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRRect(_book)
            ..addPath(ribbon, Offset.zero);
      canvas.drawPath(filledCover, _fill(color, solid));
    }
    canvas.drawRRect(_book.deflate(.9), _stroke(color));
    if (solid < 1) canvas.drawPath(ribbon, _fill(color, 1 - solid));
  }

  void _paintPerson(Canvas canvas, Color color, double selected) {
    final lift = 4 * selected * (1 - selected);
    final rebound = (pose.value - selected).clamp(-.15, .15);
    final head = Rect.fromCenter(
      center: Offset(12, 7.15 - .7 * lift + 3 * rebound),
      width: lerpDouble(5.05, 5.6, selected)! - .65 * lift,
      height: lerpDouble(5.15, 5.7, selected)! + 1.8 * lift,
    );
    final edge = lerpDouble(5.5, 5, selected)! + .7 * lift;
    final bottom = 19.65 + .8 * lift;
    final top = 12.65 + .7 * lift - 3 * rebound;
    final shoulders =
        Path()
          ..moveTo(edge + 1.3, bottom)
          ..quadraticBezierTo(edge, bottom, edge, bottom - 1.3)
          ..lineTo(edge, bottom - 2.65)
          ..cubicTo(edge, top + 1.5, 9.25, top, 12, top)
          ..cubicTo(14.75, top, 24 - edge, top + 1.5, 24 - edge, bottom - 2.65)
          ..lineTo(24 - edge, bottom - 1.3)
          ..quadraticBezierTo(24 - edge, bottom, 24 - edge - 1.3, bottom)
          ..close();
    final fill = Curves.easeOut.transform(
      ((selected - .32) / .64).clamp(0.0, 1.0),
    );
    if (fill > 0) {
      canvas.drawOval(head, _fill(color, fill));
      canvas.drawPath(shoulders, _fill(color, fill));
    }
    canvas.drawOval(head, _stroke(color));
    canvas.drawPath(shoulders, _stroke(color));
  }

  void _paintHistory(
    Canvas canvas,
    Color color,
    double selected,
    double sweep,
  ) {
    if (selected < 1) canvas.drawOval(_clock, _stroke(color, 1 - selected));
    final hands = _stroke(color);
    canvas.drawLine(const Offset(12, 7.35), _center, hands);
    canvas.drawLine(_center, const Offset(15.55, 13.9), hands);
    if (sweep <= 0 || selected <= 0) return;

    // The tip travels the full circle; shorten the trailing end as it comes
    // home so the resting glyph has a visible gap behind the arrowhead.
    const start = math.pi * 1.09;
    final tipAngle = start - _circle * sweep;
    final arc = math.min(_circle * sweep, _circle - .78);
    final stroke = _stroke(color, selected);
    canvas.drawArc(_clock, tipAngle + arc, -arc, false, stroke);

    final normal = Offset(math.cos(tipAngle), math.sin(tipAngle));
    final forward = Offset(normal.dy, -normal.dx);
    final tip = _center + normal * 8.5;
    final back = tip - forward * 3.0;
    final outside = back + normal * 2.2;
    final inside = back - normal * 2.2;
    final arrow =
        Path()
          ..moveTo(outside.dx, outside.dy)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(inside.dx, inside.dy);
    canvas.drawPath(arrow, stroke);
  }

  @override
  bool shouldRepaint(covariant _NavigationGlyphPainter oldDelegate) =>
      oldDelegate.symbol != symbol ||
      oldDelegate.pose != pose ||
      oldDelegate.turn != turn ||
      oldDelegate.ink != ink;
}
