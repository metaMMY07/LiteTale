import 'package:wild/services/read_result_cache.dart';
import 'package:wild/sources/book_source.dart';

/// A skipped speculative read is retried through the normal foreground path
/// if a reader was already waiting for that same chapter.
class Wenku8PrefetchDeferred implements Exception {
  const Wenku8PrefetchDeferred();
}

typedef Wenku8PrefetchLoad =
    Future<SourceChapter?> Function(
      String book,
      String chapter,
      bool Function() isCurrent,
    );

/// Short-lived, bounded reuse above both native and browser transports. Native
/// offline storage remains authoritative; this also covers browser-only reads.
class Wenku8ReadRepository {
  Wenku8ReadRepository({
    required Future<String> Function() host,
    required int Function() session,
    required Future<SourceBookDetail> Function(String) detail,
    required Future<SourceChapter> Function(String, String) chapter,
    required Wenku8PrefetchLoad prefetch,
    DateTime Function()? now,
  }) : _host = host,
       _session = session,
       _detail = detail,
       _chapter = chapter,
       _prefetch = prefetch,
       _details = ReadResultCache(
         maxEntries: 20,
         maxWeight: 2000000,
         ttl: const Duration(minutes: 5),
         weightOf: _detailWeight,
         cacheable: (value) => value.volumes.any((v) => v.chapters.isNotEmpty),
         now: now,
       ),
       _chapters = ReadResultCache(
         maxEntries: 12,
         maxWeight: 4000000,
         ttl: const Duration(minutes: 30),
         weightOf: (value) => value.content.length * 2,
         cacheable: (value) => value.content.trim().isNotEmpty,
         now: now,
       );

  final Future<String> Function() _host;
  final int Function() _session;
  final Future<SourceBookDetail> Function(String) _detail;
  final Future<SourceChapter> Function(String, String) _chapter;
  final Wenku8PrefetchLoad _prefetch;
  final ReadResultCache<(String, int, String), SourceBookDetail> _details;
  final ReadResultCache<(String, int, String, String), SourceChapter> _chapters;

  Future<(String, int)> _scope() async {
    final session = _session();
    final host = await _host();
    if (_session() != session) throw StateError('书源或账号已变化，请重试。');
    return (host, session);
  }

  Future<void> _check((String, int) scope) async {
    if (_session() != scope.$2 ||
        await _host() != scope.$1 ||
        _session() != scope.$2) {
      throw StateError('书源或账号已变化，请重试。');
    }
  }

  Future<SourceBookDetail> detail(String book) async {
    final scope = await _scope();
    final value = await _details.getOrLoad(
      (scope.$1, scope.$2, book),
      () async {
        final value = await _detail(book);
        await _check(scope);
        return value;
      },
    );
    await _check(scope);
    return value;
  }

  Future<SourceChapter> chapter(
    String book,
    String chapter, {
    bool Function()? isCurrent,
  }) async {
    final scope = await _scope();
    final key = (scope.$1, scope.$2, book, chapter);
    Future<SourceChapter> load() async {
      if (isCurrent?.call() == false) throw const Wenku8PrefetchDeferred();
      final value = await _chapter(book, chapter);
      await _check(scope);
      return value;
    }

    SourceChapter value;
    if (isCurrent?.call() == false) throw const Wenku8PrefetchDeferred();
    try {
      value = await _chapters.getOrLoad(key, load);
    } on Wenku8PrefetchDeferred {
      // The background attempt may have yielded to search, login or another
      // chapter. A foreground request still gets its normal transport/fallback.
      await _check(scope);
      if (isCurrent?.call() == false) rethrow;
      value = await _chapters.getOrLoad(key, load);
    }
    await _check(scope);
    return value;
  }

  Future<void> prefetch(
    String book,
    String chapter, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return;
    final scope = await _scope();
    if (!isCurrent()) return;
    try {
      await _chapters.getOrLoad((scope.$1, scope.$2, book, chapter), () async {
        bool current() => isCurrent() && _session() == scope.$2;
        if (!current()) throw const Wenku8PrefetchDeferred();
        final value = await _prefetch(book, chapter, current);
        if (value == null || !current()) throw const Wenku8PrefetchDeferred();
        await _check(scope);
        return value;
      });
    } catch (_) {
      // Speculation never changes the currently displayed chapter or auth UI.
    }
  }

  void clear() {
    _details.clear();
    _chapters.clear();
  }

  static int _detailWeight(SourceBookDetail value) =>
      (value.info.introduce.length + value.info.title.length) * 2 +
      value.volumes.fold<int>(
        0,
        (sum, v) =>
            sum +
            v.chapters.fold<int>(
              0,
              (sum, c) =>
                  sum + (c.title.length + c.url.length + c.cid.length) * 2,
            ),
      );
}
