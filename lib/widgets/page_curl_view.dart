import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A reader page turn with a blank, opaque reverse side.
///
/// The fold uses both the drag's initial height and its current position.
/// Children stay in repaint boundaries while a drag only updates the clip
/// and painting geometry; the caller owns the committed page index.
class PageCurlView extends StatefulWidget {
  const PageCurlView({
    super.key,
    required this.pageCount,
    required this.index,
    required this.pageBuilder,
    required this.onPageChanged,
    required this.paperDecoration,
    required this.paperColor,
  }) : assert(pageCount > 0);

  final int pageCount;
  final int index;
  final IndexedWidgetBuilder pageBuilder;
  final ValueChanged<int> onPageChanged;
  final Decoration paperDecoration;
  final Color paperColor;

  @override
  State<PageCurlView> createState() => PageCurlViewState();
}

class PageCurlViewState extends State<PageCurlView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  final ValueNotifier<Offset> _foldPoint = ValueNotifier(const Offset(0, 0.5));
  int _direction = 0;
  double _startX = 0;
  double _lastX = 0;
  double _startY = 0.5;
  double _width = 1;
  double _height = 1;
  bool _settling = false;

  bool get isTurning => _direction != 0 || _settling;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )..addListener(() {
      _foldPoint.value = Offset(_progress.value, _foldPoint.value.dy);
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    _foldPoint.dispose();
    super.dispose();
  }

  bool _canTurn(int direction) =>
      direction != 0 &&
      widget.index + direction >= 0 &&
      widget.index + direction < widget.pageCount;

  Future<void> turn(int direction, {double? startY}) async {
    if (isTurning || !_canTurn(direction)) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      widget.onPageChanged(widget.index + direction);
      return;
    }
    _startY = ((startY ?? _height / 2) / _height).clamp(0.0, 1.0);
    _foldPoint.value = Offset(0, _startY);
    setState(() => _direction = direction);
    _progress.value = 0;
    await _settle(true);
  }

  void _dragDown(DragDownDetails details) {
    if (isTurning) return;
    _startX = details.localPosition.dx;
    _lastX = _startX;
    _startY = (details.localPosition.dy / _height).clamp(0.0, 1.0);
  }

  void _startDrag(DragStartDetails details) {
    if (isTurning) return;
    _foldPoint.value = Offset(0, _startY);
  }

  void _updateDrag(DragUpdateDetails details) {
    if (_settling) return;
    if (_direction == 0) {
      if (details.delta.dx == 0) return;
      final direction = details.delta.dx < 0 ? 1 : -1;
      if (!_canTurn(direction)) return;
      setState(() => _direction = direction);
    }
    final distance = (details.localPosition.dx - _startX) * -_direction;
    _lastX = details.localPosition.dx;
    _foldPoint.value = Offset(
      (distance / _width).clamp(0.0, 1.0),
      (details.localPosition.dy / _height).clamp(0.0, 1.0),
    );
  }

  void _endDrag(DragEndDetails details) {
    if (_direction == 0 || _settling) return;
    final directionalVelocity = -(details.primaryVelocity ?? 0) * _direction;
    final crossedMiddle =
        _direction > 0 ? _lastX < _width / 2 : _lastX > _width / 2;
    _settle(crossedMiddle || directionalVelocity > 650);
  }

  Future<void> _settle(bool commit) async {
    if (_settling || _direction == 0) return;
    _settling = true;
    final destination = commit ? 1.0 : 0.0;
    _progress.value = _foldPoint.value.dx;
    final remaining = (destination - _progress.value).abs();
    final milliseconds = (310 * remaining).round().clamp(80, 310);
    try {
      await _progress.animateTo(
        destination,
        duration: Duration(milliseconds: milliseconds),
        curve: Curves.easeOutCubic,
      );
    } on TickerCanceled {
      return;
    }
    if (!mounted) return;
    final nextIndex = widget.index + _direction;
    if (commit && nextIndex >= 0 && nextIndex < widget.pageCount) {
      widget.onPageChanged(nextIndex);
    }
    setState(() {
      _direction = 0;
      _progress.value = 0;
      _foldPoint.value = const Offset(0, 0.5);
      _settling = false;
    });
  }

  Widget _paper(BuildContext context, int index) => RepaintBoundary(
    child: DecoratedBox(
      decoration: widget.paperDecoration,
      child: SizedBox.expand(child: widget.pageBuilder(context, index)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        _height = constraints.maxHeight;
        final target = widget.index + _direction;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragDown: _dragDown,
          onHorizontalDragStart: _startDrag,
          onHorizontalDragUpdate: _updateDrag,
          onHorizontalDragEnd: _endDrag,
          onHorizontalDragCancel: () => _settle(false),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_direction == 0)
                _paper(context, widget.index)
              else ...[
                _paper(context, target),
                ClipPath(
                  clipper: _FoldClipper(_foldPoint, _direction, _startY),
                  child: _paper(context, widget.index),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _FoldPainter(
                      _foldPoint,
                      _direction,
                      _startY,
                      widget.paperColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _FoldGeometry {
  _FoldGeometry(Size size, Offset point, this.direction, double startY)
    : width = size.width,
      height = size.height,
      progress = point.dx.clamp(0.0, 1.0) {
    final wave = math.sin(math.pi * progress);
    final anchor = _edgeAnchor(startY.clamp(0.0, 1.0));
    final verticalPull = (point.dy.clamp(0.0, 1.0) - anchor) * height * wave;
    final horizontalPull = math.max(width * 0.2, width * 2 * progress);

    // Approximate the perpendicular bisector between a point on the right
    // edge and the finger. Its tilt changes with both the starting height and
    // the finger's current y. Tapering the vertical pull at both ends lets the
    // page settle into an entirely flat first/last frame.
    seam =
        width * (1 - progress) -
        verticalPull * verticalPull / (2 * horizontalPull);
    tilt = (verticalPull / horizontalPull).clamp(-0.72, 0.72);
    bend = width * 0.035 * wave;
    final widthAtMiddle = width * 0.19 * wave;
    final bias = (0.5 - startY) * 1.1;
    backTopWidth = widthAtMiddle * (1 + bias);
    backBottomWidth = widthAtMiddle * (1 - bias);
    shadowWidth = width * 0.045 * wave;
    anchorPixels = anchor * height;
  }

  final double width;
  final double height;
  final double progress;
  final int direction;
  late final double seam;
  late final double tilt;
  late final double bend;
  late final double backTopWidth;
  late final double backBottomWidth;
  late final double shadowWidth;
  late final double anchorPixels;

  static double _smooth(double value) => value * value * (3 - 2 * value);

  // Top and bottom starts peel their respective corners. The transition to a
  // middle, nearly vertical fold is continuous rather than a sudden snap.
  static double _edgeAnchor(double startY) {
    if (startY < 0.45) {
      final t = ((startY - 0.22) / 0.23).clamp(0.0, 1.0);
      return startY * _smooth(t);
    }
    if (startY > 0.55) {
      final t = ((startY - 0.55) / 0.23).clamp(0.0, 1.0);
      return startY + (1 - startY) * _smooth(t);
    }
    return startY;
  }

  double _edgeX(double fraction) =>
      seam +
      tilt * (fraction * height - anchorPixels) -
      bend * math.sin(math.pi * fraction);

  double _backWidth(double fraction) =>
      backTopWidth + (backBottomWidth - backTopWidth) * fraction;

  void _traceEdge(
    Path path, {
    double Function(double)? offset,
    bool reverse = false,
  }) {
    if (reverse) {
      for (var i = 15; i >= 0; i--) {
        final fraction = i / 16;
        path.lineTo(
          _edgeX(fraction) + (offset?.call(fraction) ?? 0),
          height * fraction,
        );
      }
    } else {
      for (var i = 1; i <= 16; i++) {
        final fraction = i / 16;
        path.lineTo(
          _edgeX(fraction) + (offset?.call(fraction) ?? 0),
          height * fraction,
        );
      }
    }
  }

  Path _orient(Path path) {
    if (direction > 0) return path;
    return path.transform(
      (Matrix4.identity()
            ..translate(width, 0.0)
            ..scale(-1.0, 1.0))
          .storage,
    );
  }

  Path get front {
    final path =
        Path()
          ..moveTo(0, 0)
          ..lineTo(_edgeX(0), 0);
    _traceEdge(path);
    path
      ..lineTo(0, height)
      ..close();
    return _orient(path);
  }

  Path get back {
    final path = Path()..moveTo(_edgeX(0), 0);
    _traceEdge(path);
    path.lineTo(_edgeX(1) + backBottomWidth, height);
    _traceEdge(path, offset: _backWidth, reverse: true);
    path.close();
    return _orient(path);
  }

  Path get frontShadow {
    final path =
        Path()
          ..moveTo(_edgeX(0) - shadowWidth, 0)
          ..lineTo(_edgeX(0), 0);
    _traceEdge(path);
    path.lineTo(_edgeX(1) - shadowWidth, height);
    _traceEdge(path, offset: (_) => -shadowWidth, reverse: true);
    path.close();
    return _orient(path);
  }
}

class _FoldClipper extends CustomClipper<Path> {
  _FoldClipper(this.point, this.direction, this.startY) : super(reclip: point);

  final ValueNotifier<Offset> point;
  final int direction;
  final double startY;

  @override
  Path getClip(Size size) {
    return _FoldGeometry(size, point.value, direction, startY).front;
  }

  @override
  bool shouldReclip(covariant _FoldClipper oldClipper) =>
      direction != oldClipper.direction ||
      startY != oldClipper.startY ||
      point != oldClipper.point;
}

class _FoldPainter extends CustomPainter {
  _FoldPainter(this.point, this.direction, this.startY, this.paperColor)
    : super(repaint: point);

  final ValueNotifier<Offset> point;
  final int direction;
  final double startY;
  final Color paperColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fold = _FoldGeometry(size, point.value, direction, startY);
    if (fold.progress <= 0 || fold.progress >= 1) return;
    // Shade only the narrow front crease; the folded reverse is a direct,
    // fully opaque paint operation. No page bitmap or text is drawn on it.
    canvas.drawPath(
      fold.frontShadow,
      Paint()..color = Colors.black.withValues(alpha: 0.11),
    );
    final opaquePaper = paperColor.withValues(alpha: 1);
    final shadeTarget =
        opaquePaper.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    canvas.drawPath(
      fold.back,
      Paint()
        ..color = Color.lerp(
          opaquePaper,
          shadeTarget,
          0.045,
        )!.withValues(alpha: 1),
    );
  }

  @override
  bool shouldRepaint(covariant _FoldPainter oldDelegate) =>
      direction != oldDelegate.direction ||
      startY != oldDelegate.startY ||
      paperColor != oldDelegate.paperColor ||
      point != oldDelegate.point;
}
