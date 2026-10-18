import 'dart:async';

import 'package:wild/src/rust/wenku8/models.dart';

typedef ReaderPrefetchLoad =
    Future<void> Function({
      required String aid,
      required String cid,
      required bool Function() isCurrent,
    });

/// Only one neighbour is planned, after the current chapter has been displayed.
/// Replacing/closing the reader invalidates pending and active speculation.
class ReaderChapterPrefetch {
  ReaderChapterPrefetch(
    this._load, {
    this.delay = const Duration(milliseconds: 900),
  });

  final ReaderPrefetchLoad _load;
  final Duration delay;
  Timer? _timer;
  int _generation = 0;
  (String, String)? _target;

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _target = null;
  }

  /// A tap on the chapter already being fetched adopts that request. Merely
  /// scheduled work is cancelled so the foreground can start immediately.
  void foreground(String aid, String cid) {
    if (_target == (aid, cid)) {
      _timer?.cancel();
      _timer = null;
    } else {
      cancel();
    }
  }

  void schedule({
    required String aid,
    required String cid,
    required List<Volume> volumes,
    required bool Function() isCurrent,
  }) {
    cancel();
    final chapter = nextChapter(aid, cid, volumes);
    if (chapter == null || !isCurrent()) return;
    _target = (chapter.aid, chapter.cid);
    final generation = _generation;
    bool current() => _generation == generation && isCurrent();
    _timer = Timer(delay, () async {
      _timer = null;
      if (!current()) return;
      try {
        await _load(aid: chapter.aid, cid: chapter.cid, isCurrent: current);
      } catch (_) {
        // No retry loop or error state for a chapter nobody has asked for yet.
      }
    });
  }

  static Chapter? nextChapter(String aid, String cid, List<Volume> volumes) {
    var found = false;
    for (final volume in volumes) {
      for (final chapter in volume.chapters) {
        if (found && chapter.aid == aid && chapter.cid != cid) return chapter;
        if (chapter.aid == aid && chapter.cid == cid) found = true;
      }
    }
    return null;
  }
}
