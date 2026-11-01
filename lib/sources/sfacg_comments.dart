import 'dart:convert';
import 'package:wild/models/source_comment.dart';
import 'package:wild/services/read_request.dart';
import 'comment_parsers.dart';
import 'rules/rule_source_engine.dart';

/// Read-only endpoints observed in SF's own request-1.0.16.js. The owning
/// rule adapter supplies its existing same-origin transport and cooldown.
class SfacgComments {
  const SfacgComments(this.transport);
  final RuleSourceTransport transport;

  Future<SourceCommentPage> load(
    String bookNumber, {
    int page = 1,
    CommentFeed feed = CommentFeed.comments,
    String? threadId,
  }) async {
    validateCommentPage(page);
    if (!RegExp(r'^[1-9]\d{0,11}$').hasMatch(bookNumber) ||
        (threadId != null && !RegExp(r'^[1-9]\d{0,11}$').hasMatch(threadId))) {
      throw const SourceCommentException('SF 评论编号无效');
    }
    final scope = ReadRequest.current;
    scope?.check();
    final uri = Uri.https('book.sfacg.com', '/ajax/ashx/Common.ashx', {
      'op': threadId == null ? 'getcmtlist' : 'getCmtReply',
      if (threadId == null) ...{
        'nid': bookNumber,
        'ctype': feed == CommentFeed.reviews ? 'long' : 'short',
        'len': '32768',
        'so': 'addtime',
      } else ...{
        'cid': threadId,
        'order': 'asc',
      },
      // The website's index starts at zero, Flutter's starts at one.
      'pi': '${page - 1}', 'ps': '20',
    });
    final response = await transport.get(
      uri,
      timeout: const Duration(seconds: 12),
      maxBytes: 1024 * 1024,
    );
    scope?.check();
    if (response.statusCode != 200) {
      throw SourceCommentException('SF 评论加载失败（HTTP ${response.statusCode}）');
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(response.bytes));
    } on FormatException {
      throw const SourceCommentException('SF 原站未返回有效评论，请稍后重试');
    }
    return sfComments(data, page, replies: threadId != null);
  }
}
