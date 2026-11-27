/// Original-site comments, rendered by Flutter. No executable markup or
/// account/session data is kept in this model.
enum CommentFeed { comments, reviews }

class SourceComment {
  const SourceComment({
    required this.id,
    required this.author,
    required this.content,
    this.time = '',
    this.title = '',
    this.replyCount = 0,
    this.replies = const [],
    this.spoiler = false,
    this.preview = false,
    this.canOpenThread = false,
  });

  final String id, author, content, time, title;
  final int replyCount;
  final List<SourceComment> replies;
  final bool spoiler, preview, canOpenThread;

  int get weight =>
      128 +
      (id.length +
              author.length +
              content.length +
              time.length +
              title.length) *
          2 +
      replies.fold<int>(0, (sum, reply) => sum + reply.weight);
}

class SourceCommentPage {
  const SourceCommentPage({
    required this.page,
    required this.items,
    this.hasMore = false,
    this.notice,
  });
  final int page;
  final List<SourceComment> items;
  final bool hasMore;
  final String? notice;

  int get weight =>
      128 +
      (notice?.length ?? 0) * 2 +
      items.fold<int>(0, (sum, comment) => sum + comment.weight);
}

abstract interface class BookCommentsSource {
  bool get supportsComments;
  List<CommentFeed> get commentFeeds => const [CommentFeed.comments];
  Future<SourceCommentPage> comments(
    String bookId, {
    int page = 1,
    CommentFeed feed = CommentFeed.comments,
    String? threadId,
  });
}

class SourceCommentException implements Exception {
  const SourceCommentException(this.message);
  final String message;
  @override
  String toString() => message;
}

void validateCommentPage(int page) {
  if (page < 1 || page > 1000) {
    throw const SourceCommentException('评论页码超出范围');
  }
}
