import 'package:wild/services/reader_images.dart';
import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;

class CachedImageProvider extends ImageProvider<CachedImageProvider> {
  final String url;
  final double scale;
  final SourceId source;

  CachedImageProvider(this.url, {required this.source, this.scale = 1.0});

  @override
  ImageStreamCompleter loadImage(
    CachedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
    );
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  Future<ui.Codec> _loadAsync(
    CachedImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    assert(key == this);
    final ref = ReaderImageRef(source: source, url: url);
    final revision = sourceRevision.value;
    final repository = ReaderImageRepository.instance;
    final data = await repository.read(ref, revision: revision);
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(data.bytes));
    } on Object {
      repository.invalidate(ref, revision: revision);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    final CachedImageProvider typedOther = other as CachedImageProvider;
    return url == typedOther.url &&
        scale == typedOther.scale &&
        source == typedOther.source;
  }

  @override
  int get hashCode => Object.hash(url, scale, source);

  @override
  String toString() =>
      '$runtimeType(url: ${describeIdentity(url)}, scale: $scale)';
}

class CachedImage extends StatelessWidget {
  final String url;
  final SourceId source;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? cacheWidth;

  const CachedImage({
    super.key,
    required this.url,
    required this.source,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.cacheWidth,
  });

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: ResizeImage.resizeIfNeeded(
        cacheWidth,
        null,
        CachedImageProvider(url, source: source),
      ),
      fit: fit,
      width: width,
      height: height,
      // Mipmapped filtering preserves detail when large covers are reduced.
      // Bicubic (high) filtering can alias when shrinking below half-size.
      filterQuality: FilterQuality.medium,
      frameBuilder:
          (context, child, frame, wasSynchronouslyLoaded) =>
              frame == null
                  ? ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                  : child,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );

    if (borderRadius != null) {
      image = ClipRRect(borderRadius: borderRadius!, child: image);
    }

    return image;
  }
}
