import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'reader_raster_readiness.dart';

class CurlMeshData {
  CurlMeshData(
    this.front,
    this.uv,
    this.frontColors,
    this.back,
    this.backColors,
  );
  final Float32List front, uv, back;
  final Int32List frontColors, backColors;
}

/// An opaque sheet wrapped around a cylinder. Its front keeps the original
/// texture coordinates; the reverse has only paper and light, never glyphs.
CurlMeshData createCurlMesh({
  required Size size,
  required double progress,
  required double startY,
  required double dragY,
  required int direction,
  required bool spread,
  required Color paper,
}) {
  const columns = 64, rows = 64;
  const capacity = columns * rows * 6;
  final front = Float32List(capacity * 2), uv = Float32List(capacity * 2);
  final back = Float32List(capacity * 2);
  final fc = Int32List(capacity), bc = Int32List(capacity);
  var nf = 0, nb = 0;
  final t = progress.clamp(0.0, 1.0);
  final leaf = size.width / (spread ? 2 : 1), offset = spread ? leaf : 0.0;
  final radius = math.max(
    1.0,
    math.min(leaf * .12, leaf * .2 * math.sin(math.pi * t)),
  );
  final bend = leaf * (1 - t) - radius * .8;
  final tilt = (((startY - .5) * 1.1 + (dragY - startY) * .45) *
          math.sin(math.pi * t))
      .clamp(-.6, .6);
  final nx = math.cos(tilt), ny = math.sin(tilt), cy = size.height * startY;
  final red = (paper.toARGB32() >> 16) & 255;
  final green = (paper.toARGB32() >> 8) & 255;
  final blue = paper.toARGB32() & 255;
  ({double x, double y, double u, double v, double normal}) point(
    int col,
    int row,
  ) {
    final x = leaf * col / columns, y = size.height * row / rows;
    final d = (x - bend) * nx + (y - cy) * ny;
    final tangent = -(x - bend) * ny + (y - cy) * nx;
    var mapped = d, z = 0.0, normal = 1.0;
    if (d > 0) {
      final angle = math.min(math.pi, d / radius);
      mapped =
          d < math.pi * radius
              ? radius * math.sin(angle)
              : -(d - math.pi * radius);
      z = radius * (1 - math.cos(angle));
      normal = math.cos(angle);
    }
    var px = bend + nx * mapped - ny * tangent;
    var py = cy + ny * mapped + nx * tangent;
    final perspective = 1 - z / (math.max(size.width, size.height) * 3);
    px = (px + offset - size.width / 2) * perspective + size.width / 2;
    py = (py - size.height / 2) * perspective + size.height / 2;
    return (
      x: direction > 0 ? px : size.width - px,
      y: py,
      u: direction > 0 ? x + offset : size.width - x - offset,
      v: y,
      normal: normal,
    );
  }

  void triangle(
    ({double x, double y, double u, double v, double normal}) a,
    ({double x, double y, double u, double v, double normal}) b,
    ({double x, double y, double u, double v, double normal}) c,
  ) {
    final isFront = a.normal + b.normal + c.normal >= 0;
    for (final p in [a, b, c]) {
      if (isFront) {
        front[nf * 2] = p.x;
        front[nf * 2 + 1] = p.y;
        uv[nf * 2] = p.u;
        uv[nf * 2 + 1] = p.v;
        final light = (255 * (.88 + .12 * math.max(0, p.normal))).round();
        fc[nf++] = 0xff000000 | light << 16 | light << 8 | light;
      } else {
        back[nb * 2] = p.x;
        back[nb * 2 + 1] = p.y;
        final light = .87 + .11 * p.normal.abs();
        bc[nb++] =
            0xff000000 |
            (red * light).round() << 16 |
            (green * light).round() << 8 |
            (blue * light).round();
      }
    }
  }

  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < columns; col++) {
      final a = point(col, row),
          b = point(col + 1, row),
          c = point(col + 1, row + 1),
          d = point(col, row + 1);
      triangle(a, b, c);
      triangle(a, c, d);
    }
  }
  return CurlMeshData(
    Float32List.sublistView(front, 0, nf * 2),
    Float32List.sublistView(uv, 0, nf * 2),
    Int32List.sublistView(fc, 0, nf),
    Float32List.sublistView(back, 0, nb * 2),
    Int32List.sublistView(bc, 0, nb),
  );
}

class CurlMeshLayer extends StatefulWidget {
  const CurlMeshLayer({
    super.key,
    required this.index,
    required this.target,
    required this.direction,
    required this.startY,
    required this.point,
    required this.spread,
    required this.paper,
    required this.pageBuilder,
  });
  final int index, target, direction;
  final double startY;
  final ValueNotifier<Offset> point;
  final bool spread;
  final Color paper;
  final IndexedWidgetBuilder pageBuilder;
  @override
  State<CurlMeshLayer> createState() => CurlMeshLayerState();
}

class CurlMeshLayerState extends State<CurlMeshLayer> {
  final _key = GlobalKey();
  late final ReaderRasterReadiness _ready = ReaderRasterReadiness(
    onChanged: _schedule,
  );
  ui.Image? _image;
  ui.ImageShader? _shader;
  bool _scheduled = false;
  Future<void>? _capture;
  int _generation = 0;
  Size? _size;
  void _clear() {
    _generation++;
    _shader?.dispose();
    _shader = null;
    _image?.dispose();
    _image = null;
  }

  @override
  void didUpdateWidget(CurlMeshLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.paper != widget.paper ||
        oldWidget.spread != widget.spread) {
      _clear();
    }
    _schedule();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _schedule() {
    if (!mounted || _scheduled || _image != null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) capture();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> capture() =>
      _capture ??= _capturePage().whenComplete(() {
        _capture = null;
      });
  Future<void> _capturePage() async {
    if (!_ready.isReady || _image != null) return;
    final boundary = _key.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.hasSize ||
        boundary.debugNeedsPaint) {
      return;
    }
    final generation = _generation, revision = _ready.revision;
    final pixels = boundary.size.width * boundary.size.height;
    final ratio = math.min(
      MediaQuery.devicePixelRatioOf(context),
      math.sqrt(4000000 / pixels),
    );
    try {
      final image = await boundary.toImage(pixelRatio: ratio);
      if (!mounted ||
          generation != _generation ||
          !_ready.isReady ||
          revision != _ready.revision) {
        image.dispose();
        if (mounted) _schedule();
        return;
      }
      final identity =
          Float64List(16)
            ..[0] = 1
            ..[5] = 1
            ..[10] = 1
            ..[15] = 1;
      final shader = ui.ImageShader(
        image,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        identity,
      );
      setState(() {
        _image = image;
        _shader = shader;
      });
    } catch (_) {
      /* A new viewport will request a fresh painted boundary. */
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (_size != box.biggest) {
        _clear();
        _size = box.biggest;
      }
      _schedule();
      return Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _key,
            child: ReaderRasterScope(
              readiness: _ready,
              child: widget.pageBuilder(context, widget.index),
            ),
          ),
          if (widget.direction != 0 && _image != null) ...[
            widget.pageBuilder(context, widget.target),
            IgnorePointer(
              child: CustomPaint(
                painter: _MeshPainter(
                  widget.point,
                  image: _image!,
                  shader: _shader!,
                  direction: widget.direction,
                  startY: widget.startY,
                  spread: widget.spread,
                  paper: widget.paper,
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _MeshPainter extends CustomPainter {
  _MeshPainter(
    this.point, {
    required this.image,
    required this.shader,
    required this.direction,
    required this.startY,
    required this.spread,
    required this.paper,
  }) : super(repaint: point);
  final ValueNotifier<Offset> point;
  final ui.Image image;
  final ui.ImageShader shader;
  final int direction;
  final double startY;
  final bool spread;
  final Color paper;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    if (spread) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          direction > 0 ? 0 : size.width / 2,
          0,
          size.width / 2,
          size.height,
        ),
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
      canvas.restore();
    }
    final mesh = createCurlMesh(
      size: size,
      progress: point.value.dx,
      startY: startY,
      dragY: point.value.dy,
      direction: direction,
      spread: spread,
      paper: paper,
    );
    for (var i = 0; i < mesh.uv.length; i += 2) {
      mesh.uv[i] *= image.width / size.width;
      mesh.uv[i + 1] *= image.height / size.height;
    }
    if (mesh.front.isNotEmpty) {
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        mesh.front,
        textureCoordinates: mesh.uv,
        colors: mesh.frontColors,
      );
      canvas.drawVertices(
        vertices,
        BlendMode.modulate,
        Paint()
          ..shader = shader
          ..filterQuality = FilterQuality.low,
      );
      vertices.dispose();
    }
    if (mesh.back.isNotEmpty) {
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        mesh.back,
        colors: mesh.backColors,
      );
      canvas.drawVertices(
        vertices,
        BlendMode.modulate,
        Paint()..color = Colors.white,
      );
      vertices.dispose();
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.image != image ||
      old.direction != direction ||
      old.startY != startY ||
      old.spread != spread ||
      old.paper != paper;
}
