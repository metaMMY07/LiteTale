import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/read_result_cache.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/lnovel_source.dart';
import 'package:wild/sources/source_api.dart';

/// A book owns the image policy even after discovery changes source.
class ReaderImageRef {
  const ReaderImageRef({
    required this.source,
    required this.url,
    this.readLocal,
  });
  final SourceId source;
  final String url;
  final Future<Uint8List> Function()? readLocal;
}

class ReaderImageData {
  ReaderImageData(this.bytes) {
    if (bytes.isEmpty || bytes.length > ReaderImageRepository.maxBytes) {
      throw const FormatException('图片为空或超过20MB');
    }
    bool starts(List<int> prefix, [int offset = 0]) =>
        bytes.length >= offset + prefix.length &&
        List.generate(
          prefix.length,
          (i) => bytes[offset + i] == prefix[i],
        ).every((value) => value);
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) {
      extension = 'png';
    } else if (starts([255, 216, 255])) {
      extension = 'jpg';
    } else if (starts([71, 73, 70, 56])) {
      extension = 'gif';
    } else if (starts([82, 73, 70, 70]) && starts([87, 69, 66, 80], 8)) {
      extension = 'webp';
    } else if (starts([66, 77])) {
      extension = 'bmp';
    } else if (starts([102, 116, 121, 112], 4) &&
        (starts([97, 118, 105, 102], 8) || starts([97, 118, 105, 115], 8))) {
      extension = 'avif';
    } else {
      throw const FormatException('返回内容不是受支持的图片');
    }
  }
  final Uint8List bytes;
  late final String extension;
  String get mime => 'image/${extension == 'jpg' ? 'jpeg' : extension}';
}

class ReaderImageRepository {
  ReaderImageRepository({http.Client? client}) : _client = client;
  static final instance = ReaderImageRepository();
  static const maxBytes = 20 * 1024 * 1024;
  final http.Client? _client;
  final _cache = ReadResultCache<String, ReaderImageData>(
    maxEntries: 16,
    maxWeight: 32 * 1024 * 1024,
    ttl: const Duration(minutes: 10),
    weightOf: (data) => data.bytes.length,
  );

  static Map<String, String> headersFor(SourceId source) =>
      source == SourceId.lnovel
          ? LNovelSource.headers
          : source == SourceId.bili
          ? const {
            'User-Agent': 'Mozilla/5.0',
            'Referer': 'https://www.bilinovel.net/',
          }
          : source.isRule ||
              source == SourceId.huanmeng ||
              source == SourceId.esj
          ? ruleImageHeaders(source)
          : const {'Referer': 'https://www.lightnovel.app/'};

  Future<ReaderImageData> read(
    ReaderImageRef ref, {
    int? revision,
  }) => _cache.getOrLoad(
    '${ref.source.name}:${revision ?? sourceRevision.value}:${ref.url}',
    () async {
      if (ref.readLocal != null) return ReaderImageData(await ref.readLocal!());
      if (ref.source == SourceId.localEpub) {
        return ReaderImageData(
          await LocalEpubLibrary.instance.readAsset(ref.url),
        );
      }
      final uri = Uri.tryParse(ref.url);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('图片地址无效');
      }
      if (ref.source == SourceId.wenku8) {
        final file = File(await downloadImage(url: ref.url));
        if (await file.length() > maxBytes) {
          throw const FormatException('图片超过20MB');
        }
        return ReaderImageData(await file.readAsBytes());
      }
      final client = _client ?? http.Client();
      try {
        return await (() async {
          final response = await client.send(
            http.Request('GET', uri)..headers.addAll(headersFor(ref.source)),
          );
          if (response.statusCode != 200) throw const FormatException('图片加载失败');
          if ((response.contentLength ?? 0) > maxBytes) {
            throw const FormatException('图片超过20MB');
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.stream) {
            if (bytes.length + chunk.length > maxBytes) {
              throw const FormatException('图片超过20MB');
            }
            bytes.add(chunk);
          }
          return ReaderImageData(bytes.takeBytes().asUnmodifiableView());
        })().timeout(const Duration(seconds: 25));
      } finally {
        if (_client == null) client.close();
      }
    },
  );

  /// Explicit retry also drops a response that passed the format header check
  /// but was subsequently rejected by the image decoder.
  void invalidate(ReaderImageRef ref, {int? revision}) => _cache.invalidate(
    '${ref.source.name}:${revision ?? sourceRevision.value}:${ref.url}',
  );
}

enum ReaderImageSaveResult { saved, exported, cancelled }

class ReaderImageExporter {
  static const channel = MethodChannel('litetale/reader_images');
  static Future<ReaderImageSaveResult> save(
    ReaderImageData image, {
    required bool export,
    String name = 'LiteTale',
  }) async {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final result = await channel.invokeMethod<
      String
    >(export ? 'export' : 'save', {
      'bytes': image.bytes,
      'mime': image.mime,
      'name':
          '${safe.substring(0, safe.length.clamp(0, 64))}_${DateTime.now().microsecondsSinceEpoch}.${image.extension}',
    });
    return switch (result) {
      'saved' => ReaderImageSaveResult.saved,
      'exported' => ReaderImageSaveResult.exported,
      'cancelled' => ReaderImageSaveResult.cancelled,
      _ => throw const FormatException('系统未确认图片已保存'),
    };
  }
}
