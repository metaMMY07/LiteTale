import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/reader_mark_text.dart';

typedef ReaderSpeechVoice =
    ({String id, String name, String language, bool network});
typedef ReaderSpeechInfo = ({int limit, List<ReaderSpeechVoice> voices});
typedef ReaderSpeechEvent =
    ({String id, String type, int? start, String? message});

abstract interface class ReaderSpeechEngine {
  Stream<ReaderSpeechEvent> get events;
  Future<ReaderSpeechInfo> initialize();
  Future<void> speak(String id, String text, double rate, String? voice);
  Future<bool> pause(String id);
  Future<bool> resume(String id);
  Future<void> stop(String id);
}

class PlatformReaderSpeech implements ReaderSpeechEngine {
  PlatformReaderSpeech._();

  static final instance = PlatformReaderSpeech._();
  static const _commands = MethodChannel('litetale/reader_speech');
  static const _events = EventChannel('litetale/reader_speech/events');

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  late final Stream<ReaderSpeechEvent> events = _events
      .receiveBroadcastStream()
      .where(
        (event) =>
            event is Map && event['id'] is String && event['type'] is String,
      )
      .map((event) {
        final values = event as Map;
        return (
          id: values['id'] as String,
          type: values['type'] as String,
          start: values['start'] as int?,
          message: values['message'] as String?,
        );
      });

  @override
  Future<ReaderSpeechInfo> initialize() async {
    final info = await _commands.invokeMapMethod<String, Object?>('voices');
    return (
      limit: info?['limit'] as int? ?? 1000,
      voices: [
        for (final voice in (info?['voices'] as List? ?? const []))
          (
            id: voice['id'] as String,
            name: voice['name'] as String,
            language: voice['language'] as String,
            network: voice['network'] == true,
          ),
      ],
    );
  }

  @override
  Future<void> speak(String id, String text, double rate, String? voice) =>
      _commands.invokeMethod<void>('speak', {
        'id': id,
        'text': text,
        'rate': rate,
        if (voice != null) 'voice': voice,
      });

  @override
  Future<bool> pause(String id) async =>
      await _commands.invokeMethod<bool>('pause', id) ?? false;

  @override
  Future<bool> resume(String id) async =>
      await _commands.invokeMethod<bool>('resume', id) ?? false;

  @override
  Future<void> stop(String id) => _commands.invokeMethod<void>('stop', id);
}

List<String> readerSpeechSegments(String content, int limit) {
  final maximum = limit.clamp(2, 1000);
  final endings = RegExp(r'[。！？；.!?;，、,\s]');
  final segments = <String>[];
  for (final part in readerPlainParts(content)) {
    if (part.image) continue;
    final text = part.text.trim();
    var start = 0;
    while (start < text.length) {
      var end = (start + maximum).clamp(0, text.length);
      if (end < text.length) {
        final boundary = text.lastIndexOf(endings, end - 1);
        if (boundary >= start + maximum ~/ 2) {
          end = boundary + 1;
        } else if (_lowSurrogate(text.codeUnitAt(end))) {
          end--;
        }
      }
      final segment = text.substring(start, end).trim();
      if (segment.isNotEmpty) segments.add(segment);
      start = end;
    }
  }
  return segments;
}

bool _lowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Owns the cursor for one reader route. Old speech events carry the native
/// utterance identity and cannot advance a new chapter or a resumed segment.
class ReaderSpeechController extends ChangeNotifier {
  ReaderSpeechController({ReaderSpeechEngine? engine})
    : _engine = engine ?? PlatformReaderSpeech.instance;

  static final _active = ValueNotifier<ReaderSpeechController?>(null);
  static Listenable get playbackChanges => _active;
  static bool get isAnyPlaying => _active.value != null;
  static int _utteranceSequence = 0;
  static double _preferredRate = 1;
  static String? _preferredVoice;

  final ReaderSpeechEngine _engine;
  StreamSubscription<ReaderSpeechEvent>? _subscription;
  List<String> _segments = const [];
  List<ReaderSpeechVoice> voices = const [];
  String? _utterance;
  String? voice = _preferredVoice;
  String? message;
  double rate = _preferredRate;
  int _index = 0, _offset = 0, _utteranceOffset = 0;
  int _revision = 0, _playbackRequest = 0;
  bool _disposed = false, _nativePaused = false;
  bool loading = false, playing = false, paused = false;
  bool canRetryInitialization = false;

  bool get ready => _segments.isNotEmpty;
  int get currentSegment => (_index + 1).clamp(0, _segments.length);
  int get segmentCount => _segments.length;
  bool get finished => ready && _index == _segments.length;

  Future<void> prepare(({String text, bool encoded})? chapter) async {
    if (ready || loading || _disposed) return;
    if (chapter == null || chapter.encoded || chapter.text.trim().isEmpty) {
      message = chapter?.encoded == true ? '当前章节使用专用字形，暂不可朗读' : '当前章节暂无可朗读的正文';
      notifyListeners();
      return;
    }
    final revision = _revision;
    loading = true;
    canRetryInitialization = false;
    message = null;
    notifyListeners();
    try {
      final info = await _engine.initialize().timeout(
        const Duration(seconds: 8),
      );
      if (_disposed || revision != _revision) return;
      voices = info.voices;
      if (!voices.any((entry) => entry.id == voice)) voice = null;
      _segments = readerSpeechSegments(chapter.text, info.limit);
      if (_segments.isEmpty) message = '当前章节暂无可朗读的正文';
      if (ready) {
        _subscription ??= _engine.events.listen(
          _onEvent,
          onError: (Object _) {
            if (_utterance != null) _fail('朗读连接已中断，请重试');
          },
        );
      }
    } catch (error) {
      if (!_disposed && revision == _revision) {
        canRetryInitialization = !ready;
        message = _message(error, '无法启动系统语音，请检查设备语音设置');
      }
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void setRate(double value) {
    if (playing || rate == value) return;
    _releaseUtterance();
    rate = _preferredRate = value;
    notifyListeners();
  }

  void setVoice(String? value) {
    if (playing || voice == value) return;
    _releaseUtterance();
    voice = _preferredVoice = value;
    notifyListeners();
  }

  Future<void> play() async {
    if (!ready || playing || _disposed) return;
    final request = ++_playbackRequest;
    if (finished) _index = 0;
    final other = _active.value;
    if (other != null && !identical(other, this)) other.stop();
    _active.value = this;
    playing = true;
    paused = false;
    message = null;
    final id = _utterance;
    final nativePaused = _nativePaused;
    _nativePaused = false;
    notifyListeners();
    if (nativePaused && id != null) {
      bool resumed;
      try {
        resumed = await _engine.resume(id);
      } catch (_) {
        resumed = false;
      }
      if (request != _playbackRequest ||
          id != _utterance ||
          !playing ||
          resumed) {
        return;
      }
      _releaseUtterance();
    }
    await _speak();
  }

  Future<void> pause() async {
    if (!playing) return;
    final request = ++_playbackRequest;
    final id = _utterance;
    _nativePaused = id != null;
    _setPaused();
    if (id == null) return;
    // Issue pause before the first await. A quick resume reaches the native
    // channel after this call and can fall back to the current text cursor.
    bool native;
    try {
      native = await _engine.pause(id);
    } catch (_) {
      native = false;
    }
    if (!native &&
        request == _playbackRequest &&
        id == _utterance &&
        !playing) {
      _releaseUtterance();
    }
  }

  void suspend() {
    if (!playing && _utterance == null) return;
    _releaseUtterance();
    _setPaused();
  }

  void _clearPlayback() {
    _playbackRequest++;
    _releaseUtterance();
    _releaseOwner();
    _index = _offset = 0;
    message = null;
    playing = paused = false;
  }

  void stop() {
    _clearPlayback();
    notifyListeners();
  }

  void reset({bool notify = true}) {
    _revision++;
    loading = false;
    canRetryInitialization = false;
    _segments = const [];
    _clearPlayback();
    if (notify) notifyListeners();
  }

  Future<void> _speak() async {
    if (!playing || _index >= _segments.length) return;
    final segment = _segments[_index];
    final id = _utterance = '${++_utteranceSequence}';
    _utteranceOffset = _offset;
    try {
      await _engine.speak(id, segment.substring(_offset), rate, voice);
    } catch (error) {
      if (id == _utterance) _fail(_message(error, '系统语音未能播放，请重试'));
    }
  }

  void _onEvent(ReaderSpeechEvent event) {
    if (_disposed || event.id != _utterance) return;
    switch (event.type) {
      case 'range':
        if (!playing || _index >= _segments.length) return;
        final start = _utteranceOffset + (event.start ?? 0);
        final segment = _segments[_index];
        if (start >= _offset &&
            start < segment.length &&
            !_lowSurrogate(segment.codeUnitAt(start))) {
          _offset = start;
        }
      case 'done':
        _index++;
        _offset = 0;
        if (!playing || finished) {
          _releaseUtterance();
          _releaseOwner();
          playing = false;
          if (finished) paused = false;
        } else {
          unawaited(_speak());
        }
        notifyListeners();
      case 'interrupted':
        suspend();
      case 'error':
        _fail(event.message ?? '系统语音未能播放，请重试');
    }
  }

  void _setPaused() {
    playing = false;
    paused = true;
    _releaseOwner();
    notifyListeners();
  }

  void _fail(String error) {
    message = error;
    _releaseUtterance();
    _setPaused();
  }

  void _releaseOwner() {
    if (identical(_active.value, this)) _active.value = null;
  }

  void _releaseUtterance() {
    final id = _utterance;
    _utterance = null;
    _nativePaused = false;
    if (id != null) unawaited(_engine.stop(id).catchError((Object _) {}));
  }

  static String _message(Object error, String fallback) =>
      error is PlatformException ? error.message ?? fallback : fallback;

  @override
  void dispose() {
    _disposed = true;
    _clearPlayback();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
