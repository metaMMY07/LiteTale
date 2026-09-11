import 'package:flutter/material.dart';
import 'package:wild/sources/source_api.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;

class CachedImageProvider extends ImageProvider<CachedImageProvider> {
  final String url;
  final double scale;

  CachedImageProvider(this.url, {this.scale = 1.0});

  @override
  ImageStreamCompleter loadImage(
    CachedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key),
      scale: key.scale,
    );
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  Future<ui.Codec> _loadAsync(CachedImageProvider key) async {
    assert(key == this);
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) throw const FormatException('图片地址无效');
    final wenku = ['wenku8.net', 'wenku8.com', 'wenku8.cc'].any((host) => uri.host == host || uri.host.endsWith('.$host'));
    if (!wenku) {
      final response = await http.get(uri, headers: {'Referer': 'https://www.lightnovel.app/'})
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw const FormatException('图片加载失败');
      return ui.instantiateImageCodec(response.bodyBytes);
    }
    final path = await downloadImage(url: url);
    return ui.instantiateImageCodec(await File(path).readAsBytes());
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    final CachedImageProvider typedOther = other as CachedImageProvider;
    return url == typedOther.url && scale == typedOther.scale;
  }

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() =>
      '$runtimeType(url: ${describeIdentity(url)}, scale: $scale)';
}

class CachedImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const CachedImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: CachedImageProvider(url),
      fit: fit,
      width: width,
      height: height,
      // Mipmapped filtering preserves detail when large covers are reduced.
      // Bicubic (high) filtering can alias when shrinking below half-size.
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          color: Colors.grey.withAlpha(80),
          child: const Center(child: CircularProgressIndicator()),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Colors.grey.withAlpha(80),
          child: const Icon(Icons.broken_image),
        );
      },
    );

    if (borderRadius != null) {
      image = ClipRRect(borderRadius: borderRadius!, child: image);
    }

    return image;
  }
}
