import 'package:flutter/material.dart';
import 'package:wild/pages/novel/reader_image_viewer.dart';
import 'package:wild/services/reader_images.dart';

/// Tracks illustration visibility and the hotspots used by native curl pages.
class ReaderImageHitRegistry {
  ReaderImageHitRegistry(this.anchor);
  final GlobalKey anchor;
  final _regions = <Object, ({BuildContext context, VoidCallback? open})>{};
  void register(Object token, BuildContext context, {VoidCallback? open}) =>
      _regions[token] = (context: context, open: open);
  void unregister(Object token) => _regions.remove(token);

  bool get hasVisibleImage {
    final viewport = anchor.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return false;
    }
    final bounds = Offset.zero & viewport.size;
    for (final region in _regions.values) {
      final target = region.context.findRenderObject();
      if (target is! RenderBox || !target.attached || !target.hasSize) continue;

      // Preloaded page leaves and cached scroll rows can still be mounted.
      RenderObject child = target;
      while (child != viewport) {
        final parent = child.parent;
        if (parent == null || !parent.paintsChild(child)) break;
        child = parent;
      }
      if (child != viewport) continue;
      final rect = MatrixUtils.transformRect(
        target.getTransformTo(viewport),
        Offset.zero & target.size,
      );
      if (rect.isFinite && rect.overlaps(bounds)) return true;
    }
    return false;
  }

  Map<int, ({Rect rect, VoidCallback open})> get regions {
    final box = anchor.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return {};
    }
    final result = <int, ({Rect rect, VoidCallback open})>{};
    var id = 0;
    for (final region in _regions.values) {
      final open = region.open;
      if (open == null) continue;
      final target = region.context.findRenderObject();
      if (target is! RenderBox || !target.attached || !target.hasSize) continue;
      final origin = target.localToGlobal(Offset.zero, ancestor: box);
      final rect = Rect.fromLTWH(
        origin.dx / box.size.width,
        origin.dy / box.size.height,
        target.size.width / box.size.width,
        target.size.height / box.size.height,
      );
      result[id++] = (rect: rect, open: open);
    }
    return result;
  }

  List<Map<String, Object>> get serialized =>
      regions.entries
          .map(
            (e) => {
              'id': e.key,
              'rect': [
                e.value.rect.left,
                e.value.rect.top,
                e.value.rect.right,
                e.value.rect.bottom,
              ],
            },
          )
          .toList();
  bool openAt(Offset point) {
    for (final region in regions.values) {
      if (region.rect.contains(point)) {
        region.open();
        return true;
      }
    }
    return false;
  }

  void openId(int id) => regions[id]?.open();
}

class ReaderImageHitScope extends InheritedWidget {
  const ReaderImageHitScope({
    super.key,
    required this.registry,
    required super.child,
  });
  final ReaderImageHitRegistry registry;
  static ReaderImageHitRegistry? of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderImageHitScope>()
          ?.registry;
  @override
  bool updateShouldNotify(ReaderImageHitScope oldWidget) =>
      oldWidget.registry != registry;
}

/// The region is exactly the visible image, not its contain-fit letterboxing.
class ReaderImageRegion extends StatefulWidget {
  const ReaderImageRegion({super.key, required this.image, this.frame});
  final ReaderImageRef image;
  final ReaderImageFrame? frame;
  @override
  State<ReaderImageRegion> createState() => _ReaderImageRegionState();
}

class _ReaderImageRegionState extends State<ReaderImageRegion> {
  ReaderImageHitRegistry? _registry;
  void _open() {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    final box = context.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    ReaderImageOrigin? origin;
    if (box is RenderBox &&
        box.attached &&
        box.hasSize &&
        overlay is RenderBox &&
        overlay.attached &&
        overlay.hasSize) {
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(overlay),
        Offset.zero & box.size,
      );
      if (rect.isFinite && !rect.isEmpty) {
        origin = (rect: rect, viewport: overlay.size);
      }
    }
    openReaderImage(context, widget.image, origin: origin, frame: widget.frame);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ReaderImageHitScope.of(context);
    if (next != _registry) {
      _registry?.unregister(this);
      _registry = next;
    }
    _registry?.register(this, context, open: _open);
  }

  @override
  void dispose() {
    _registry?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '预览插图',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _open,
      child: const SizedBox.expand(),
    ),
  );
}

class ReaderIllustration extends StatefulWidget {
  const ReaderIllustration({
    super.key,
    required this.image,
    required this.provider,
    required this.child,
  });
  final ReaderImageRef image;
  final ImageProvider provider;
  final Widget child;
  @override
  State<ReaderIllustration> createState() => _ReaderIllustrationState();
}

class _ReaderIllustrationState extends State<ReaderIllustration> {
  ReaderImageHitRegistry? _registry;
  ImageStream? _stream;
  Size? _size;
  late final _listener = ImageStreamListener((image, synchronous) {
    final size = Size(
      image.image.width.toDouble(),
      image.image.height.toDouble(),
    );
    image.dispose();
    if (mounted && _size != size) setState(() => _size = size);
  }, onError: (Object _, StackTrace? _) {});
  void _resolve() {
    _stream?.removeListener(_listener);
    _stream = widget.provider.resolve(createLocalImageConfiguration(context))
      ..addListener(_listener);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ReaderImageHitScope.of(context);
    if (next != _registry) {
      _registry?.unregister(this);
      _registry = next;
    }
    _registry?.register(this, context);
    _resolve();
  }

  @override
  void didUpdateWidget(ReaderIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      _size = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _registry?.unregister(this);
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final output = constraints.biggest;
      final source = _size;
      final fitted =
          source == null
              ? null
              : applyBoxFit(BoxFit.contain, source, output).destination;
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (fitted != null && source != null)
            Positioned.fromRect(
              rect: Alignment.center.inscribe(fitted, Offset.zero & output),
              child: ReaderImageRegion(
                image: widget.image,
                frame: (provider: widget.provider, size: source),
              ),
            ),
        ],
      );
    },
  );
}
