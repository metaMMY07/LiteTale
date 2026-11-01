import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wild/models/source_comment.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/widgets/wenku8_recovery_button.dart';

typedef ReviewsLoader =
    Future<SourceCommentPage> Function(
      String bookId, {
      int page,
      CommentFeed feed,
      String? threadId,
      bool refresh,
    });

class ReviewsPage extends StatefulWidget {
  const ReviewsPage({
    super.key,
    required this.aid,
    required this.title,
    this.loader = api.loadBookComments,
    this.feeds,
    this.threadId,
    this.parentComment,
  });
  final String aid, title;
  final ReviewsLoader loader;
  final List<CommentFeed>? feeds;
  final String? threadId;
  final SourceComment? parentComment;

  @override
  State<ReviewsPage> createState() => _ReviewsPageState();
}

class _ReviewsPageState extends State<ReviewsPage> {
  final _scroll = ScrollController();
  List<SourceComment> _items = const [];
  CommentFeed _feed = CommentFeed.comments;
  int _page = 0, _serial = 0;
  bool _loading = false, _hasMore = false, _loaded = false;
  bool _retryRefresh = false;
  String? _notice;
  Object? _error;
  ReadRequest? _request;

  List<CommentFeed> get _feeds =>
      widget.threadId == null
          ? widget.feeds ?? api.sourceCommentFeeds(widget.aid)
          : const [CommentFeed.comments];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ReviewsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aid != widget.aid || oldWidget.threadId != widget.threadId) {
      _reset();
      unawaited(_load());
    }
  }

  void _reset() {
    _request?.cancel();
    _serial++;
    _items = const [];
    _page = 0;
    _loading = false;
    _hasMore = false;
    _loaded = false;
    _notice = null;
    _error = null;
    _retryRefresh = false;
    _feed = CommentFeed.comments;
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 240 &&
        _loaded &&
        _hasMore &&
        !_loading &&
        _error == null) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh) return;
    _request?.cancel();
    final request = _request = ReadRequest();
    final serial = ++_serial;
    final book = widget.aid;
    final session = api.readerSessionGeneration(book);
    final next = refresh || !_loaded ? 1 : _page + 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ReadRequest.run(
        request,
        () => request.wait(
          widget.loader(
            book,
            page: next,
            feed: _feed,
            threadId: widget.threadId,
            refresh: refresh,
          ),
        ),
      );
      if (!mounted || serial != _serial || request.isCancelled) return;
      if (session != api.readerSessionGeneration(book)) {
        throw const SourceCommentException('书源或账号已变化，请刷新评论');
      }
      if (result.page != next) {
        throw const SourceCommentException('原站返回的评论页码不匹配');
      }
      final existing = next == 1 ? <SourceComment>[] : _items;
      final seen = existing.map((c) => c.id).toSet();
      final added = result.items.where((c) => seen.add(c.id)).toList();
      if (next > 1 && result.hasMore && added.isEmpty) {
        throw const SourceCommentException('原站返回了重复评论，请稍后重试');
      }
      final combined = [...existing, ...added];
      if (combined.length > 2000 ||
          combined.fold<int>(0, (n, c) => n + c.weight) > 4 * 1024 * 1024) {
        throw const SourceCommentException('本次已加载较多评论，请刷新后查看最新评论');
      }
      setState(() {
        _items = combined;
        _page = result.page;
        _hasMore = result.hasMore;
        _notice = result.notice;
        _loaded = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || serial != _serial || request.isCancelled) return;
      setState(() {
        _loading = false;
        _error = error;
        _retryRefresh = refresh;
        if (session != api.readerSessionGeneration(book)) {
          _items = const [];
          _page = 0;
          _hasMore = false;
          _loaded = false;
        }
      });
    }
  }

  Future<void> _refresh() => _load(refresh: true);

  void _changeFeed(Set<CommentFeed> selected) {
    final next = selected.single;
    if (next == _feed) return;
    setState(() {
      _reset();
      _feed = next;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load());
  }

  @override
  void dispose() {
    _serial++;
    _request?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Widget _errorView() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        const Icon(Icons.chat_bubble_outline, size: 32),
        const SizedBox(height: 12),
        Text('评论加载失败', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('$_error', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        AppButton.tonal(
          onPressed:
              _loading ? null : () => _load(refresh: _retryRefresh || !_loaded),
          child: const Text('重试'),
        ),
        Wenku8RecoveryButton(
          error: _error,
          source: sourceOf(widget.aid),
          onRecovered: _refresh,
        ),
        BiliRecoveryButton(
          error: _error,
          source: sourceOf(widget.aid),
          onRecovered: _refresh,
        ),
        SourceWebsiteLink(source: sourceOf(widget.aid)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = sourceOf(widget.aid);
    return Scaffold(
      appBar: AppBar(title: Text(widget.threadId == null ? '评论' : '评论回复')),
      body:
          !_loaded && _loading
              ? SourceLoadingIndicator(source: source, requestKey: _request)
              : RefreshIndicator.adaptive(
                onRefresh: _refresh,
                child: ListView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    24 + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    Text(widget.title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      '${source.label} · 原站评论',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (_feeds.length > 1) ...[
                      const SizedBox(height: 16),
                      AppSegmentedButton<CommentFeed>(
                        segments: const [
                          ButtonSegment(
                            value: CommentFeed.comments,
                            label: Text('简评'),
                          ),
                          ButtonSegment(
                            value: CommentFeed.reviews,
                            label: Text('书评'),
                          ),
                        ],
                        selected: {_feed},
                        onSelectionChanged: _changeFeed,
                      ),
                    ],
                    if (_notice != null && _notice!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(_notice!, style: theme.textTheme.bodyMedium),
                    ],
                    if (widget.parentComment case final parent?)
                      _CommentTile(comment: parent),
                    const SizedBox(height: 12),
                    if (_loaded &&
                        _items.isEmpty &&
                        _notice == null &&
                        _error == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: Text('暂无评论')),
                      ),
                    for (final comment in _items)
                      _CommentTile(
                        key: ValueKey(
                          '${widget.aid}:${_feed.name}:${comment.id}',
                        ),
                        comment: comment,
                        onReplies:
                            !comment.canOpenThread
                                ? null
                                : () => Navigator.of(context).push(
                                  HorizontalCoverPageRoute(
                                    builder:
                                        (_) => ReviewsPage(
                                          aid: widget.aid,
                                          title: widget.title,
                                          threadId: comment.id,
                                          parentComment: comment,
                                          loader: widget.loader,
                                        ),
                                  ),
                                ),
                      ),
                    if (_error != null) _errorView(),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: AppLoadingIndicator()),
                      )
                    else if (_hasMore && _error == null)
                      AppButton.text(
                        onPressed: _load,
                        child: const Text('加载更多评论'),
                      ),
                  ],
                ),
              ),
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({super.key, required this.comment, this.onReplies});
  final SourceComment comment;
  final VoidCallback? onReplies;
  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  bool _revealed = false, _expanded = false, _replies = false;
  @override
  void didUpdateWidget(_CommentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comment != widget.comment) {
      _revealed = false;
      _expanded = false;
      _replies = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final theme = Theme.of(context);
    return AppleGlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comment.author.isEmpty ? '匿名读者' : comment.author,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (comment.time.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(comment.time, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            if (comment.spoiler && !_revealed)
              AppButton.tonal(
                onPressed: () => setState(() => _revealed = true),
                child: const Text('含剧透，点击查看'),
              )
            else ...[
              if (comment.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    comment.title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              SelectableText(
                comment.content,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                maxLines: !_expanded && comment.content.length > 450 ? 8 : null,
              ),
              if (comment.content.length > 450)
                AppButton.text(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? '收起' : '展开全文'),
                ),
              if (comment.preview)
                Text('原站公开摘要', style: theme.textTheme.bodySmall),
              if (comment.replies.isNotEmpty)
                AppButton.text(
                  onPressed: () => setState(() => _replies = !_replies),
                  child: Text(
                    _replies
                        ? '收起回复 / 引用'
                        : '查看回复 / 引用（${comment.replies.length}）',
                  ),
                ),
              if (_replies)
                for (final reply in comment.replies)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.05,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${reply.title.isEmpty ? '' : '${reply.title} · '}${reply.author}',
                          style: theme.textTheme.labelLarge,
                        ),
                        if (reply.time.isNotEmpty)
                          Text(reply.time, style: theme.textTheme.bodySmall),
                        const SizedBox(height: 6),
                        SelectableText(
                          reply.content,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
              if (widget.onReplies != null)
                AppButton.text(
                  onPressed: widget.onReplies,
                  child: Text('查看回复（${comment.replyCount}）'),
                )
              else if (comment.replyCount > 0 && comment.replies.isEmpty)
                Text(
                  '${comment.replyCount} 条原站回复',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
