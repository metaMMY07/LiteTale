import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/reader_mark_text.dart';

typedef ReaderSpeechEvent =
    ({String id, String type, int? start, String? message});

bool get readerSpeechSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

abstract interface class ReaderSpeechEngine {
  Stream<ReaderSpeechEvent> get events;
  Future<void> initialize();
  Future<void> speak(String id, String text, double rate, String? voice);
  Future<bool> pause(String id);
  Future<bool> resume(String id);
  Future<void> stop(String id);
}

abstract interface class ReaderSpeechPrefetch {
  void prefetch(String text, String? voice);
}

abstract interface class ReaderSpeechLiveRate {
  Future<void> setPlaybackRate(String id, double rate);
}

typedef ReaderSpeechChunk = ({String text, int offset, int paragraph});
typedef ReaderSpeechParagraph = ({String text, int offset});

final _speechText = RegExp(r'[\p{L}\p{N}\p{S}]', unicode: true);
final _sentenceEnd = RegExp(r'[。！？；.!?;]');
final _clauseEnd = RegExp(r'[，、：,:\s]');
final _number = RegExp(r'[0-9]');

bool readerHasSpeech(String? text) =>
    text != null &&
    readerPlainParts(
      text,
    ).any((part) => !part.image && _speechText.hasMatch(part.text));

class ReaderSpeechPlan {
  ReaderSpeechPlan(String content, int limit) {
    var lineEnd = -1;
    for (final part in readerPlainParts(content)) {
      if (part.image) continue;
      final text = part.text.trim();
      if (!_speechText.hasMatch(text)) continue;
      final offset = part.offset + part.text.indexOf(text);
      if (part.offset > lineEnd) {
        final nextLine = content.indexOf('\n', part.offset);
        lineEnd = nextLine < 0 ? content.length : nextLine;
        paragraphs.add((text: text, offset: offset));
      } else {
        final previous = paragraphs.last;
        paragraphs[paragraphs.length - 1] = (
          text: '${previous.text} $text',
          offset: previous.offset,
        );
      }
      _split(text, offset, paragraphs.length - 1, limit.clamp(2, 240));
    }
  }

  final paragraphs = <ReaderSpeechParagraph>[];
  final chunks = <ReaderSpeechChunk>[];

  void _split(String text, int offset, int paragraph, int limit) {
    var start = 0;
    while (start < text.length) {
      var end = (start + limit).clamp(0, text.length);
      if (end < text.length) {
        if (_lowSurrogate(text.codeUnitAt(end))) end--;
        final window = text.substring(start, end);
        final sentence = window.lastIndexOf(_sentenceEnd);
        final clauses = _clauseEnd.allMatches(window).where((match) {
          final at = start + match.start;
          return match.end >= limit ~/ 2 &&
              !(at > start &&
                  _number.hasMatch(text[at - 1]) &&
                  _number.hasMatch(text[at + 1]));
        });
        final clause = clauses.lastOrNull;
        if (sentence >= limit ~/ 3) {
          end = start + sentence + 1;
          if (end < text.length &&
              end - start < limit &&
              '」』”’'.contains(text[end])) {
            end++;
          }
        } else if (clause != null) {
          end = start + clause.end;
        }
      }
      final raw = text.substring(start, end);
      final segment = raw.trim();
      if (segment.isNotEmpty) {
        chunks.add((
          text: segment,
          offset: offset + start + raw.indexOf(segment),
          paragraph: paragraph,
        ));
      }
      start = end;
    }
  }
}

bool _lowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Owns the cursor for one reader route. Old speech events carry the
/// utterance identity and cannot advance a new chapter or a resumed segment.
class ReaderSpeechController extends ChangeNotifier {
  ReaderSpeechController({required ReaderSpeechEngine engine})
    : _engine = engine;

  static final _active = ValueNotifier<ReaderSpeechController?>(null);
  static Listenable get playbackChanges => _active;
  static bool get isAnyPlaying => _active.value != null;
  static int _utteranceSequence = 0;
  static double _preferredRate = 1;

  final ReaderSpeechEngine _engine;
  StreamSubscription<ReaderSpeechEvent>? _subscription;
  List<ReaderSpeechChunk> _segments = const [];
  List<ReaderSpeechParagraph> paragraphs = const [];
  String? _utterance;
  String? voice;
  String? message;
  double rate = _preferredRate;
  int _index = 0, _offset = 0, _utteranceOffset = 0;
  int spokenOffset = 0;
  bool hasSpoken = false;
  int _playbackRequest = 0;
  bool _disposed = false, _nativePaused = false;
  bool playing = false, paused = false;
  bool _initialized = false;

  bool get ready => _segments.isNotEmpty;
  int get paragraphIndex =>
      ready ? _segments[_index.clamp(0, _segments.length - 1)].paragraph : 0;
  int get segmentCount => paragraphs.length;
  bool get finished => ready && _index == _segments.length;

  void loadPlan(ReaderSpeechPlan plan, int initialOffset) {
    _clearPlayback();
    _segments = plan.chunks;
    paragraphs = plan.paragraphs;
    spokenOffset = initialOffset;
    final cursor = _segments.lastIndexWhere(
      (part) => part.offset <= initialOffset,
    );
    if (cursor >= 0) {
      _index = cursor;
      final chunk = _segments[cursor];
      _offset = (initialOffset - chunk.offset).clamp(0, chunk.text.length - 1);
      if (_lowSurrogate(chunk.text.codeUnitAt(_offset))) _offset--;
    }
    if (_segments.isEmpty) message = '当前章节暂无可朗读的正文';
    notifyListeners();
  }

  void _listen() {
    _subscription ??= _engine.events.listen(
      _onEvent,
      onError: (Object _) {
        if (_utterance != null) _fail('朗读连接已中断，请重试');
      },
    );
  }

  void selectVoice(String selectedVoice) {
    if (voice == selectedVoice) return;
    final autoplay = playing;
    suspend();
    voice = selectedVoice;
    notifyListeners();
    if (autoplay) unawaited(play());
  }

  void seekParagraph(int index, {required bool autoplay}) {
    final next = _segments.indexWhere((part) => part.paragraph == index);
    if (next < 0) return;
    _playbackRequest++;
    _releaseUtterance();
    _releaseOwner();
    _index = next;
    _offset = 0;
    playing = false;
    message = null;
    notifyListeners();
    if (autoplay) unawaited(play());
  }

  void setRate(double value) {
    if (rate == value) return;
    final id = _utterance;
    final engine = _engine;
    if (id != null && engine is ReaderSpeechLiveRate) {
      rate = _preferredRate = value;
      unawaited(
        (engine as ReaderSpeechLiveRate)
            .setPlaybackRate(id, value)
            .catchError((Object _) {}),
      );
      notifyListeners();
      return;
    }
    final autoplay = playing;
    if (autoplay) suspend();
    _releaseUtterance();
    rate = _preferredRate = value;
    notifyListeners();
    if (autoplay) unawaited(play());
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
    if (!_initialized) {
      try {
        await _engine.initialize().timeout(const Duration(seconds: 8));
        if (_disposed || request != _playbackRequest || !playing) return;
        _initialized = true;
        _listen();
      } catch (error) {
        if (!_disposed && request == _playbackRequest) {
          _fail(_message(error, '无法启动朗读，请重试'));
        }
        return;
      }
    }
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
    _playbackRequest++;
    _releaseUtterance();
    _setPaused();
  }

  void _clearPlayback() {
    _playbackRequest++;
    _releaseUtterance();
    _releaseOwner();
    _index = _offset = 0;
    hasSpoken = false;
    message = null;
    playing = paused = false;
  }

  void stop() {
    _clearPlayback();
    notifyListeners();
  }

  Future<void> _speak() async {
    if (!playing || _index >= _segments.length) return;
    final segment = _segments[_index];
    final id = _utterance = '${++_utteranceSequence}';
    _utteranceOffset = _offset;
    try {
      await _engine.speak(id, segment.text.substring(_offset), rate, voice);
      final engine = _engine;
      if (id == _utterance &&
          engine is ReaderSpeechPrefetch &&
          _index + 1 < _segments.length) {
        (engine as ReaderSpeechPrefetch).prefetch(
          _segments[_index + 1].text,
          voice,
        );
      }
    } catch (error) {
      if (id == _utterance) _fail(_message(error, '朗读失败，请重试'));
    }
  }

  void _onEvent(ReaderSpeechEvent event) {
    if (_disposed || event.id != _utterance) return;
    switch (event.type) {
      case 'started':
        if (playing && _index < _segments.length) {
          hasSpoken = true;
          spokenOffset = _segments[_index].offset + _offset;
        }
      case 'range':
        if (!playing || _index >= _segments.length) return;
        final start = _utteranceOffset + (event.start ?? 0);
        final segment = _segments[_index];
        if (start >= _offset &&
            start < segment.text.length &&
            !_lowSurrogate(segment.text.codeUnitAt(start))) {
          _offset = start;
          hasSpoken = true;
          spokenOffset = segment.offset + start;
        }
      case 'done':
        if (_index < _segments.length) {
          hasSpoken = true;
          final segment = _segments[_index];
          final end = segment.text.length - 1;
          spokenOffset =
              segment.offset +
              (_lowSurrogate(segment.text.codeUnitAt(end)) ? end - 1 : end);
        }
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
        _fail(event.message ?? '朗读失败，请重试');
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
