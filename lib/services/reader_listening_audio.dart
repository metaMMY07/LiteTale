import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_edge_tts/flutter_edge_tts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/reader_speech.dart';

class ListeningVoice {
  const ListeningVoice(this.id, this.name, {this.language = 'zh-CN'});

  final String id, name, language;

  static const female = ListeningVoice(
    'zh-CN-XiaoxiaoNeural',
    'LiteTale 默认音色（女）',
  );
  static const male = ListeningVoice('zh-CN-YunxiNeural', 'LiteTale 默认音色（男）');
  static const _storage = FlutterSecureStorage();
  static const _key = 'litetale.listening.voice.v1';
  static Future<void> _writes = Future.value();

  static Future<ListeningVoice> load() async {
    try {
      await _writes;
      final saved = await _storage.read(key: _key);
      if (saved != null) {
        final json = jsonDecode(saved) as Map<String, dynamic>;
        final voice = json['voice'] as Map<String, dynamic>;
        final id = voice['id'];
        if (voice['source'] == 'online' && id is String && id.isNotEmpty) {
          if (id == female.id) return female;
          if (id == male.id) return male;
          return ListeningVoice(
            id,
            voice['name'] as String,
            language: voice['language'] as String,
          );
        }
      }
    } catch (_) {
      // Settings from an older install or unavailable keychain are optional.
    }
    return female;
  }

  Future<void> save() {
    final value = jsonEncode({
      'voice': {
        'source': 'online',
        'id': id,
        'name': name,
        'language': language,
      },
    });
    final next = _writes.then((_) => _storage.write(key: _key, value: value));
    _writes = next.catchError((Object _) {});
    return next;
  }

  static bool _isChinese(String language) => const {
    'zh',
    'cmn',
    'chi',
    'zho',
  }.contains(language.toLowerCase().split(RegExp('[-_]')).first);

  static Future<List<ListeningVoice>> fetchOnline() async {
    final client = FlutterEdgeTts(voice: female.id);
    try {
      final voices = await client.getVoices().timeout(
        const Duration(seconds: 12),
      );
      return [
        for (final voice in voices)
          if (_isChinese(voice.locale) &&
              voice.shortName.isNotEmpty &&
              voice.shortName != female.id &&
              voice.shortName != male.id)
            ListeningVoice(
              voice.shortName,
              '${voice.shortName.split('-').last.replaceFirst('Neural', '')} · ${voice.locale} · ${voice.gender == 'Female' ? '女声' : '男声'}',
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
  OnlineReaderSpeech({
    AudioPlayer Function() createPlayer = AudioPlayer.new,
    Future<Directory> Function() temporaryDirectory = getTemporaryDirectory,
    Future<EdgeTtsSynthesisResult> Function(String, String, ReadRequest)
        synthesize =
        _synthesizeWithEdge,
  }) : _createPlayer = createPlayer,
       _temporaryDirectory = temporaryDirectory,
       _synthesize = synthesize;

  final AudioPlayer Function() _createPlayer;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<EdgeTtsSynthesisResult> Function(String, String, ReadRequest)
  _synthesize;
  final _events = StreamController<ReaderSpeechEvent>.broadcast();
  final _ready = <_ClipKey, _VoiceClip>{};
  final _requests = <_ClipKey, (ReadRequest, Future<_VoiceClip>)>{};
  AudioPlayer? _player;
  StreamSubscription<Duration>? _position;
  StreamSubscription<PlayerState>? _playerState;
  StreamSubscription<PlayerException>? _playerError;
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
  Future<void> initialize() async {}

  _ClipKey _key(String text, String? voice) => (
    voice ?? ListeningVoice.female.id,
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
    final result = await _synthesize(key.$1, key.$2, request);
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
  }

  static Future<EdgeTtsSynthesisResult> _synthesizeWithEdge(
    String voice,
    String text,
    ReadRequest request,
  ) async {
    final client = FlutterEdgeTts(
      voice: voice,
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
      return await request.wait(client.synthesize(text)).timeout(_timeout);
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
    final directory = await _temporaryDirectory();
    final file = File(
      '${directory.path}/litetale-tts-${DateTime.now().microsecondsSinceEpoch}.mp3',
    );
    try {
      await file.writeAsBytes(clip.bytes);
      await _command(() async {
        if (id != _id) return;
        final player = _player ??= _createPlayer();
        await player.pause();
        if (id != _id) return;
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
    _stopObservingPlayback();
    final revision = _playRevision;
    bool current() =>
        !_closed && !_paused && id == _id && revision == _playRevision;
    void settle(String type) {
      if (!current()) return;
      _stopObservingPlayback();
      _emit(id, type);
    }

    // A completed player can retain its playing flag. The play Future can
    // resolve while another clip is playing, so only the state can end a clip.
    var wasPlaying = player.playing;
    _playerState = player.playerStateStream.listen((state) {
      if (!current()) return;
      if (state.processingState == ProcessingState.completed) {
        if (player.processingState == ProcessingState.completed &&
            (state.playing || wasPlaying)) {
          settle('done');
        }
      } else if (state.playing) {
        wasPlaying = true;
      } else if (wasPlaying && !player.playing) {
        settle('interrupted');
      }
    });
    _playerError = player.errorStream.listen((_) => settle('error'));
    unawaited(player.play().catchError((Object _) => settle('error')));
  }

  void _stopObservingPlayback() {
    _playRevision++;
    unawaited(_playerState?.cancel());
    unawaited(_playerError?.cancel());
    _playerState = null;
    _playerError = null;
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
    _stopObservingPlayback();
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
    _stopObservingPlayback();
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
