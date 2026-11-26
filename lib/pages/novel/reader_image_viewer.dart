import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:photo_view/photo_view.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

typedef ReaderImageFrame = ({ImageProvider provider, Size size});
typedef ReaderImageOrigin = ({Rect rect, Size viewport});

Future<void> openReaderImage(
  BuildContext context,
  ReaderImageRef image, {
  ReaderImageOrigin? origin,
  ReaderImageFrame? frame,
}) => Navigator.of(context).push<void>(
  PageRouteBuilder<void>(
    opaque: false,
    allowSnapshotting: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder:
        (_, _, _) =>
            ReaderImageViewer(image: image, origin: origin, frame: frame),
  ),
);

class ReaderImageViewer extends StatefulWidget {
  const ReaderImageViewer({
    super.key,
    required this.image,
    this.repository,
    this.origin,
    this.frame,
  });
  final ReaderImageRef image;
  final ReaderImageRepository? repository;
  final ReaderImageOrigin? origin;
  final ReaderImageFrame? frame;
  @override
  State<ReaderImageViewer> createState() => _ReaderImageViewerState();
}

class _ReaderImageViewerState extends State<ReaderImageViewer>
    with SingleTickerProviderStateMixin {
  static const _easeOut = Cubic(.23, 1, .32, 1);
  static const _settleSpring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 41,
  );
  final _photoController = PhotoViewController();
  late final _motion = AnimationController.unbounded(vsync: this, value: 1);
  _PreviewPose _from = const _PreviewPose(scrim: 0);
  _PreviewPose _to = const _PreviewPose(scrim: 0);
  final _pointers = <int>{};
  _PreviewDrag? _drag;
  Size _viewport = Size.zero;
  ReaderImageFrame? _frame;
  ReaderImageData? _data;
  String? _error;
  bool _saving = false;
  bool _opening = true;
  bool _entranceScheduled = false;
  bool _entranceStarted = false;
  bool _waitingForImage = false;
  bool _closing = false;
  String? _message;

  ReaderImageRepository get _repository =>
      widget.repository ?? ReaderImageRepository.instance;
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);
  _PreviewPose get _pose => _PreviewPose.lerp(_from, _to, _motion.value);

  @override
  void initState() {
    super.initState();
    _frame = widget.frame;
    if (_frame == null) unawaited(_load());
  }

  @override
  void dispose() {
    _motion.dispose();
    _photoController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await _repository.read(widget.image);
      final frame = await _boundedFrame(data);
      if (!mounted || _closing) return;
      var decodeFailed = false;
      await precacheImage(
        frame.provider,
        context,
        onError: (_, _) => decodeFailed = true,
      );
      if (!mounted || _closing) return;
      setState(() {
        if (decodeFailed) {
          _error = '图片解码失败';
        } else {
          _data = data;
          _frame = frame;
        }
      });
    } on Object {
      if (mounted && !_closing) setState(() => _error = '图片加载失败');
    }
  }

  Future<ReaderImageFrame> _boundedFrame(ReaderImageData data) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(data.bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      final ratio = math.min(
        1.0,
        math.min(4096 / math.max(w, h), math.sqrt(8 * 1024 * 1024 / (w * h))),
      );
      final width = math.max(1, (w * ratio).round());
      final height = math.max(1, (h * ratio).round());
      final provider = ResizeImage(
        MemoryImage(data.bytes),
        width: width,
        height: height,
      );
      return (
        provider: provider,
        size: Size(width.toDouble(), height.toDouble()),
      );
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> _save(bool export) async {
    if (_saving || _frame == null || _closing) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final data = _data ??= await _repository.read(widget.image);
      if (!mounted || _closing) return;
      final result = await ReaderImageExporter.save(data, export: export);
      if (!mounted) return;
      setState(
        () =>
            _message = switch (result) {
              ReaderImageSaveResult.saved => '已保存到相册',
              ReaderImageSaveResult.exported => '已导出图片',
              ReaderImageSaveResult.cancelled => null,
            },
      );
    } on Object {
      if (mounted) {
        setState(
          () => _message = export ? '导出失败，请重试' : '未能保存到相册，可使用右侧“导出原图”保存到文件',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _retry() {
    _repository.invalidate(widget.image);
    setState(() {
      _data = null;
      _frame = null;
      _error = null;
      _opening = true;
      _entranceScheduled = false;
      _entranceStarted = false;
    });
    unawaited(_load());
  }

  Rect _photoBounds(Size size, [PhotoViewControllerValue? value]) {
    final scale =
        value?.scale ??
        math.min(_viewport.width / size.width, _viewport.height / size.height);
    return Rect.fromCenter(
      center: _viewport.center(value?.position ?? Offset.zero),
      width: size.width * scale,
      height: size.height * scale,
    );
  }

  _PreviewPose? _originPose(Rect photo, double scrim) {
    final origin = widget.origin;
    if (_reduceMotion ||
        origin == null ||
        origin.viewport != _viewport ||
        !origin.rect.overlaps(Offset.zero & _viewport)) {
      return null;
    }
    final scale = math.min(
      origin.rect.width / photo.width,
      origin.rect.height / photo.height,
    );
    final viewportCenter = _viewport.center(Offset.zero);
    return _PreviewPose(
      offset:
          origin.rect.center -
          viewportCenter -
          (photo.center - viewportCenter) * scale,
      scale: scale,
      scrim: scrim,
    );
  }

  _PreviewPose _entryPose(ReaderImageFrame frame) {
    final scrim = _waitingForImage ? .55 : 0.0;
    return _originPose(_photoBounds(frame.size), scrim) ??
        _PreviewPose(scale: _reduceMotion ? 1 : .94, scrim: scrim, opacity: 0);
  }

  Future<void> _enter(ReaderImageFrame frame) async {
    final start = _entryPose(frame);
    _entranceStarted = true;
    try {
      await _animateTo(
        const _PreviewPose(),
        from: start,
        duration: _reduceMotion ? 120 : 240,
      ).orCancel;
      _opening = false;
    } on TickerCanceled {
      // A close can interrupt the entrance.
    }
  }

  TickerFuture _animateTo(
    _PreviewPose target, {
    _PreviewPose? from,
    int duration = 240,
    double? springVelocity,
  }) {
    _from = from ?? _pose;
    _to = target;
    _motion.value = 0;
    if (springVelocity != null) {
      return _motion.animateWith(
        ScrollSpringSimulation(
          _settleSpring,
          0,
          1,
          springVelocity,
          tolerance: const Tolerance(distance: .004, velocity: .05),
        ),
      );
    }
    return _motion.animateTo(
      1,
      duration: Duration(milliseconds: duration),
      curve: _easeOut,
    );
  }

  double? _releaseVelocity(Offset toward, Offset? velocity) {
    if (_reduceMotion || velocity == null || toward.distanceSquared < 1) {
      return null;
    }
    // Project the finger's velocity onto the path the image will take.
    return ((toward.dx * velocity.dx + toward.dy * velocity.dy) /
            toward.distanceSquared)
        .clamp(-4.0, 10.0);
  }

  Future<void> _close({Offset? velocity}) async {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    final start = _currentPose;
    final frame = _frame;
    final anchor =
        frame == null
            ? null
            : _originPose(_photoBounds(frame.size, _photoController.value), 0);
    setState(() => _closing = true);
    _drag = null;
    final end =
        anchor ??
        _PreviewPose(
          offset: start.offset,
          scale: start.scale * (_reduceMotion ? 1 : .94),
          scrim: 0,
          opacity: 0,
        );
    try {
      await _animateTo(
        end,
        from: start,
        duration: _reduceMotion ? 120 : 240,
        springVelocity: _releaseVelocity(end.offset - start.offset, velocity),
      ).orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  _PreviewPose get _currentPose {
    if (_closing || _entranceStarted) return _pose;
    return _frame == null
        ? const _PreviewPose(scrim: .55)
        : _entryPose(_frame!);
  }

  bool _atFit(Size size) {
    final value = _photoController.value;
    final fit = _photoBounds(size);
    return ((value.scale ?? fit.width / size.width) * size.width - fit.width)
                .abs() <
            1 &&
        value.position.distance < 1;
  }

  void _pointerDown(PointerDownEvent event, Size size) {
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _finishDrag(cancelled: true);
      return;
    }
    if (_opening || _closing || !_atFit(size)) return;
    final bounds = _pose.map(_photoBounds(size), _viewport);
    if (!bounds.contains(event.localPosition)) return;
    _drag = _PreviewDrag(event);
  }

  void _pointerMove(PointerMoveEvent event, Size size) {
    final drag = _drag;
    if (drag == null || drag.pointer != event.pointer) return;
    if (!_atFit(size)) {
      _finishDrag(cancelled: true);
      return;
    }
    drag.velocity.addPosition(event.timeStamp, event.localPosition);
    final delta = event.localPosition - drag.start;
    if (drag.base == null && (delta.distance <= kTouchSlop || delta.dy <= 0)) {
      return;
    }
    final base = drag.base ??= _pose;
    final movement =
        delta.distance <= kTouchSlop
            ? Offset.zero
            : delta * (1 - kTouchSlop / delta.distance);
    final offset = base.offset + movement;
    final fadeDistance = _viewport.shortestSide * .64;
    final progress =
        (offset.distance / fadeDistance).clamp(0.0, 1.0) -
        (base.offset.distance / fadeDistance).clamp(0.0, 1.0);
    final visual = _PreviewPose(
      offset: offset,
      scale: _reduceMotion ? 1 : (base.scale - .24 * progress).clamp(.76, 1),
      scrim: (base.scrim - .86 * progress).clamp(.14, 1),
    );
    _from = _to = visual;
    _motion.value = 1;
  }

  void _pointerEnd(PointerEvent event, {bool cancelled = false}) {
    _pointers.remove(event.pointer);
    final drag = _drag;
    if (drag?.pointer != event.pointer) return;
    drag!.velocity.addPosition(event.timeStamp, event.localPosition);
    _finishDrag(cancelled: cancelled);
  }

  void _finishDrag({required bool cancelled}) {
    final drag = _drag;
    _drag = null;
    if (drag?.base == null || _closing) return;
    final offset = _pose.offset;
    final distance = offset.distance;
    final velocity = drag!.velocity.getVelocity().pixelsPerSecond;
    final outwardSpeed =
        distance == 0
            ? 0.0
            : (velocity.dx * offset.dx + velocity.dy * offset.dy) / distance;
    final threshold = (_viewport.shortestSide * .27).clamp(86.0, 165.0);
    final fling =
        distance >= 36 &&
        outwardSpeed > 650 &&
        distance + outwardSpeed * .09 >= threshold;
    if (!cancelled && (distance >= threshold || fling)) {
      unawaited(_close(velocity: velocity));
      return;
    }
    _animateTo(
      const _PreviewPose(),
      duration: 120,
      springVelocity: _releaseVelocity(-offset, velocity),
    );
  }

  Widget _photo(ReaderImageFrame frame) => RepaintBoundary(
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _pointerDown(event, frame.size),
      onPointerMove: (event) => _pointerMove(event, frame.size),
      onPointerUp: _pointerEnd,
      onPointerCancel: (event) => _pointerEnd(event, cancelled: true),
      child: PhotoView(
        imageProvider: frame.provider,
        controller: _photoController,
        semanticLabel: '插图',
        backgroundDecoration: const BoxDecoration(),
        basePosition: Alignment.center,
        minScale: PhotoViewComputedScale.contained,
        initialScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        enableRotation: false,
        onTapUp: (_, details, transform) {
          if (_opening ||
              _closing ||
              _drag?.base != null ||
              _motion.isAnimating) {
            return;
          }
          final bounds = _photoBounds(frame.size, transform);
          if (!bounds.contains(details.localPosition)) _close();
        },
        loadingBuilder: (_, _) => const CenteredLoadingIndicator(),
        errorBuilder: (_, _, _) => _loadError('图片解码失败', '重新加载原图'),
      ),
    ),
  );

  Widget _loadError(String message, String retryLabel) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, style: const TextStyle(color: Colors.white)),
        AppButton.text(onPressed: _retry, child: Text(retryLabel)),
      ],
    ),
  );

  Widget _canvas(BuildContext context, BoxConstraints constraints) {
    _viewport = constraints.biggest;
    final frame = _frame;
    if (frame == null) _waitingForImage = true;
    if (frame != null && !_entranceScheduled && !_closing) {
      _entranceScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closing && _frame == frame) unawaited(_enter(frame));
      });
    }
    final actions = _PreviewActions(
      onClose: _close,
      onSave: _saving || frame == null ? null : () => _save(false),
      onExport: _saving || frame == null ? null : () => _save(true),
    );
    return AnimatedBuilder(
      animation: _motion,
      child: frame == null ? null : _photo(frame),
      builder: (context, photo) {
        final pose = _currentPose;
        final controls =
            _closing || frame != null
                ? ((pose.scrim - .70) / .30).clamp(0.0, 1.0)
                : 1.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black.withValues(alpha: pose.scrim)),
            if (photo == null) ...[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: _close,
              ),
              if (!_closing)
                _error == null
                    ? const IgnorePointer(child: CenteredLoadingIndicator())
                    : _loadError(_error!, '重试'),
            ] else
              ClipRect(
                child: IgnorePointer(
                  ignoring: _closing || pose.opacity < .5,
                  child: Opacity(
                    opacity: pose.opacity,
                    child: Transform(
                      alignment: Alignment.center,
                      transformHitTests: false,
                      transform:
                          Matrix4.identity()
                            ..translate(pose.offset.dx, pose.offset.dy)
                            ..scale(pose.scale, pose.scale),
                      child: photo,
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: _closing || controls < .5,
                child: Opacity(
                  opacity: controls,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: actions,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: Semantics(
      namesRoute: true,
      label: '图片预览',
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            LayoutBuilder(builder: _canvas),
            if (!_closing && (_saving || _message != null))
              Positioned(
                bottom: 0,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.only(bottom: 12),
                    child: Center(
                      child:
                          _saving
                              ? const CenteredLoadingIndicator()
                              : DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: Text(
                                    _message!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PreviewDrag {
  _PreviewDrag(PointerDownEvent event)
    : pointer = event.pointer,
      start = event.localPosition,
      velocity = VelocityTracker.withKind(event.kind) {
    velocity.addPosition(event.timeStamp, start);
  }

  final int pointer;
  final Offset start;
  final VelocityTracker velocity;
  _PreviewPose? base;
}

/// The same visual state drives the opening, direct drag and return to the book.
/// Interpolating it from the last painted pose keeps the handoff continuous.
class _PreviewPose {
  const _PreviewPose({
    this.offset = Offset.zero,
    this.scale = 1,
    this.scrim = 1,
    this.opacity = 1,
  });

  final Offset offset;
  final double scale, scrim, opacity;

  Rect map(Rect rect, Size viewport) {
    final center = viewport.center(Offset.zero);
    return Rect.fromCenter(
      center: center + (rect.center - center) * scale + offset,
      width: rect.width * scale,
      height: rect.height * scale,
    );
  }

  static _PreviewPose lerp(_PreviewPose a, _PreviewPose b, double t) {
    if (identical(a, b) || t == 1) return b;
    return _PreviewPose(
      offset: Offset.lerp(a.offset, b.offset, t)!,
      scale: math.max(.001, ui.lerpDouble(a.scale, b.scale, t)!),
      scrim: ui.lerpDouble(a.scrim, b.scrim, t)!.clamp(0, 1),
      opacity: ui.lerpDouble(a.opacity, b.opacity, t)!.clamp(0, 1),
    );
  }
}

class _PreviewActions extends StatelessWidget {
  const _PreviewActions({required this.onClose, this.onSave, this.onExport});

  final VoidCallback onClose;
  final VoidCallback? onSave, onExport;

  @override
  Widget build(BuildContext context) {
    final ios = usesAppleGlass;
    Widget action(
      String label,
      IconData apple,
      IconData material,
      VoidCallback? onPressed,
    ) =>
        ios
            ? SizedBox.square(
              dimension: 48,
              child: AppIconButton(
                tooltip: label,
                color: Colors.white.withValues(
                  alpha: onPressed == null ? .52 : 1,
                ),
                icon: Icon(apple),
                onPressed: onPressed,
              ),
            )
            : IconButton.filledTonal(
              tooltip: label,
              style: IconButton.styleFrom(minimumSize: const Size.square(48)),
              icon: Icon(material),
              onPressed: onPressed,
            );

    final close = action('关闭预览', CupertinoIcons.xmark, Icons.close, onClose);
    final save = action(
      '保存到相册',
      CupertinoIcons.arrow_down_to_line,
      Icons.download_rounded,
      onSave,
    );
    final export = action(
      '导出原图',
      CupertinoIcons.share,
      Icons.ios_share_rounded,
      onExport,
    );

    const glassTint = Color(0xD9202024);
    final row = Row(
      children: [
        ios
            ? AppleGlassSurface(capsule: true, tint: glassTint, child: close)
            : close,
        const Spacer(),
        if (ios)
          AppleGlassSurface(
            capsule: true,
            tint: glassTint,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [save, export],
            ),
          )
        else ...[
          save,
          const SizedBox(width: 8),
          export,
        ],
      ],
    );
    return ios
        ? Theme(
          data: iosGlassTheme(
            Brightness.dark,
            accent: Theme.of(context).colorScheme.primary,
          ),
          child: row,
        )
        : row;
  }
}
