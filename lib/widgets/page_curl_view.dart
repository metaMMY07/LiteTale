import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// PTQFlipper page curl on Android, with a blank, opaque reverse side.
///
/// Reader pages are cached as bitmaps when their content changes. The native
/// component handles touch, geometry and drawing without re-laying out text on
/// every drag frame. Other platforms retain the lightweight reader fallback.
class PageCurlView extends StatefulWidget {
  const PageCurlView({
    super.key,
    required this.pageCount,
    required this.index,
    required this.pageBuilder,
    required this.onPageChanged,
    required this.paperDecoration,
    required this.paperColor,
    this.onCenterTap,
    this.onBoundaryTurn,
  }) : assert(pageCount > 0);

  final int pageCount;
  final int index;
  final IndexedWidgetBuilder pageBuilder;
  final ValueChanged<int> onPageChanged;
  final Decoration paperDecoration;
  final Color paperColor;
  final VoidCallback? onCenterTap;
  final ValueChanged<int>? onBoundaryTurn;

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

  // PTQFlipper owns the actual curl on Android. Flutter pages are rasterized
  // only when pagination changes; no Dart geometry runs on drag frames.
  final Map<int, GlobalKey> _nativeKeys = {};
  final Map<int, Uint8List> _nativePages = {};
  final Set<int> _nativeRequestedPages = {};
  MethodChannel? _nativeChannel;
  bool _nativeReady = false;
  bool _nativeInteractive = false;
  int? _nativeReadyIndex;
  bool _nativeTurning = false;
  int? _nativeOptimisticIndex;
  int? _pendingNativeDirection;
  double? _pendingNativeStartY;
  double _loadingDragDx = 0;
  double _loadingDragStartY = 0;
  bool _nativeCaptureScheduled = false;
  bool _nativeCaptureRunning = false;
  bool _nativeCaptureAgain = false;
  int _nativeCaptureFailures = 0;
  int _nativeGeneration = 0;
  Size? _nativeViewportSize;

  bool get isTurning =>
      Platform.isAndroid
          ? _nativeTurning || _pendingNativeDirection != null
          : _direction != 0 || _settling;

  @visibleForTesting
  bool get isNativeInteractive => _nativeInteractive;

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
    _nativeChannel?.setMethodCallHandler(null);
    _progress.dispose();
    _foldPoint.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PageCurlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!Platform.isAndroid) return;
    final paperChanged =
        widget.paperDecoration != oldWidget.paperDecoration ||
        widget.paperColor != oldWidget.paperColor;
    if (paperChanged || widget.pageCount != oldWidget.pageCount) {
      _nativeGeneration++;
      _nativePages.clear();
      _nativeRequestedPages.clear();
      _nativeReady = false;
      _nativeInteractive = false;
      _nativeReadyIndex = null;
      _nativeOptimisticIndex = null;
      _pendingNativeDirection = null;
      _nativeCaptureFailures = 0;
      _nativeChannel?.setMethodCallHandler(null);
      _nativeChannel = null;
    }
    if (paperChanged ||
        widget.pageCount != oldWidget.pageCount ||
        widget.index != oldWidget.index) {
      if (widget.index != oldWidget.index) {
        _nativeOptimisticIndex = null;
        _nativeInteractive = _nativeReadyIndex == widget.index;
      }
      if (paperChanged || widget.pageCount != oldWidget.pageCount) {
        _nativeTurning = false;
      }
      _nativeChannel?.invokeMethod('setState', _nativeState);
      _scheduleNativeCapture();
    }
  }

  Map<String, Object> get _nativeState => {
    'pageCount': widget.pageCount,
    'index': widget.index,
    'paperColor': widget.paperColor.toARGB32(),
  };

  List<int> get _nativeVisibleIndices {
    // Capturing the current page before its neighbors makes a newly opened
    // book visible immediately. A second page ahead is warmed after the
    // first turn becomes available so rapid forward taps need no PNG readback.
    return <int>{
      widget.index,
      if (_nativeReady && widget.index + 1 < widget.pageCount) widget.index + 1,
      if (_nativeReady && widget.index > 0) widget.index - 1,
      if (_nativeInteractive && widget.index + 2 < widget.pageCount)
        widget.index + 2,
      if (_nativeInteractive && widget.index > 1) widget.index - 2,
      ..._nativeRequestedPages.where(
        (index) => index >= 0 && index < widget.pageCount,
      ),
    }.toList();
  }

  void _scheduleNativeCapture() {
    if (_nativeCaptureScheduled || _nativeCaptureFailures >= 3) return;
    _nativeCaptureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nativeCaptureScheduled = false;
      if (mounted) _captureNativePages();
    });
    // A retry can be scheduled after the last frame has gone idle. Explicitly
    // request another painted frame before reading a RepaintBoundary.
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _captureNativePages() async {
    if (_nativeCaptureRunning) {
      _nativeCaptureAgain = true;
      return;
    }
    _nativeCaptureRunning = true;
    final generation = _nativeGeneration;
    var capturedAny = false;
    try {
      // The platform view is inserted once the current page has been
      // rasterized. Wait for its channel before capturing further pages so
      // none are cached without being delivered to Android.
      if (_nativeReady && _nativeChannel == null) return;
      for (final index in _nativeVisibleIndices) {
        if (!mounted || generation != _nativeGeneration) break;
        if (_nativePages.containsKey(index)) continue;
        final boundary = _nativeKeys[index]?.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary) {
          _nativeCaptureAgain = true;
          continue;
        }
        // toImage asserts if this boundary still has a pending layout/paint.
        // Wait for the next frame instead of treating normal startup as a
        // failed capture (the getter itself is only valid in debug builds).
        var needsFrame = false;
        assert(() {
          needsFrame = boundary.debugNeedsLayout || boundary.debugNeedsPaint;
          return true;
        }());
        if (needsFrame) {
          _nativeCaptureAgain = true;
          continue;
        }
        final ratio = View.of(context).devicePixelRatio;
        final image = await boundary.toImage(pixelRatio: ratio);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) throw StateError('Page image encoding failed');
          if (!mounted || generation != _nativeGeneration) break;
          final bytes = data.buffer.asUint8List();
          _nativePages[index] = bytes;
          capturedAny = true;
          _nativeRequestedPages.remove(index);
          await _nativeChannel?.invokeMethod<void>('setPage', {
            'index': index,
            'bytes': bytes,
          });
          if (!_nativeReady && index == widget.index) {
            setState(() => _nativeReady = true);
            break;
          }
        } finally {
          image.dispose();
        }
      }
      if (!mounted || generation != _nativeGeneration) return;
      _nativeCaptureFailures = 0;
      if (!_nativeReady && _nativePages.containsKey(widget.index)) {
        setState(() => _nativeReady = true);
      }
      if (capturedAny && _nativeReady && _nativeChannel != null) {
        // The PNG is now owned by Android. Remove its low-opacity Flutter
        // duplicate so a drag does not composite several full-screen pages.
        setState(() {});
      }
      // Keep a small window so a reverse turn can reuse the previous PNG.
      _nativePages.removeWhere(
        (index, _) =>
            (index - widget.index).abs() > 3 &&
            !_nativeRequestedPages.contains(index),
      );
    } catch (error) {
      _nativeCaptureFailures++;
      debugPrint('PTQ page capture failed: $error');
      if (_nativeCaptureFailures < 3 && mounted) {
        Future<void>.delayed(const Duration(milliseconds: 40), () {
          if (mounted) _scheduleNativeCapture();
        });
      }
    } finally {
      _nativeCaptureRunning = false;
      if (_nativeCaptureAgain && mounted) {
        _nativeCaptureAgain = false;
        _scheduleNativeCapture();
      }
    }
  }

  Future<void> _turnNative(int direction, {double? startY}) async {
    if (_nativeTurning ||
        _pendingNativeDirection != null ||
        !_canTurn(direction)) {
      return;
    }
    if (_nativeOptimisticIndex != null ||
        !_nativeInteractive ||
        _nativeChannel == null) {
      // On a newly opened book, PNG readback and Android bitmap decoding can
      // take longer than a tap. Show the requested page immediately with the
      // existing Flutter page while the curl cache warms in the background.
      // Once ready, later turns use the native paper animation as usual.
      final target = (_nativeOptimisticIndex ?? widget.index) + direction;
      _nativeOptimisticIndex = target;
      widget.onPageChanged(target);
      return;
    }
    _nativeTurning = true;
    try {
      final accepted = await _nativeChannel!.invokeMethod<bool>('turn', {
        'direction': direction,
        'startY': ((startY ?? _height / 2) / _height).clamp(0.0, 1.0),
      });
      if (accepted == false) {
        _nativeTurning = false;
        final readyIndex = await _nativeChannel!.invokeMethod<int>(
          'getReadyIndex',
        );
        if (mounted && readyIndex != widget.index && _canTurn(direction)) {
          _nativeInteractive = false;
          _pendingNativeDirection = direction;
          _pendingNativeStartY = startY;
          setState(() {});
        }
      }
      // Guard an interrupted native gesture or detached view.
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) _nativeTurning = false;
      });
    } catch (error) {
      _nativeTurning = false;
      debugPrint('PTQ page turn failed: $error');
    }
  }

  void _markNativeReady(int index) {
    _nativeReadyIndex = index;
    if (!mounted || index != widget.index) return;
    if (!_nativeInteractive) setState(() => _nativeInteractive = true);
    final direction = _pendingNativeDirection;
    if (direction == null) return;
    final startY = _pendingNativeStartY;
    _pendingNativeDirection = null;
    _pendingNativeStartY = null;
    // Remove the loading-page overlay before the native tap animation starts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_canTurn(direction)) {
        _turnNative(direction, startY: startY);
      } else {
        widget.onBoundaryTurn?.call(direction);
      }
    });
  }

  void _loadingTurn(int direction, double startY) {
    if (_nativeTurning || _pendingNativeDirection != null) return;
    if (_canTurn(direction)) {
      _turnNative(direction, startY: startY);
    } else {
      widget.onBoundaryTurn?.call(direction);
    }
  }

  void _loadingTap(Offset position) {
    if (position.dx < _width * 0.30 || position.dy < _height * 0.30) {
      _loadingTurn(-1, position.dy);
    } else if (position.dx > _width * 0.70 || position.dy > _height * 0.70) {
      _loadingTurn(1, position.dy);
    } else {
      widget.onCenterTap?.call();
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'turnStarted':
        _nativeTurning = true;
      case 'turnFinished':
        _nativeTurning = false;
      case 'ready':
        _markNativeReady((call.arguments as Map)['index'] as int);
      case 'pageChanged':
        final index = (call.arguments as Map)['index'] as int;
        if (index >= 0 && index < widget.pageCount && index != widget.index) {
          widget.onPageChanged(index);
        }
      case 'turnLimit':
        _nativeTurning = false;
        widget.onBoundaryTurn?.call(
          (call.arguments as Map)['direction'] as int,
        );
      case 'centerTap':
        widget.onCenterTap?.call();
      case 'pageNeeded':
        final index = (call.arguments as Map)['index'] as int;
        if (index >= 0 && index < widget.pageCount) {
          final cached = _nativePages[index];
          if (cached != null && _nativeChannel != null) {
            try {
              await _nativeChannel!.invokeMethod<void>('setPage', {
                'index': index,
                'bytes': cached,
              });
              _nativeRequestedPages.remove(index);
            } catch (error) {
              debugPrint('PTQ cached page restore failed: $error');
              _nativePages.remove(index);
              _nativeRequestedPages.add(index);
              setState(() {});
              _scheduleNativeCapture();
            }
          } else {
            _nativeRequestedPages.add(index);
            setState(() {});
            _scheduleNativeCapture();
          }
        }
    }
  }

  Widget _buildNative(BuildContext context) {
    _scheduleNativeCapture();
    final visible = _nativeVisibleIndices;
    // Native PNGs keep the nearby history; offscreen Flutter page widgets do
    // not need a GlobalKey for every page the reader has ever visited.
    _nativeKeys.removeWhere((index, _) => !visible.contains(index));
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (viewport.width > 0 &&
            viewport.height > 0 &&
            _nativeViewportSize != viewport) {
          // Orientation and window-size changes can happen after the first
          // page was rasterized. Never stretch a portrait PNG across a
          // landscape curl (or keep its expensive stale bitmap cache).
          if (_nativeViewportSize != null) {
            _nativeGeneration++;
            _nativePages.clear();
            _nativeRequestedPages.clear();
            _nativeReady = false;
            _nativeInteractive = false;
            _nativeReadyIndex = null;
            _nativeOptimisticIndex = null;
            _nativeTurning = false;
            _nativeCaptureFailures = 0;
            _nativeChannel?.setMethodCallHandler(null);
            _nativeChannel = null;
          }
          _nativeViewportSize = viewport;
          // LayoutBuilder can rebuild for new constraints without rebuilding
          // PageCurlView itself, so its earlier capture callback has already
          // run. Start a new capture for the resized page explicitly.
          _scheduleNativeCapture();
        }
        _width = constraints.maxWidth;
        _height = constraints.maxHeight;
        final viewGeneration = _nativeGeneration;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final index in visible.where(
              (index) => !_nativePages.containsKey(index),
            ))
              // Keep the boundary painted so toImage can rasterize its page,
              // but keep their composited opacity negligible underneath the
              // native curl. Otherwise text from both layers overlaps at the
              // curved edge (especially with dense landscape typography).
              Opacity(
                opacity: !_nativeReady && index == widget.index ? 1 : 0.01,
                child: RepaintBoundary(
                  key: _nativeKeys.putIfAbsent(index, GlobalKey.new),
                  child: DecoratedBox(
                    decoration: widget.paperDecoration,
                    child: SizedBox.expand(
                      child: widget.pageBuilder(context, index),
                    ),
                  ),
                ),
              ),
            if (_nativeReady)
              AndroidView(
                key: const ValueKey('ptq-curl-android-view'),
                viewType: 'litetale/ptq_curl',
                // Send the full down/move/up stream to PTQ immediately. The
                // default arena policy can wait until pointer-up and turns a
                // live curl into a tap-only animation.
                gestureRecognizers: {
                  Factory<OneSequenceGestureRecognizer>(
                    EagerGestureRecognizer.new,
                  ),
                },
                creationParamsCodec: const StandardMessageCodec(),
                creationParams: _nativeState,
                onPlatformViewCreated: (id) {
                  if (!mounted || viewGeneration != _nativeGeneration) return;
                  final channel = MethodChannel('litetale/ptq_curl/$id');
                  _nativeChannel = channel;
                  channel.setMethodCallHandler(_handleNativeCall);
                  // The reader may have moved to another page while Android
                  // was creating this view. Creation params are a snapshot.
                  unawaited(
                    channel
                        .invokeMethod<void>('setState', _nativeState)
                        .catchError((Object error) {
                          debugPrint('PTQ initial state sync failed: $error');
                        }),
                  );
                  for (final entry in _nativePages.entries) {
                    unawaited(
                      channel
                          .invokeMethod<void>('setPage', {
                            'index': entry.key,
                            'bytes': entry.value,
                          })
                          .catchError((Object error) {
                            debugPrint(
                              'PTQ initial page upload failed: $error',
                            );
                          }),
                    );
                  }
                  _scheduleNativeCapture();
                  unawaited(
                    channel
                        .invokeMethod<int>('getReadyIndex')
                        .then((index) {
                          if (index != null) _markNativeReady(index);
                        })
                        .catchError((Object error) {
                          debugPrint('PTQ readiness query failed: $error');
                        }),
                  );
                },
              ),
            if (!_nativeInteractive)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _loadingTap(details.localPosition),
                  onHorizontalDragStart: (details) {
                    _loadingDragDx = 0;
                    _loadingDragStartY = details.localPosition.dy;
                  },
                  onHorizontalDragUpdate: (details) {
                    _loadingDragDx += details.delta.dx;
                  },
                  onHorizontalDragEnd: (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    // The horizontal recognizer has already crossed touch
                    // slop. Requiring another distance/velocity threshold
                    // here makes short deliberate swipes look ignored.
                    if (_loadingDragDx == 0 && velocity == 0) {
                      return;
                    }
                    _loadingTurn(
                      _loadingDragDx != 0
                          ? (_loadingDragDx < 0 ? 1 : -1)
                          : (velocity < 0 ? 1 : -1),
                      _loadingDragStartY,
                    );
                  },
                  child:
                      _nativeReady
                          ? DecoratedBox(
                            decoration: widget.paperDecoration,
                            child: SizedBox.expand(
                              child: widget.pageBuilder(context, widget.index),
                            ),
                          )
                          : const SizedBox.expand(),
                ),
              ),
          ],
        );
      },
    );
  }

  bool _canTurn(int direction) =>
      direction != 0 &&
      (_nativeOptimisticIndex ?? widget.index) + direction >= 0 &&
      (_nativeOptimisticIndex ?? widget.index) + direction < widget.pageCount;

  Future<void> turn(int direction, {double? startY}) async {
    if (Platform.isAndroid) {
      await _turnNative(direction, startY: startY);
      return;
    }
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
    if (Platform.isAndroid) return _buildNative(context);
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
