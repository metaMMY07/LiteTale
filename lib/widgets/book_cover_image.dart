import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wild/services/book_cover_preview.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/sources/book_source.dart';
import 'cached_image.dart';

/// Cover-only loading surface. Reading illustrations retain their own behavior.
class BookCoverImage extends StatelessWidget {
  const BookCoverImage({
    super.key,
    required this.url,
    required this.source,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.cacheWidth,
    this.onColor,
    this.imageProvider,
    this.previewCache,
  });
  final String url;
  final SourceId source;
  final double? width, height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? cacheWidth;
  final ValueChanged<Color>? onColor;
  final ImageProvider? imageProvider;
  final BookCoverPreviewCache? previewCache;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final logical =
          width?.isFinite == true
              ? width!
              : box.maxWidth.isFinite
              ? box.maxWidth
              : 120.0;
      final pixels =
          cacheWidth ??
          (logical * MediaQuery.devicePixelRatioOf(context)).ceil();
      // Nearby layouts reuse the same decoded size, without changing source URLs.
      final bucket = ((pixels / 64).ceil() * 64).clamp(64, 1536);
      return ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        child: SizedBox(
          width: width,
          height: height,
          child: _CoverSurface(
            url: url,
            source: source,
            pixels: bucket,
            fit: fit,
            onColor: onColor,
            imageProvider: imageProvider,
            cache: previewCache ?? BookCoverPreviewCache.instance,
          ),
        ),
      );
    },
  );
}

class _CoverSurface extends StatefulWidget {
  const _CoverSurface({
    required this.url,
    required this.source,
    required this.pixels,
    required this.fit,
    required this.cache,
    this.onColor,
    this.imageProvider,
  });
  final String url;
  final SourceId source;
  final int pixels;
  final BoxFit fit;
  final ValueChanged<Color>? onColor;
  final ImageProvider? imageProvider;
  final BookCoverPreviewCache cache;
  @override
  State<_CoverSurface> createState() => _CoverSurfaceState();
}

enum _CoverPhase { loading, ready, revealing, loaded, error }

class _CoverSurfaceState extends State<_CoverSurface>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late Animation<double> _opacity;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _frame;
  BookCoverPreview? _preview;
  ImageProvider? _provider;
  String _key = '';
  int _revision = 0, _generation = 0;
  _CoverPhase _phase = _CoverPhase.loading;

  @override
  void initState() {
    super.initState();
    sourceRevision.addListener(_sourceChanged);
    _fade.addStatusListener((status) {
      if (mounted && status == AnimationStatus.completed) {
        setState(() => _phase = _CoverPhase.loaded);
      }
    });
  }

  void _sourceChanged() {
    if (mounted) setState(() => _resolve());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final apple = Theme.of(context).platform == TargetPlatform.iOS;
    // Novella's expo-image uses UIView's 200ms ease-in-out cross-dissolve.
    // Android follows the 500ms foreground fade used by OctoImage, which is
    // present in Yomiru; its private CoverImage overrides are not published.
    _fade.duration = Duration(milliseconds: apple ? 200 : 500);
    _opacity = _fade.drive(
      CurveTween(curve: apple ? Curves.easeInOut : Curves.easeIn),
    );
    _resolve();
    if (_frame != null && MediaQuery.disableAnimationsOf(context)) {
      _fade.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant _CoverSurface old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.source != widget.source ||
        old.pixels != widget.pixels ||
        old.imageProvider != widget.imageProvider ||
        old.cache != widget.cache) {
      _resolve(force: true);
    }
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void _resolve({bool force = false}) {
    final revision = sourceRevision.value;
    final key = '${widget.source.name}:$revision:${widget.url}';
    if (!force && key == _key && _stream != null) return;
    _detach();
    _frame?.dispose();
    _frame = null;
    _phase = _CoverPhase.loading;
    _revision = revision;
    _key = key;
    final generation = ++_generation;
    _fade.value = 0;
    _preview = widget.cache.lookup(key);
    if (_preview != null) _notifyColor(_preview!.color, generation);
    if (widget.url.isEmpty && widget.imageProvider == null) return;
    unawaited(
      widget.cache.fromUrl(key, widget.url).then((preview) {
        if (!mounted || generation != _generation || preview == null) return;
        // Do not replace the underlay halfway through an ongoing dissolve.
        if (_frame == null) setState(() => _preview = preview);
        _notifyColor(preview.color, generation);
      }),
    );
    _provider =
        widget.imageProvider ??
        ResizeImage.resizeIfNeeded(
          widget.pixels,
          null,
          CachedImageProvider(
            widget.url,
            source: widget.source,
            revision: revision,
          ),
        );
    _stream = _provider!.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted || generation != _generation) return;
        final first = _frame == null;
        // A decoded/prefetched image has not necessarily appeared on screen.
        // Novella's skipOnCacheHit is `none`: only an actually displayed cover
        // suppresses the first reveal, irrespective of source or load speed.
        final instant =
            widget.cache.wasRevealed(key) ||
            MediaQuery.disableAnimationsOf(context);
        final previous = _frame;
        _frame = info.clone();
        previous?.dispose();
        if (first) {
          _phase = instant ? _CoverPhase.loaded : _CoverPhase.ready;
          if (instant) {
            _fade.value = 1;
          }
          unawaited(
            widget.cache.capture(key, info.image).then((preview) {
              if (!mounted || generation != _generation || preview == null) {
                return;
              }
              _notifyColor(preview.color, generation);
            }),
          );
        }
        setState(() {});
      },
      onError: (Object error, StackTrace? trace) {
        if (!mounted || generation != _generation) return;
        _fade.stop();
        setState(() => _phase = _CoverPhase.error);
      },
    );
    _stream!.addListener(_listener!);
  }

  void _didPaintFrame(int generation) {
    if (!mounted ||
        generation != _generation ||
        _frame == null ||
        _phase == _CoverPhase.error) {
      return;
    }
    widget.cache.reveal(_key);
    if (_phase != _CoverPhase.ready) return;
    // Offstage tabs and sliver-cache children may finish decoding without ever
    // being painted. Start their transition on display, not during prefetch.
    setState(() => _phase = _CoverPhase.revealing);
    unawaited(_fade.forward());
  }

  void _notifyColor(Color color, int generation) {
    if (widget.onColor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation) widget.onColor?.call(color);
    });
  }

  Future<void> _retry() async {
    final generation = _generation;
    ReaderImageRepository.instance.invalidate(
      ReaderImageRef(source: widget.source, url: widget.url),
      revision: _revision,
    );
    await _provider?.evict();
    if (mounted && generation == _generation) {
      setState(() => _resolve(force: true));
    }
  }

  @override
  void dispose() {
    sourceRevision.removeListener(_sourceChanged);
    ++_generation;
    _detach();
    _frame?.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final apple = Theme.of(context).platform == TargetPlatform.iOS;
    final preview = apple ? _preview : null;
    final generation = _generation;
    return RepaintBoundary(
      child: _CoverFirstPaint(
        token: (_generation, _frame != null),
        onPaint: () => _didPaintFrame(generation),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_phase == _CoverPhase.loaded)
              const SizedBox.shrink()
            else if (preview != null)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: Image.memory(
                  preview.bytes,
                  fit: widget.fit,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                ),
              )
            else if (apple && _frame != null && _phase != _CoverPhase.error)
              // Other sources have no server BlurHash. Render a tiny blurred
              // sample of the very same decoded pixels, without another request
              // or holding the sharp image behind thumbnail encoding work.
              _LocalCoverPreview(frame: _frame!, fit: widget.fit)
            else
              DecoratedBox(
                key: ValueKey(
                  apple ? 'cover-ios-placeholder' : 'cover-android-placeholder',
                ),
                decoration: BoxDecoration(
                  gradient:
                      apple
                          ? null
                          : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.alphaBlend(
                                colors.primary.withValues(alpha: .08),
                                colors.primaryContainer,
                              ),
                              Color.alphaBlend(
                                colors.primary.withValues(alpha: .24),
                                colors.surface,
                              ),
                            ],
                          ),
                  color: apple ? colors.surfaceContainerHighest : null,
                ),
                child: Center(
                  child: Icon(
                    apple ? CupertinoIcons.book : Icons.menu_book_rounded,
                    color: apple ? colors.onSurfaceVariant : colors.primary,
                    size: 28,
                  ),
                ),
              ),
            if (_frame != null)
              FadeTransition(
                key: const ValueKey('cover-reveal'),
                opacity: _opacity,
                child: RawImage(
                  image: _frame!.image,
                  scale: _frame!.scale,
                  fit: widget.fit,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            if (_phase == _CoverPhase.error)
              Center(
                child: IconButton(
                  key: const ValueKey('cover-retry'),
                  tooltip: '重新加载封面',
                  onPressed: _retry,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surface.withValues(alpha: .88),
                  ),
                  icon: Icon(Icons.refresh_rounded, color: colors.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LocalCoverPreview extends StatelessWidget {
  const _LocalCoverPreview({required this.frame, required this.fit});
  final ImageInfo frame;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => ClipRect(
    key: const ValueKey('cover-local-blur'),
    child: FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: 32,
        height: 48,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
          child: RawImage(
            image: frame.image,
            fit: fit,
            filterQuality: FilterQuality.low,
          ),
        ),
      ),
    ),
  );
}

/// Receiving an image frame is not evidence that a cover was displayed.
class _CoverFirstPaint extends SingleChildRenderObjectWidget {
  const _CoverFirstPaint({
    required this.token,
    required this.onPaint,
    required super.child,
  });
  final Object token;
  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _CoverPaintObserver(token, onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _CoverPaintObserver renderObject,
  ) {
    renderObject.update(token, onPaint);
  }
}

class _CoverPaintObserver extends RenderProxyBox {
  _CoverPaintObserver(this._token, this._onPaint);
  Object _token;
  VoidCallback _onPaint;
  bool _scheduled = false;

  void update(Object token, VoidCallback onPaint) {
    _onPaint = onPaint;
    if (_token == token) return;
    _token = token;
    _scheduled = false;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_scheduled) return;
    _scheduled = true;
    final token = _token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && token == _token) _onPaint();
    });
  }
}
