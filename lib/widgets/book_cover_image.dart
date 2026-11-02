import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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

class _CoverSurfaceState extends State<_CoverSurface>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _fade,
    curve: const Cubic(.23, 1, .32, 1),
  );
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _frame;
  BookCoverPreview? _preview;
  ImageProvider? _provider;
  String _key = '';
  int _revision = 0, _generation = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    sourceRevision.addListener(_sourceChanged);
    _fade.addStatusListener((status) {
      if (mounted && status == AnimationStatus.completed) setState(() {});
    });
  }

  void _sourceChanged() {
    if (mounted) setState(() => _resolve());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
    if (MediaQuery.disableAnimationsOf(context)) _fade.value = 1;
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
    _failed = false;
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
        setState(() => _preview = preview);
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
      (info, synchronous) {
        if (!mounted || generation != _generation) return;
        final first = _frame == null;
        final instant =
            synchronous ||
            widget.cache.wasRevealed(key) ||
            MediaQuery.disableAnimationsOf(context);
        final previous = _frame;
        _frame = info.clone();
        previous?.dispose();
        _failed = false;
        if (first) {
          widget.cache.reveal(key);
          if (instant) {
            _fade.value = 1;
          } else {
            unawaited(_fade.forward());
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
        setState(() => _failed = true);
      },
    );
    _stream!.addListener(_listener!);
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
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_frame != null && _fade.isCompleted && !_failed)
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
          if (_failed)
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
    );
  }
}
