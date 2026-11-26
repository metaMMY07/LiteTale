import 'dart:async';
import 'package:wild/models/source_comment.dart';
import 'read_request.dart';
import 'read_result_cache.dart';

typedef CommentLoader =
    Future<SourceCommentPage> Function(
      String bookId, {
      int page,
      CommentFeed feed,
      String? threadId,
    });

/// Comments never run as part of detail/discovery loading. Successful pages
/// have a short, bounded RAM cache; account/source changes cannot reuse them.
class BookCommentsRepository {
  BookCommentsRepository({
    required this.loader,
    required this.generation,
    this.timeout = const Duration(seconds: 25),
    int maxEntries = 24,
    int maxBytes = 2 * 1024 * 1024,
  }) : _cache = ReadResultCache(
         maxEntries: maxEntries,
         maxWeight: maxBytes,
         ttl: const Duration(minutes: 2),
         weightOf: (value) => value.weight,
       );

  final CommentLoader loader;
  final int Function(String) generation;
  final Duration timeout;
  final ReadResultCache<_Key, SourceCommentPage> _cache;
  final _loads = SharedReadPool<_Key, SourceCommentPage>();
  int _epoch = 0;

  Future<SourceCommentPage> load(
    String bookId, {
    int page = 1,
    CommentFeed feed = CommentFeed.comments,
    String? threadId,
    bool refresh = false,
  }) {
    validateCommentPage(page);
    ReadRequest.current?.check();
    if (refresh) {
      _epoch++;
      _cache.clear();
    }
    final epoch = _epoch;
    final session = generation(bookId);
    final key = (bookId, session, epoch, page, feed, threadId);
    final cached = _cache.peek(key);
    if (cached != null) return Future.value(cached);
    return _loads.run(key, () async {
      final scope = ReadRequest.current!;
      final timer = Timer(
        timeout,
        () => scope.cancel(const SourceCommentException('评论加载超时，请稍后重试')),
      );
      try {
        final result = await scope.wait(
          loader(bookId, page: page, feed: feed, threadId: threadId),
        );
        scope.check();
        if (generation(bookId) != session) {
          throw const SourceCommentException('书源或账号已变化，请重新打开评论');
        }
        if (result.page != page ||
            result.items.length > 500 ||
            result.weight > 2 * 1024 * 1024) {
          throw const SourceCommentException('原站评论页码或内容大小异常');
        }
        if (epoch != _epoch) return result;
        // Only completed results enter the cache; an abandoned physical load
        // can never remain as an in-flight cache entry for the next caller.
        return _cache.getOrLoad(key, () {
          scope.check();
          return Future.value(result);
        });
      } finally {
        timer.cancel();
      }
    });
  }
}

typedef _Key = (String, int, int, int, CommentFeed, String?);
