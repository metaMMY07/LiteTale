import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:wild/services/read_request.dart';

enum QwenTtsRegion {
  beijing('北京', 'dashscope.aliyuncs.com'),
  singapore('新加坡', 'dashscope-intl.aliyuncs.com');

  const QwenTtsRegion(this.label, this._host);

  final String label;
  final String _host;

  Uri get _endpoint => Uri.https(
    _host,
    '/api/v1/services/aigc/multimodal-generation/generation',
  );
}

class QwenTtsSettings {
  const QwenTtsSettings({required this.region, required this.apiKey});

  final QwenTtsRegion region;
  final String apiKey;

  static const _storage = FlutterSecureStorage();
  static const _key = 'litetale.listening.qwen.v1';
  static final _keyFormat = RegExp(r'^[!-~]+$');

  static bool acceptsApiKey(String apiKey) => _keyFormat.hasMatch(apiKey);

  static Future<QwenTtsSettings?> load() async {
    final saved = await _storage.read(key: _key);
    if (saved == null) return null;
    try {
      if (jsonDecode(saved) case {
        'region': final String name,
        'apiKey': final String apiKey,
      }) {
        final region = QwenTtsRegion.values.asNameMap()[name];
        if (region != null && acceptsApiKey(apiKey)) {
          return QwenTtsSettings(region: region, apiKey: apiKey);
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> save() => _storage.write(
    key: _key,
    value: jsonEncode({'region': region.name, 'apiKey': apiKey}),
  );

  static Future<void> remove() => _storage.delete(key: _key);
}

/// Synthesizes one reader clip, then downloads its signed OSS audio URL.
class QwenReaderTts {
  const QwenReaderTts({
    Future<QwenTtsSettings?> Function() loadSettings = QwenTtsSettings.load,
    http.Client Function() createClient = http.Client.new,
  }) : _loadSettings = loadSettings,
       _createClient = createClient;

  final Future<QwenTtsSettings?> Function() _loadSettings;
  final http.Client Function() _createClient;

  // A PCM WAV needs more storage than the Edge MP3 for the same paragraph.
  static const _maxWavBytes = 8 * 1024 * 1024;
  static const _maxResponseBytes = 64 * 1024;

  Future<Uint8List> synthesize(
    String voice,
    String text,
    ReadRequest request,
  ) async {
    request.check();
    final operation = ReadRequest();
    final client = _createClient();
    final closeOnCancel = operation.onCancel((_) => client.close());
    final detach = request.onCancel(operation.cancel);
    final deadline = Timer(
      const Duration(seconds: 30),
      () => operation.cancel(
        PlatformException(code: 'tts_qwen_timeout', message: '千问合成超时，请重试'),
      ),
    );
    try {
      return await operation.wait(_fetch(client, voice, text, operation));
    } catch (error) {
      request.check();
      if (error is PlatformException) rethrow;
      throw PlatformException(code: 'tts_qwen', message: '千问音色暂时无法播放，请重试或切换音色');
    } finally {
      deadline.cancel();
      detach();
      closeOnCancel();
      client.close();
    }
  }

  Future<Uint8List> _fetch(
    http.Client client,
    String voice,
    String text,
    ReadRequest request,
  ) async {
    final settings = await _loadSettings();
    request.check();
    if (settings == null) {
      throw PlatformException(
        code: 'tts_qwen_settings',
        message: '请先在音色面板配置百炼 API Key',
      );
    }
    final response = await client.send(
      http.Request('POST', settings.region._endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer ${settings.apiKey}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'model': 'qwen3-tts-flash',
          'input': {'text': text, 'voice': voice, 'language_type': 'Auto'},
        }),
    );
    switch (response.statusCode) {
      case 200:
        break;
      case 401 || 403:
        throw PlatformException(
          code: 'tts_qwen_auth',
          message: '千问鉴权失败，请检查百炼 API Key 和地域',
        );
      case 429:
        throw PlatformException(
          code: 'tts_qwen_limit',
          message: '千问请求受限，请检查百炼额度或稍后重试',
        );
      default:
        throw const FormatException('Qwen synthesis failed');
    }
    final envelope = jsonDecode(
      utf8.decode(await _readBytes(response, _maxResponseBytes)),
    );
    if (envelope case {'output': {'audio': {'url': final String url}}}) {
      request.check();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !const {'http', 'https'}.contains(uri.scheme) ||
          !uri.host.endsWith('.aliyuncs.com') ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort) {
        throw const FormatException('Invalid Qwen audio URL');
      }
      // DashScope can return an HTTP OSS URL. The signed query is preserved
      // when using HTTPS, and the download carries no API key.
      final audio = await client.send(
        http.Request('GET', uri.replace(scheme: 'https'))
          ..followRedirects = false,
      );
      if (audio.statusCode != 200) {
        throw const FormatException('Qwen audio download failed');
      }
      final bytes = await _readBytes(audio, _maxWavBytes);
      if (bytes.length >= 44 &&
          String.fromCharCodes(bytes, 0, 4) == 'RIFF' &&
          String.fromCharCodes(bytes, 8, 12) == 'WAVE') {
        return bytes;
      }
    }
    throw const FormatException('Invalid Qwen audio');
  }

  static Future<Uint8List> _readBytes(
    http.StreamedResponse response,
    int limit,
  ) async {
    if ((response.contentLength ?? 0) > limit) {
      throw const FormatException('Qwen response exceeds limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Qwen response exceeds limit');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
