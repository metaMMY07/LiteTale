import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_edge_tts/flutter_edge_tts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/reader_speech.dart';

enum ListeningVoiceSource { online, custom, system }

enum ListeningVoiceAuth { none, azure, bearer }

class ListeningVoice {
  const ListeningVoice(
    this.source,
    this.name, {
    this.id,
    this.language = 'zh-CN',
  });

  final ListeningVoiceSource source;
  final String name, language;
  final String? id;

  static const female = ListeningVoice(
    ListeningVoiceSource.online,
    'LiteTale 默认音色（女）',
    id: 'zh-CN-XiaoxiaoNeural',
  );
  static const male = ListeningVoice(
    ListeningVoiceSource.online,
    'LiteTale 默认音色（男）',
    id: 'zh-CN-YunxiNeural',
  );
  static const system = ListeningVoice(ListeningVoiceSource.system, '系统中文音色');

  bool matches(ListeningVoice other) =>
      source == other.source && id == other.id;

  Map<String, Object?> toJson() => {
    'source': source.name,
    'name': name,
    'id': id,
    'language': language,
  };

  factory ListeningVoice.fromJson(Map<String, dynamic> json) => ListeningVoice(
    ListeningVoiceSource.values.byName(json['source'] as String),
    json['name'] as String,
    id: json['id'] as String?,
    language: json['language'] as String,
  );
}

class ListeningVoiceEndpoint {
  const ListeningVoiceEndpoint({
    required this.url,
    required this.name,
    required this.id,
    required this.language,
    required this.auth,
    required this.credential,
  });

  final Uri url;
  final String name, id, language, credential;
  final ListeningVoiceAuth auth;

  ListeningVoice get voice => ListeningVoice(
    ListeningVoiceSource.custom,
    name,
    id: id,
    language: language,
  );

  static Uri? parseUrl(String value) {
    final url = Uri.tryParse(value.trim());
    return url != null &&
            url.scheme == 'https' &&
            url.host.isNotEmpty &&
            url.userInfo.isEmpty &&
            !url.hasFragment
        ? url
        : null;
  }

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'name': name,
    'id': id,
    'language': language,
    'auth': auth.name,
    'credential': credential,
  };

  factory ListeningVoiceEndpoint.fromJson(Map<String, dynamic> json) =>
      ListeningVoiceEndpoint(
        url: parseUrl(json['url'] as String)!,
        name: json['name'] as String,
        id: json['id'] as String,
        language: json['language'] as String,
        auth: ListeningVoiceAuth.values.byName(json['auth'] as String),
        credential: json['credential'] as String,
      );
}

class ListeningVoiceSettings {
  const ListeningVoiceSettings(this.voice, {this.endpoint});

  final ListeningVoice voice;
  final ListeningVoiceEndpoint? endpoint;
  static const _storage = FlutterSecureStorage();
  static const _key = 'litetale.listening.voice.v1';
  static Future<void> _writes = Future.value();

  static Future<ListeningVoiceSettings> load() async {
    try {
      await _writes;
      final saved = await _storage.read(key: _key);
      if (saved != null) {
        final json = jsonDecode(saved) as Map<String, dynamic>;
        final voice = ListeningVoice.fromJson(
          json['voice'] as Map<String, dynamic>,
        );
        final endpoint = json['endpoint'];
        final config =
            endpoint is Map<String, dynamic>
                ? ListeningVoiceEndpoint.fromJson(endpoint)
                : null;
        if (voice.source != ListeningVoiceSource.custom || config != null) {
          return ListeningVoiceSettings(voice, endpoint: config);
        }
      }
    } catch (_) {
      // Settings from an older install or unavailable keychain are optional.
    }
    return const ListeningVoiceSettings(ListeningVoice.female);
  }

  Future<void> save() {
    final value = jsonEncode({
      'voice': voice.toJson(),
      'endpoint': endpoint?.toJson(),
    });
    final next = _writes.then((_) => _storage.write(key: _key, value: value));
    _writes = next.catchError((Object _) {});
    return next;
  }

  static bool isChinese(String language) => const {
    'zh',
    'cmn',
    'chi',
    'zho',
  }.contains(language.toLowerCase().split(RegExp('[-_]')).first);

  static Future<List<ListeningVoice>> onlineVoices() async {
    final client = FlutterEdgeTts(voice: ListeningVoice.female.id!);
    try {
      final voices = await client.getVoices().timeout(
        const Duration(seconds: 12),
      );
      return [
        for (final voice in voices)
          if (isChinese(voice.locale) &&
              voice.shortName.isNotEmpty &&
              voice.shortName != ListeningVoice.female.id &&
              voice.shortName != ListeningVoice.male.id)
            ListeningVoice(
              ListeningVoiceSource.online,
              '${voice.shortName.split('-').last.replaceFirst('Neural', '')} · ${voice.locale} · ${voice.gender == 'Female' ? '女声' : '男声'}',
              id: voice.shortName,
              language: voice.locale,
            ),
      ];
    } finally {
      await client.close();
    }
  }
}

typedef _ClipKey = (String, String);
typedef _WordOffset = ({Duration time, int start});
typedef _VoiceClip = ({Uint8List bytes, List<_WordOffset> words});

/// One bounded lookahead, shared with the foreground request for that clip.
/// Each command and playback callback belongs to one utterance ID.
class OnlineReaderSpeech
    implements ReaderSpeechEngine, ReaderSpeechPrefetch, ReaderSpeechLiveRate {
  OnlineReaderSpeech({this.endpoint});

  final ListeningVoiceEndpoint? endpoint;
  final _events = StreamController<ReaderSpeechEvent>.broadcast();
  final _ready = <_ClipKey, _VoiceClip>{};
  final _requests = <_ClipKey, (ReadRequest, Future<_VoiceClip>)>{};
  AudioPlayer? _player;
  StreamSubscription<Duration>? _position;
  File? _file;
  String? _id;
  int _playRevision = 0;
  double _rate = 1;
  bool _paused = false, _loaded = false, _closed = false;
  Future<void> _commands = Future.value();

  static const _timeout = Duration(seconds: 18);
  static const _maxBytes = 2 * 1024 * 1024;

  @override
  Stream<ReaderSpeechEvent> get events => _events.stream;

  @override
  Future<ReaderSpeechInfo> initialize() async => (
    limit: 240,
    voices: const <ReaderSpeechVoice>[],
  );

  _ClipKey _key(String text, String? voice) => (
    voice ?? ListeningVoice.female.id!,
    text,
  );

  Future<_VoiceClip> _audio(_ClipKey key) {
    if (_ready[key] case final clip?) return Future.value(clip);
    if (_requests[key] case final entry?) return entry.$2;
    final request = ReadRequest();
    final future = _generate(key, request)
        .then((clip) {
          request.check();
          if (clip.bytes.isEmpty || clip.bytes.length > _maxBytes) {
            throw PlatformException(code: 'tts_audio', message: '语音服务返回了无效音频');
          }
          if (_ready.length >= 3) _ready.remove(_ready.keys.first);
          _ready[key] = clip;
          return clip;
        })
        .whenComplete(() {
          if (identical(_requests[key]?.$1, request)) _requests.remove(key);
        });
    _requests[key] = (request, future);
    return future;
  }

  Future<_VoiceClip> _generate(_ClipKey key, ReadRequest request) async {
    if (endpoint case final config?) {
      return (
        bytes: await _custom(key.$2, config, request),
        words: const <_WordOffset>[],
      );
    }
    final client = FlutterEdgeTts(
      voice: key.$1,
      outputFormat: EdgeTtsOutputFormat.audio24Khz48KbitrateMonoMp3,
      connectionTimeout: const Duration(seconds: 10),
      enableWordBoundary: true,
    );
    Future<void>? closing;
    Future<void> close() =>
        closing ??= client
            .close()
            .timeout(const Duration(seconds: 2))
            .catchError((Object _) {});
    final detach = request.onCancel((_) => unawaited(close()));
    try {
      final result = await request
          .wait(client.synthesize(key.$2))
          .timeout(_timeout);
      final offsets = <_WordOffset>[];
      var searchFrom = 0;
      for (final item in result.metadata) {
        final word = item.data.text?.text;
        if (item.type != 'WordBoundary' || word == null || word.isEmpty) {
          continue;
        }
        final start = key.$2.indexOf(word, searchFrom);
        if (start < 0) continue;
        offsets.add((
          time: Duration(microseconds: item.data.offset ~/ 10),
          start: start,
        ));
        searchFrom = start + word.length;
      }
      return (bytes: result.audioBytes, words: offsets);
    } catch (_) {
      request.check();
      throw PlatformException(
        code: 'tts_online',
        message: '在线音色暂时无法播放，请重试或切换音色',
      );
    } finally {
      detach();
      unawaited(close());
    }
  }

  Future<Uint8List> _custom(
    String text,
    ListeningVoiceEndpoint config,
    ReadRequest request,
  ) async {
    final client = http.Client();
    final detach = request.onCancel((_) => client.close());
    const xml = HtmlEscape(HtmlEscapeMode.attribute);
    final command =
        http.Request('POST', config.url)
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/ssml+xml; charset=utf-8',
            'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
            'User-Agent': 'LiteTale',
            if (config.auth == ListeningVoiceAuth.azure)
              'Ocp-Apim-Subscription-Key': config.credential,
            if (config.auth == ListeningVoiceAuth.bearer)
              'Authorization': 'Bearer ${config.credential}',
          })
          ..body =
              '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
              'xml:lang="${xml.convert(config.language)}"><voice name="${xml.convert(config.id)}">'
              '${xml.convert(text)}</voice></speak>';
    try {
      return await request
          .wait(() async {
            final response = await client.send(command);
            if (response.statusCode != 200) {
              throw PlatformException(
                code: 'tts_http',
                message: '语音接口返回 HTTP ${response.statusCode}',
              );
            }
            final body = BytesBuilder(copy: false);
            await for (final bytes in response.stream) {
              request.check();
              if (body.length + bytes.length > _maxBytes) {
                throw PlatformException(code: 'tts_audio', message: '接口返回音频过大');
              }
              body.add(bytes);
            }
            return body.takeBytes();
          }())
          .timeout(_timeout);
    } finally {
      detach();
      client.close();
    }
  }

  void _cancelRequests({_ClipKey? except}) {
    for (final key in _requests.keys.toList()) {
      if (key != except) _requests.remove(key)?.$1.cancel();
    }
  }

  @override
  void prefetch(String text, String? voice) {
    if (_closed || _requests.isNotEmpty) return;
    unawaited(
      _audio(_key(text, voice)).then<void>((_) {}, onError: (Object _) {}),
    );
  }

  Future<T> _command<T>(Future<T> Function() action) {
    final next = _commands.then((_) => action());
    _commands = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<void> speak(String id, String text, double rate, String? voice) async {
    if (_closed) return;
    _id = id;
    _rate = rate;
    _paused = _loaded = false;
    final key = _key(text, voice);
    _cancelRequests(except: key);
    final clip = await _audio(key);
    if (id != _id) return;
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/litetale-tts-${DateTime.now().microsecondsSinceEpoch}.mp3',
    );
    try {
      await file.writeAsBytes(clip.bytes);
      await _command(() async {
        if (id != _id) return;
        final player = _player ??= AudioPlayer();
        await player.setFilePath(file.path).timeout(const Duration(seconds: 8));
        final old = _file;
        _file = file;
        await _delete(old);
        if (id != _id) return;
        await player.setSpeed(_rate);
        if (id != _id) return;
        _loaded = true;
        _watchPosition(id, player, clip.words, text.length);
        _play(id, player);
      });
    } finally {
      if (!identical(_file, file)) await _delete(file);
    }
  }

  void _watchPosition(
    String id,
    AudioPlayer player,
    List<_WordOffset> offsets,
    int textLength,
  ) {
    unawaited(_position?.cancel());
    var next = 0;
    var previous = -1;
    _position = player.positionStream.listen((position) {
      if (_id != id ||
          _paused ||
          !player.playing ||
          position <= Duration.zero) {
        return;
      }
      if (previous == -1) _emit(id, 'started');
      int start;
      if (offsets.isNotEmpty) {
        while (next < offsets.length && offsets[next].time <= position) {
          next++;
        }
        start = next > 0 ? offsets[next - 1].start : 0;
      } else {
        final total = player.duration?.inMicroseconds ?? 0;
        start =
            total > 0
                ? (position.inMicroseconds * textLength ~/ total).clamp(
                  0,
                  textLength - 1,
                )
                : 0;
      }
      if (start > previous) {
        previous = start;
        _emit(id, 'range', start: start);
      }
    });
  }

  void _play(String id, AudioPlayer player) {
    final revision = ++_playRevision;
    unawaited(
      player.play().then<void>(
        (_) {
          if (!_paused && revision == _playRevision) {
            _emit(
              id,
              player.processingState == ProcessingState.completed
                  ? 'done'
                  : 'interrupted',
            );
          }
        },
        onError: (Object _) {
          if (revision == _playRevision) _emit(id, 'error');
        },
      ),
    );
  }

  void _emit(String id, String type, {int? start}) {
    if (_closed || _id != id) return;
    _events.add((id: id, type: type, start: start, message: null));
  }

  @override
  Future<bool> pause(String id) async {
    if (id != _id) return false;
    if (!_loaded) {
      await stop(id);
      return false;
    }
    _paused = true;
    _playRevision++;
    await _command(() async {
      if (id == _id) await _player?.pause();
    });
    return id == _id;
  }

  @override
  Future<bool> resume(String id) => _command(() async {
    final player = _player;
    if (id != _id || !_loaded || !_paused || player == null) return false;
    _paused = false;
    _play(id, player);
    return true;
  });

  @override
  Future<void> setPlaybackRate(String id, double rate) async {
    if (id != _id) return;
    _rate = rate;
    await _command(() async {
      if (id == _id && _loaded) await _player?.setSpeed(_rate);
    });
  }

  @override
  Future<void> stop(String id) async {
    if (id != _id) return;
    _id = null;
    _loaded = false;
    _playRevision++;
    unawaited(_position?.cancel());
    _position = null;
    _cancelRequests();
    await _command(() async {
      await _player?.stop();
      final file = _file;
      _file = null;
      await _delete(file);
    });
  }

  Future<void> dispose() async {
    _closed = true;
    if (_id case final id?) await stop(id);
    await _commands;
    await _player?.dispose();
    _ready.clear();
    await _events.close();
  }

  static Future<void> _delete(File? file) async {
    if (file == null) return;
    try {
      await file.delete();
    } on FileSystemException {
      // The OS can already have reclaimed temporary audio.
    }
  }
}
