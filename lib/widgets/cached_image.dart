import 'package:flutter/material.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/lnovel_source.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;

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
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) {
      throw const FormatException('图片地址无效');
    }
    // A book owns its image request policy. Wenku8 illustrations can use an
    // unrelated CDN hostname, so the hostname cannot identify the book source.
    if (source != SourceId.wenku8) {
      final response = await http
          .get(
            uri,
            headers:
                source == SourceId.lnovel
                    ? LNovelSource.headers
                    : {'Referer': 'https://www.lightnovel.app/'},
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw const FormatException('图片加载失败');
      return decode(await ui.ImmutableBuffer.fromUint8List(response.bodyBytes));
    }
    final path = await downloadImage(url: url);
    return decode(
      await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes()),
    );
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
