import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html/parser.dart' as html;
import 'package:wild/models/book_detail_hint.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'apple_glass_chrome.dart';
import 'book_cover_image.dart';
import 'material_control_motion.dart';
import 'platform_controls.dart';
import 'reader_controls.dart';

/// Source-independent presentation: only the host supplies real capabilities.
class BookDetailsView extends StatefulWidget {
  const BookDetailsView({
    super.key,
    required NovelInfo this.info,
    required this.volumes,
    required this.source,
    required ValueChanged<Chapter> this.onRead,
    this.hint,
    this.resumeChapterId,
    this.inShelf = false,
    this.onBookmark,
    this.onComments,
    this.onAuthor,
    this.onTag,
  }) : loading = null;

  const BookDetailsView.loading({
    super.key,
    required this.source,
    required this.hint,
    required Widget this.loading,
  }) : info = null,
       volumes = const [],
       onRead = null,
       resumeChapterId = null,
       inShelf = false,
       onBookmark = null,
       onComments = null,
       onAuthor = null,
       onTag = null;

  final NovelInfo? info;
  final BookDetailHint? hint;
  final Widget? loading;
  final List<Volume> volumes;
  final SourceId source;
  final ValueChanged<Chapter>? onRead;
  final String? resumeChapterId;
  final bool inShelf;
  final Future<void> Function()? onBookmark;
  final VoidCallback? onComments, onAuthor;
  final ValueChanged<String>? onTag;
  @override
  State<BookDetailsView> createState() => _BookDetailsViewState();
}

class _BookDetailsViewState extends State<BookDetailsView> {
  final _open = <int>{};
  final _volumeStarts = <int>[];
  Chapter? _firstChapter, _resumeChapter;
  int _chapterCount = 0, _rowCount = 0;
  bool _busy = false, _fullDescription = false;
  String _description = '';
  @override
  void initState() {
    super.initState();
    _description = _readDescription();
    _indexCatalog();
  }

  @override
  void didUpdateWidget(covariant BookDetailsView old) {
    super.didUpdateWidget(old);
    if (old.info?.introduce != widget.info?.introduce) {
      _description = _readDescription();
    }
    final changedBook =
        old.source != widget.source ||
        (old.info != null &&
            widget.info != null &&
            old.info?.title != widget.info?.title);
    if (changedBook) {
      _open.clear();
      _fullDescription = false;
    }
    if (changedBook || !identical(old.volumes, widget.volumes)) {
      _indexCatalog();
    } else if (old.resumeChapterId != widget.resumeChapterId) {
      _findResume(openVolume: false);
    }
  }

  String _readDescription() {
    final raw = widget.info?.introduce;
    return raw == null || raw.isEmpty ? '' : _plainIntroduction(raw);
  }

  void _indexCatalog() {
    _firstChapter = null;
    _chapterCount = 0;
    _open.removeWhere((i) => i >= widget.volumes.length);
    for (var i = 0; i < widget.volumes.length; i++) {
      final chapters = widget.volumes[i].chapters;
      _chapterCount += chapters.length;
      if (chapters.isNotEmpty) _firstChapter ??= chapters.first;
    }
    if (widget.volumes.length == 1) _open.add(0);
    _findResume(openVolume: true);
    _indexRows();
  }

  void _findResume({required bool openVolume}) {
    _resumeChapter = null;
    final id = widget.resumeChapterId;
    if (id == null) return;
    for (var i = widget.volumes.length - 1; i >= 0; i--) {
      final chapters = widget.volumes[i].chapters;
      for (var j = chapters.length - 1; j >= 0; j--) {
        if (chapters[j].cid != id) continue;
        _resumeChapter = chapters[j];
        if (openVolume) _open.add(i);
        return;
      }
    }
  }

  void _indexRows() {
    _volumeStarts.clear();
    _rowCount = 0;
    for (var i = 0; i < widget.volumes.length; i++) {
      _volumeStarts.add(_rowCount);
      _rowCount +=
          1 + (_open.contains(i) ? widget.volumes[i].chapters.length : 0);
    }
  }

  (int, Chapter?) _rowAt(int index) {
    // Only materialize rows that the sliver asks to display.
    var low = 0, high = _volumeStarts.length;
    while (high - low > 1) {
      final middle = (low + high) ~/ 2;
      if (_volumeStarts[middle] <= index) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final chapterIndex = index - _volumeStarts[low] - 1;
    return (
      low,
      chapterIndex < 0 ? null : widget.volumes[low].chapters[chapterIndex],
    );
  }

  Future<void> _bookmark() async {
    if (_busy || widget.onBookmark == null) return;
    setState(() => _busy = true);
    try {
      await widget.onBookmark!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return CustomScrollView(
      key: const PageStorageKey('book-detail-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child:
              info == null && widget.hint == null
                  ? const SizedBox.shrink()
                  : BookDetailsHeader(
                    info: info,
                    hint: widget.hint,
                    source: widget.source,
                    volumes: info == null ? null : widget.volumes.length,
                    chapters: info == null ? null : _chapterCount,
                    onAuthor: widget.onAuthor,
                  ),
        ),
        if (info == null)
          SliverFillRemaining(child: widget.loading!)
        else
          ..._details(context, info),
      ],
    );
  }

  List<Widget> _details(BuildContext context, NovelInfo info) {
    final colors = Theme.of(context).colorScheme;
    final apple = Theme.of(context).platform == TargetPlatform.iOS;
    final resume = _resumeChapter;
    final target = resume ?? _firstChapter;
    final allOpen = _open.length == widget.volumes.length;
    final actionHeight =
        apple
            ? math.max(
              56.0,
              MediaQuery.textScalerOf(context).scale(17) * 1.25 + 24,
            )
            : 56.0;
    final readContent = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          apple ? CupertinoIcons.play_fill : Icons.menu_book_rounded,
          size: 22,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            target == null
                ? '暂无可读章节'
                : resume == null
                ? '开始阅读'
                : '继续阅读',
            maxLines: apple ? 1 : 2,
            overflow: apple ? TextOverflow.ellipsis : null,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
    final actions = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.onBookmark != null) ...[
                if (apple)
                  ReaderRoundAction(
                    key: const ValueKey('detail-bookmark'),
                    size: actionHeight,
                    label: widget.inShelf ? '移出书架' : '加入书架',
                    selected: widget.inShelf,
                    icon:
                        widget.inShelf
                            ? CupertinoIcons.bookmark_fill
                            : CupertinoIcons.bookmark,
                    onPressed: _busy ? null : _bookmark,
                  )
                else
                  SizedBox(
                    key: const ValueKey('detail-bookmark'),
                    width: 56,
                    height: 56,
                    child: AppButton.tonal(
                      onPressed: _busy ? null : _bookmark,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(56, 56),
                        padding: EdgeInsets.zero,
                      ),
                      child: Center(
                        child: Semantics(
                          label: widget.inShelf ? '移出书架' : '加入书架',
                          button: true,
                          child:
                              Theme.of(context).platform ==
                                      TargetPlatform.android
                                  ? MaterialBookmarkGlyph(
                                    selected: widget.inShelf,
                                  )
                                  : Icon(
                                    widget.inShelf
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                  ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: AppButton.filled(
                  key: const ValueKey('detail-read'),
                  onPressed:
                      target == null ? null : () => widget.onRead!(target),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                    padding:
                        apple
                            ? const EdgeInsets.symmetric(horizontal: 16)
                            : null,
                  ),
                  // Give the button itself the common height so both its
                  // glass and its interactive content fill the same bounds.
                  child:
                      apple
                          ? SizedBox(height: actionHeight, child: readContent)
                          : readContent,
                ),
              ),
            ],
          ),
          if (resume != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                resume.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
    return [
      SliverToBoxAdapter(child: actions),
      if (info.tags.any((t) => t.trim().isNotEmpty))
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in info.tags.where((t) => t.trim().isNotEmpty))
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    customBorder: apple ? const StadiumBorder() : null,
                    onTap:
                        widget.onTag == null ? null : () => widget.onTag!(tag),
                    child: AppChip(
                      capsule: apple,
                      padding:
                          apple
                              ? const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              )
                              : null,
                      label: Text(tag),
                      backgroundColor: colors.primaryContainer,
                      labelStyle: TextStyle(color: colors.onPrimaryContainer),
                    ),
                  ),
              ],
            ),
          ),
        ),
      if (_description.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('简介', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                if (_fullDescription)
                  Html(
                    data: info.introduce,
                    style: {
                      'body': Style(
                        margin: Margins.zero,
                        padding: HtmlPaddings.zero,
                        color: colors.onSurface,
                        fontFamily:
                            Theme.of(context).textTheme.bodyMedium?.fontFamily,
                        fontSize: FontSize(15),
                      ),
                    },
                  )
                else
                  Text(
                    _description,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(height: 1.65),
                  ),
                if (_description.length > 150)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: AppButton.text(
                      onPressed:
                          () => setState(
                            () => _fullDescription = !_fullDescription,
                          ),
                      child: Text(_fullDescription ? '收起简介' : '展开简介'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '目录',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (widget.volumes.isNotEmpty)
                Text(
                  '${widget.volumes.length} 卷 · $_chapterCount 章',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
      if (widget.volumes.length > 1)
        SliverToBoxAdapter(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AppButton.text(
                onPressed:
                    () => setState(() {
                      if (allOpen) {
                        _open.clear();
                      } else {
                        for (var i = 0; i < widget.volumes.length; i++) {
                          _open.add(i);
                        }
                      }
                      _indexRows();
                    }),
                child: Text(allOpen ? '收起全部' : '展开全部'),
              ),
            ),
          ),
        ),
      if (_rowCount == 0)
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(24), child: Text('暂无目录')),
        ),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final (volumeIndex, chapter) = _rowAt(index);
          final volume = widget.volumes[volumeIndex];
          if (chapter == null) {
            return AppleGlassCard(
              key: ValueKey('volume-row-$volumeIndex'),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('volume-$volumeIndex'),
                onTap:
                    () => setState(() {
                      if (!_open.remove(volumeIndex)) _open.add(volumeIndex);
                      _indexRows();
                    }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 18,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          volume.title.trim().isEmpty ? '正文' : volume.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${volume.chapters.length} 章',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      AnimatedRotation(
                        turns: _open.contains(volumeIndex) ? .5 : 0,
                        duration:
                            MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 160),
                        curve: Curves.easeOutQuad,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          final current = chapter.cid == widget.resumeChapterId;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Material(
              color: current ? colors.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                key: ValueKey('chapter-$volumeIndex-${chapter.cid}'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => widget.onRead!(chapter),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 16,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          chapter.title,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color:
                                current
                                    ? colors.onPrimaryContainer
                                    : colors.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        current
                            ? Icons.bookmark_rounded
                            : Icons.chevron_right_rounded,
                        size: 18,
                        color: colors.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }, childCount: _rowCount),
      ),
      const SliverToBoxAdapter(
        child: SafeArea(top: false, child: SizedBox(height: 32)),
      ),
    ];
  }
}

String _plainIntroduction(String raw) {
  final body = html.parseFragment(raw);
  for (final e in body.querySelectorAll('script,style')) {
    e.remove();
  }
  for (final e in body.querySelectorAll('br')) {
    e.replaceWith(html.parseFragment('\n'));
  }
  for (final e in body.querySelectorAll('p,div,li')) {
    e.append(html.parseFragment('\n'));
  }
  return (body.text ?? '')
      .replaceFirst(RegExp(r'^\s*(?:作品)?简介\s*[:：]?\s*(?:\n|$)'), '')
      .trim();
}

class BookDetailsHeader extends StatefulWidget {
  const BookDetailsHeader({
    super.key,
    this.info,
    this.hint,
    required this.source,
    this.volumes,
    this.chapters,
    this.onAuthor,
  });
  final NovelInfo? info;
  final BookDetailHint? hint;
  final SourceId source;
  final int? volumes, chapters;
  final VoidCallback? onAuthor;
  String get _coverUrl {
    final url = info?.imgUrl ?? '';
    return url.isEmpty ? hint?.coverUrl ?? '' : url;
  }

  @override
  State<BookDetailsHeader> createState() => _BookDetailsHeaderState();
}

class _BookDetailsHeaderState extends State<BookDetailsHeader> {
  final _coverColor = ValueNotifier<Color?>(null);
  @override
  void didUpdateWidget(covariant BookDetailsHeader old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source || old._coverUrl != widget._coverUrl) {
      _coverColor.value = null;
    }
  }

  @override
  void dispose() {
    _coverColor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme,
        apple = Theme.of(context).platform == TargetPlatform.iOS;
    final info = widget.info;
    final title = info?.title ?? widget.hint?.title ?? '作品详情';
    final cover = widget._coverUrl;
    final author = info?.author.trim() ?? '',
        status = info?.status.trim() ?? '';
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth >= 700
                ? 166.0
                : constraints.maxWidth < 350
                ? 96.0
                : 112.0;
        final content = Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: width,
                height: width * 1.5,
                child: BookCoverImage(
                  key: ValueKey('${widget.source.name}:$cover'),
                  source: widget.source,
                  url: cover,
                  preferPaintedSize: true,
                  fit: BoxFit.contain,
                  borderRadius: BorderRadius.circular(apple ? 10 : 16),
                  onColor: apple ? (color) => _coverColor.value = color : null,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    if (author.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: apple ? 8 : 12),
                        child: GestureDetector(
                          onTap: widget.onAuthor,
                          child: Text(
                            author,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.copyWith(
                              color:
                                  widget.onAuthor == null
                                      ? colors.onSurfaceVariant
                                      : colors.primary,
                            ),
                          ),
                        ),
                      ),
                    if (apple) ...[
                      const SizedBox(height: 10),
                      _DetailMetadata([
                        widget.source.label,
                        if (status.isNotEmpty) status,
                        if (info?.isAnimated ?? false) '动画化',
                      ]),
                      if (info?.finUpdate.trim().isNotEmpty ?? false)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _DetailMetadata([
                            '更新 ${info!.finUpdate.trim()}',
                          ]),
                        ),
                    ] else ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.source.label,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.primary),
                      ),
                      if (status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            status,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      if (widget.volumes != null && widget.chapters != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${widget.volumes} 卷 · ${widget.chapters} 章',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      if (info?.finUpdate.trim().isNotEmpty ?? false)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '更新 ${info!.finUpdate}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      if (info?.isAnimated ?? false)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '动画化',
                            style: TextStyle(color: colors.primary),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
        if (!apple) {
          return Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            clipBehavior: Clip.antiAlias,
            child: content,
          );
        }
        final strength =
            Theme.of(context).brightness == Brightness.dark ? .18 : .11;
        return ValueListenableBuilder<Color?>(
          valueListenable: _coverColor,
          builder:
              (_, color, child) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        (color ?? colors.primary).withValues(alpha: strength),
                        colors.surface,
                      ),
                      colors.surface,
                    ],
                  ),
                ),
                child: child,
              ),
          child: content,
        );
      },
    );
  }
}

class _DetailMetadata extends StatelessWidget {
  const _DetailMetadata(this.values);
  final List<String> values;

  @override
  Widget build(BuildContext context) => Text(
    values.join(' · '),
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      height: 1.4,
    ),
  );
}
