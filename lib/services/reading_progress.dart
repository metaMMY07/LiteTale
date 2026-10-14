import 'dart:async';

import 'package:wild/src/rust/api/wenku8.dart' as storage;

/// An accepted position, independent of mutable reader state and pagination.
class ReadingProgress {
  const ReadingProgress({
    required this.bookId,
    required this.title,
    required this.volumeId,
    required this.volumeTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.characters,
    required this.page,
    required this.cover,
    required this.author,
  });

  final String bookId, title, volumeId, volumeTitle, chapterId, chapterTitle;
  final int characters, page;
  final String cover, author;

  Future<void> persist() => storage.updateHistory(
    novelId: bookId,
    novelName: title,
    volumeId: volumeId,
    volumeName: volumeTitle,
    chapterId: chapterId,
    chapterTitle: chapterTitle,
    progress: characters,
    progressPage: page,
    cover: cover,
    author: author,
  );
}

typedef ProgressWriter = Future<void> Function(ReadingProgress progress);

/// One queue across reader routes/modes. Writes never run concurrently; pending
/// positions for a book collapse to the latest accepted position.
class ReadingProgressQueue {
  ReadingProgressQueue({
    ProgressWriter? write,
    this.interval = const Duration(milliseconds: 300),
    this.onError,
  }) : _write = write ?? ((value) => value.persist());

  static final instance = ReadingProgressQueue();
  final ProgressWriter _write;
  final Duration interval;
  final void Function(Object, StackTrace)? onError;
  final _pending = <String, (ReadingProgress, bool Function()?)>{};
  final _failed = <String, Object>{};
  final _retry = <String, (ReadingProgress, bool Function()?)>{};
  Timer? _timer;
  Future<void>? _draining;

  Object? errorFor(String bookId) => _failed[bookId];

  void enqueue(ReadingProgress progress, {bool Function()? isValid}) {
    if (isValid != null && !isValid()) return;
    _retry.remove(progress.bookId);
    _pending[progress.bookId] = (progress, isValid);
    // A fixed maximum wait, rather than a trailing debounce that never fires
    // while the user continues turning pages.
    _timer ??= Timer(interval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    for (final entry in _retry.entries) {
      _pending.putIfAbsent(entry.key, () => entry.value);
    }
    _retry.clear();
    return _draining ??= _drain();
  }

  Future<void> _drain() async {
    // Let flush assign _draining before even a synchronous writer can finish.
    await Future<void>.value();
    try {
      while (_pending.isNotEmpty) {
        final key = _pending.keys.first;
        final (progress, valid) = _pending.remove(key)!;
        if (valid != null && !valid()) {
          _failed.remove(key);
          continue;
        }
        try {
          await _write(progress);
          _failed.remove(key);
        } catch (error, stack) {
          _failed[key] = error;
          if (!_pending.containsKey(key)) _retry[key] = (progress, valid);
          onError?.call(error, stack);
          // New positions remain queued and will still be attempted. Failed
          // writes are exposed for recovery, never an unhandled Future.
        }
      }
    } finally {
      _draining = null;
    }
  }

  Future<bool> flushBounded({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      await flush().timeout(timeout);
      return _failed.isEmpty;
    } on TimeoutException {
      // Keep the actual write in flight: timing out must not start a second
      // writer that can race it and restore an older position.
      return false;
    }
  }
}
