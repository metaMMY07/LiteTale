import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The crease rolls across the moving leaf while the page below stays flat.
class ReaderPaperTurnFrame {
  ReaderPaperTurnFrame({
    required this.size,
    required this.progress,
    required this.touchY,
    required this.forward,
    required this.spread,
    required this.paper,
  });

  final Size size;
  final double progress, touchY;
  final bool forward, spread;
  final Color paper;

  double get _sign => forward ? 1 : -1;
  double get _width => spread ? size.width / 2 : size.width;
  double get _spine =>
      spread
          ? _width
          : forward
          ? 0
          : size.width;
  double get _lift => math.sin(math.pi * progress);
  double get _radius => .085 * _width * _lift;
  bool get _bending => progress > 0 && progress < 1 && !size.isEmpty;

  double _crease(double y) {
    final grip = touchY - .5;
    final skew = .32 * grip * (.5 - y) + .025 * (y - touchY) * (y - touchY);
    return (_width * (1 - progress + skew * _lift)).clamp(0.0, _width);
  }

  double _faceEdge(double crease) =>
      math.min(_width, crease + math.pi * _radius / 2);

  late final _PaperMesh _front = _mesh(back: false);
  late final _PaperMesh? _back =
      _faceEdge(_crease(0)) < _width ||
              _faceEdge(_crease(touchY)) < _width ||
              _faceEdge(_crease(1)) < _width
          ? _mesh(back: true)
          : null;

  static const _segments = 24;
  static const _rows = 4;
  static const _stride = _segments + 1;
  static final _indices = Uint16List.fromList([
    for (var row = 0; row < _rows; row++)
      for (var col = 0; col < _segments; col++) ...[
        row * _stride + col,
        row * _stride + col + 1,
        (row + 1) * _stride + col,
        row * _stride + col + 1,
        (row + 1) * _stride + col + 1,
        (row + 1) * _stride + col,
      ],
  ]);

  _PaperMesh _mesh({required bool back}) {
    final positions = Float32List(2 * _stride * (_rows + 1));
    final coordinates = Float32List(positions.length);
    final lighting = Int32List(positions.length ~/ 2);
    final outline = Path();
    final radius = _radius;
    final arc = math.pi * radius;
    for (var row = 0; row <= _rows; row++) {
      final v = row / _rows;
      final crease = _crease(v);
      final edge = _faceEdge(crease);
      final start = back ? edge : 0.0;
      final end = back ? _width : edge;
      for (var column = 0; column <= _segments; column++) {
        final u = start + (end - start) * column / _segments;
        final curl = math.max(0.0, u - crease);
        final angle = math.min(math.pi, curl / radius);
        // A flat front runs into a semicircle. The reverse side returns from
        // the other end of the arc, so the ink stays attached to the sheet.
        final x =
            math.min(u, crease) +
            radius * math.sin(angle) -
            math.max(0.0, curl - arc);
        final gray =
            (255 * (1 - (1 - math.cos(angle).abs()) * .20 * _lift)).round();
        final xTexture = _spine + (back && spread ? -_sign : _sign) * u;
        final vertex = column + row * _stride;
        final index = 2 * vertex;
        positions[index] = _spine + _sign * x;
        positions[index + 1] = v * size.height;
        coordinates[index] = xTexture / size.width;
        coordinates[index + 1] = v;
        lighting[vertex] =
            Color.fromARGB(
              back && !spread ? 19 : 255,
              gray,
              gray,
              gray,
            ).toARGB32();
      }
    }
    void edgeTo(int row, int col) {
      final point = 2 * (row * _stride + col);
      outline.lineTo(positions[point], positions[point + 1]);
    }

    outline.moveTo(positions[0], positions[1]);
    for (var col = 1; col <= _segments; col++) {
      edgeTo(0, col);
    }
    for (var row = 1; row <= _rows; row++) {
      edgeTo(row, _segments);
    }
    for (var col = _segments - 1; col >= 0; col--) {
      edgeTo(_rows, col);
    }
    for (var row = _rows - 1; row > 0; row--) {
      edgeTo(row, 0);
    }
    outline.close();
    return _PaperMesh(positions, coordinates, lighting, outline);
  }
}

class _PaperMesh {
  const _PaperMesh(
    this.positions,
    this.coordinates,
    this.lighting,
    this.outline,
  );

  final Float32List positions, coordinates;
  final Int32List lighting;
  final Path outline;
}

/// Retains the live page at rest and captures at most one snapshot per leaf
/// during a turn. The snapshot contains the same text and images as that leaf.
class ReaderPaperTurn extends StatefulWidget {
  const ReaderPaperTurn({
    super.key,
    required this.frame,
    required this.outgoing,
    required this.child,
  });

  final ReaderPaperTurnFrame? frame;
  final bool outgoing;
  final Widget child;

  @override
  State<ReaderPaperTurn> createState() => _ReaderPaperTurnState();
}

class _ReaderPaperTurnState extends State<ReaderPaperTurn> {
  final _snapshot = SnapshotController();
  final _painter = _PaperTurnPainter();

  void _update() {
    final frame = widget.frame;
    _snapshot.allowSnapshotting =
        frame != null && (widget.outgoing || frame.spread);
    _painter.update(frame, widget.outgoing);
  }

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(ReaderPaperTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.child, oldWidget.child)) _snapshot.clear();
    _update();
  }

  @override
  void dispose() {
    _snapshot.dispose();
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _snapshot,
    painter: _painter,
    mode: SnapshotMode.permissive,
    autoresize: true,
    child: widget.child,
  );
}

class _PaperTurnPainter extends SnapshotPainter {
  ReaderPaperTurnFrame? _frame;
  bool _outgoing = false;
  ui.Image? _image;
  ui.ImageShader? _shader;

  @override
  bool shouldRepaint(SnapshotPainter oldPainter) => oldPainter != this;

  void update(ReaderPaperTurnFrame? frame, bool outgoing) {
    if (identical(frame, _frame) && outgoing == _outgoing) return;
    _frame = frame;
    _outgoing = outgoing;
    if (frame == null) _releaseTexture();
    notifyListeners();
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    final frame = _frame;
    if (frame == null || !_outgoing || frame.progress <= 0) {
      painter(context, offset);
    } else if (frame.progress < 1) {
      // A platform view cannot be captured. Keep that page's live painting.
      painter(
        context,
        offset.translate(-frame._sign * frame.progress * size.width, 0),
      );
    }
  }

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final frame = _frame;
    final canvas = context.canvas;
    final target = Offset.zero & size;
    final source = Offset.zero & sourceSize;
    final paint = Paint()..filterQuality = FilterQuality.low;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    if (frame == null || !frame._bending) {
      if (!_outgoing || frame == null || frame.progress < 1) {
        canvas.drawImageRect(image, source, target, paint);
      }
      canvas.restore();
      return;
    }
    if (!_outgoing) {
      canvas.drawImageRect(image, source, target, paint);
      if (frame._back case final reverse?) {
        _face(canvas, reverse, image, sourceSize, frame.paper);
      }
      canvas.restore();
      return;
    }

    final front = frame._front;
    final back = frame._back;
    if (frame.spread) {
      final stationary = Rect.fromLTWH(
        frame.forward ? 0 : frame._spine,
        0,
        frame._width,
        size.height,
      );
      canvas.save();
      canvas.clipPath(_withoutBack(Path()..addRect(stationary), back));
      canvas.drawImageRect(image, source, target, paint);
      canvas.restore();
    }

    final shadow =
        Paint()
          ..color = const Color(0xff000000).withValues(alpha: .22 * frame._lift)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            12 * frame._lift + 2,
          );
    canvas.drawPath(
      (back?.outline ?? front.outline).shift(Offset(frame._sign * 8, 0)),
      shadow,
    );
    canvas.save();
    canvas.clipPath(_withoutBack(front.outline, back));
    _face(canvas, front, image, sourceSize, frame.paper);
    canvas.restore();
    if (back != null && !frame.spread) {
      _face(canvas, back, image, sourceSize, frame.paper);
    }
    canvas.restore();
  }

  Path _withoutBack(Path path, _PaperMesh? back) =>
      back == null
          ? path
          : Path.combine(PathOperation.difference, path, back.outline);

  void _face(
    Canvas canvas,
    _PaperMesh mesh,
    ui.Image image,
    Size source,
    Color paper,
  ) {
    if (!identical(image, _image)) {
      _releaseTexture();
      _image = image;
      _shader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
      );
    }
    final texture = Float32List(mesh.coordinates.length);
    for (var i = 0; i < texture.length; i += 2) {
      texture[i] = mesh.coordinates[i] * source.width;
      texture[i + 1] = mesh.coordinates[i + 1] * source.height;
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      mesh.positions,
      textureCoordinates: texture,
      colors: mesh.lighting,
      indices: ReaderPaperTurnFrame._indices,
    );
    canvas.drawPath(mesh.outline, Paint()..color = paper);
    canvas.drawVertices(
      vertices,
      BlendMode.modulate,
      Paint()..shader = _shader,
    );
    vertices.dispose();
  }

  void _releaseTexture() {
    _shader?.dispose();
    _shader = null;
    _image = null;
  }

  @override
  void dispose() {
    _releaseTexture();
    super.dispose();
  }
}
