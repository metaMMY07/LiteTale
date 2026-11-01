import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/models/source_comment.dart';

/// Convert public comment markup to inert text while retaining paragraphs.
/// Avatar URLs and inline remote images are deliberately not fetched.
String commentText(String markup, {int maxLength = 32768}) {
  if (markup.length > 128 * 1024) {
    throw const SourceCommentException('原站评论内容超过大小上限');
  }
  final fragment = html.parseFragment(markup);
  final output = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      output.write(node.text);
    } else if (node is dom.Element) {
      if (const {
        'script',
        'style',
        'iframe',
        'form',
        'button',
        'input',
        'svg',
        'object',
        'embed',
        'noscript',
      }.contains(node.localName)) {
        return;
      }
      if (node.localName == 'img') {
        output.write(node.attributes['alt'] ?? '[图片]');
        return;
      }
      if (node.localName == 'br') output.writeln();
      for (final child in node.nodes) {
        walk(child);
      }
      if (const {'p', 'div', 'li', 'blockquote'}.contains(node.localName)) {
        output.writeln();
      }
    }
  }

  for (final child in fragment.nodes) {
    walk(child);
  }
  final text =
      output
          .toString()
          .replaceAll('\u00a0', ' ')
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .replaceAll(RegExp(r' *\n *'), '\n')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
  if (text.length > maxLength) {
    throw const SourceCommentException('原站评论内容超过大小上限');
  }
  return text;
}

String _plain(Object? value, {int max = 32768}) {
  if (value == null) return '';
  if (value is! String || value.length > max) {
    throw const SourceCommentException('原站评论字段格式异常');
  }
  return value.trim();
}

int _count(Object? value, {int fallback = 0}) {
  if (value == null) return fallback;
  final n = value is int ? value : int.tryParse('$value');
  if (n == null || n < 0 || n > 10000000) {
    throw const SourceCommentException('原站评论分页格式异常');
  }
  return n;
}

Map _map(Object? value) {
  if (value is! Map) throw const SourceCommentException('原站评论响应不完整');
  return value;
}

List _list(Object? value, {int max = 100}) {
  if (value is! List || value.length > max) {
    throw const SourceCommentException('原站评论列表格式异常');
  }
  return value;
}

/// LightNovelShelf's GetComments contract (Book + Id + Page). Dictionary keys
/// remain string IDs after the source's PascalCase field normalization.
SourceCommentPage shelfComments(Object? value, int requestedPage) {
  final data = _map(value);
  final users = _map(data['Users']);
  final commentaries = _map(data['Commentaries']);
  final roots = _list(data['Data']);
  final page = _count(data['Page']);
  final maximum = _count(data['TotalPages']);
  if (page != requestedPage || (maximum > 0 && page > maximum)) {
    throw const SourceCommentException('轻书架返回的评论页码不匹配');
  }
  SourceComment read(
    Object? id, {
    bool withReplies = false,
    List ids = const [],
  }) {
    final numeric = _count(id);
    if (numeric == 0) throw const SourceCommentException('轻书架评论编号缺失');
    final row = _map(commentaries['$numeric']);
    final user = _map(users['${_count(row['UserId'])}']);
    final replyTo = row['ReplyId'];
    String prefix = '';
    if (replyTo != null &&
        _count(replyTo) > 0 &&
        commentaries['$replyTo'] is Map) {
      final parent = _map(commentaries['$replyTo']);
      final target = users['${_count(parent['UserId'])}'];
      if (target is Map) prefix = '回复 ${_plain(target['UserName'], max: 256)}：';
    }
    return SourceComment(
      id: '$numeric',
      author: _plain(user['UserName'], max: 256),
      // Shelf comment Content is plain text, not HTML. Keep literal < and &.
      content: '$prefix${_plain(row['Content'])}',
      time: _plain(row['CreatedAt'], max: 128),
      replyCount: ids.length,
      replies:
          withReplies ? List.unmodifiable(ids.map((id) => read(id))) : const [],
    );
  }

  final seen = <String>{};
  final items = <SourceComment>[];
  for (final rootValue in roots) {
    final root = _map(rootValue);
    final ids = _list(root['Reply'] ?? [], max: 200);
    final comment = read(root['Id'], withReplies: true, ids: ids);
    if (seen.add(comment.id)) items.add(comment);
  }
  return SourceCommentPage(
    page: page,
    items: List.unmodifiable(items),
    hasMore: page < maximum,
  );
}

/// LNovel currently embeds the complete comment list on the book detail. The
/// quoted row inside a comment is a quote, not another top-level comment.
SourceCommentPage lnovelComments(dom.Document document) {
  final article = document.querySelector('main article');
  final heading =
      article
          ?.querySelectorAll('h2')
          .where((e) => const {'評論', '评论'}.contains(e.text.trim()))
          .firstOrNull;
  if (article == null || heading == null) {
    throw const SourceCommentException('轻小说百科评论区格式已变化');
  }
  final rows = article.querySelectorAll('div.row.g-3.mb-2');
  if (rows.length > 500) {
    throw const SourceCommentException('轻小说百科评论数量超过本页上限');
  }
  final result = <SourceComment>[];
  for (final row in rows) {
    final meta = row.querySelector('.row.mb-1.small');
    final content = row.querySelector('.border-bottom');
    if (meta == null || content == null) continue;
    final author = meta.children.firstOrNull?.text.trim() ?? '';
    final time = meta.querySelector('.text-end')?.text.trim() ?? '';
    final quote = row.querySelector('.bg-body-tertiary .row.g-2');
    final body = commentText(content.innerHtml);
    result.add(
      SourceComment(
        id: '${result.length}:$author:$time',
        author: author,
        content: body,
        time: time,
        replies:
            quote == null
                ? const []
                : [
                  SourceComment(
                    id: 'quote:${result.length}',
                    author: quote.querySelector('.col-auto')?.text.trim() ?? '',
                    content: commentText(
                      quote.querySelector('.col')?.innerHtml ?? '',
                    ),
                    title: '引用',
                  ),
                ],
      ),
    );
  }
  return SourceCommentPage(page: 1, items: List.unmodifiable(result));
}

SourceCommentPage biliComments(
  dom.Document document,
  String bookNumber,
  int page,
) {
  final root = document.querySelector('#list_content.book-ol-comment');
  if (root == null) {
    throw const SourceCommentException('哔哩原站未返回评论列表，请稍后重试');
  }
  final rows = root.querySelectorAll('li.book-li');
  if (rows.length > 100) throw const SourceCommentException('哔哩评论列表过大');
  final seen = <String>{};
  final items = <SourceComment>[];
  for (final row in rows) {
    final link = row.querySelector('a.book-layout[href]');
    final path = link?.attributes['href'] ?? '';
    final match = RegExp(r'^/reviewshow_([1-9]\d*)_1\.html$').firstMatch(path);
    final body = row.querySelector('.book-comment-p');
    if (match == null || body == null || !seen.add(match[1]!)) continue;
    final metrics = row.querySelector('.book-meta-r')?.text ?? '';
    final replies = RegExp(r'\d+/(\d+)').firstMatch(metrics);
    final content = commentText(body.innerHtml);
    items.add(
      SourceComment(
        id: match[1]!,
        author:
            row.querySelector('.book-meta-l > em')?.text.trim() ??
            row.querySelector('.book-meta-l')?.text.trim() ??
            '',
        content: content,
        time: row.querySelector('time')?.text.trim() ?? '',
        replyCount: int.tryParse(replies?[1] ?? '') ?? 0,
        spoiler:
            body.attributes['data-netabare'] == 'true' ||
            row.querySelector('.ispoiler') != null,
        preview: content.endsWith('...') || content.endsWith('…'),
        canOpenThread: false,
      ),
    );
  }
  if (rows.isNotEmpty && items.isEmpty) {
    throw const SourceCommentException('哔哩评论结构已变化');
  }
  final nextPath = '/reviews_${bookNumber}_${page + 1}.html';
  final hasMore = document
      .querySelectorAll('a[href]')
      .any((a) => a.attributes['href'] == nextPath);
  return SourceCommentPage(
    page: page,
    items: List.unmodifiable(items),
    hasMore: hasMore,
    notice:
        items.any((c) => c.preview || c.replyCount > 0)
            ? '此处显示原站公开书评。原站完整长评及回复需要登录。'
            : null,
  );
}

/// SF's public Common.ashx API, used by its own detail page. A maintenance
/// announcement with CommentID=0 is status, never a reader's comment.
SourceCommentPage sfComments(Object? value, int page, {bool replies = false}) {
  final data = _map(value);
  if (data['status'] != 200) {
    throw const SourceCommentException('SF 原站评论暂不可用，请稍后重试');
  }
  final rows = _list(data[replies ? 'Replys' : 'Cmts']);
  final items = <SourceComment>[];
  String? notice;
  for (final raw in rows) {
    final row = _map(raw);
    final id = _count(row['CommentID']);
    final content = commentText(_plain(row['Content'], max: 128 * 1024));
    if (id == 0) {
      notice = content;
      continue;
    }
    items.add(
      SourceComment(
        id: '$id',
        author: _plain(row['DisplayName'], max: 256),
        content: content,
        title: _plain(row['Title'], max: 512),
        time: _plain(row['CreateTime'], max: 128),
        replyCount: _count(row['ReplyNum']),
        canOpenThread: !replies && _count(row['ReplyNum']) > 0,
      ),
    );
  }
  return SourceCommentPage(
    page: page,
    items: List.unmodifiable(items),
    hasMore: notice == null && rows.length == 20,
    notice: notice,
  );
}
