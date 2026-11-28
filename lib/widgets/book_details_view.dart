import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html/parser.dart' as html;
import 'package:wild/models/book_detail_hint.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'apple_glass_chrome.dart';
import 'book_cover_image.dart';
import 'ios_solid_surface.dart';
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
       onAuthor = null;

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
  @override
  State<BookDetailsView> createState() => _BookDetailsViewState();
}

class _BookDetailsViewState extends State<BookDetailsView> {
  final _scrollController = ScrollController();
  final _open = <int>{};
  final _volumeStarts = <int>[];
  Chapter? _firstChapter, _resumeChapter;
  int _chapterCount = 0, _rowCount = 0;
  bool _busy = false;
  String _description = '';
  ui.Image? _backdropImage;
  String _backdropIdentity = '';

  String _backdropIdentityFor() =>
      '${widget.source.name}:${sourceRevision.value}:${_effectiveCoverUrl(widget.info, widget.hint)}';

  @override
  void initState() {
    super.initState();
    _backdropIdentity = _backdropIdentityFor();
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
    }
    final nextBackdropIdentity = _backdropIdentityFor();
    if (nextBackdropIdentity != _backdropIdentity) {
      _backdropIdentity = nextBackdropIdentity;
      _replaceBackdrop(null);
    }
    if (changedBook || !identical(old.volumes, widget.volumes)) {
      _indexCatalog();
    } else if (old.resumeChapterId != widget.resumeChapterId) {
      _findResume(openVolume: false);
    }
  }

  void _onBackdropChanged(ui.Image? image) {
    if (!mounted) return;
    _backdropIdentity = _backdropIdentityFor();
    if (image == null && _backdropImage == null) return;
    setState(() => _replaceBackdrop(image?.clone()));
  }

  void _replaceBackdrop(ui.Image? image) {
    final previous = _backdropImage;
    _backdropImage = image;
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _backdropImage?.dispose();
    super.dispose();
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
    final theme = Theme.of(context);
    final apple = theme.platform == TargetPlatform.iOS;
    final info = widget.info;
    final topBoundary = apple ? MediaQuery.paddingOf(context).top : 0.0;
    final scrollView = CustomScrollView(
      key: const PageStorageKey('book-detail-scroll'),
      controller: apple ? _scrollController : null,
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
                    renderBackdrop: !apple,
                    onBackdropChanged: apple ? _onBackdropChanged : null,
                  ),
        ),
        if (info == null)
          SliverFillRemaining(child: widget.loading!)
        else
          ..._details(context, info),
      ],
    );
    if (!apple) return scrollView;
    final pageBg = theme.scaffoldBackgroundColor;
    final dark = theme.brightness == Brightness.dark;
    final cover = _effectiveCoverUrl(info, widget.hint);
    final showBackdrop = cover.isNotEmpty && _backdropImage != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final headerWidth =
            constraints.maxWidth >= 700
                ? 166.0
                : constraints.maxWidth < 350
                ? 96.0
                : 112.0;
        final baseBackdropHeight = topBoundary + headerWidth * 1.5 + 48;
        return ColoredBox(
          color: pageBg,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: _scrollController,
                      builder: (context, child) {
                        final offset =
                            _scrollController.hasClients
                                ? _scrollController.offset
                                : 0.0;
                        final top = offset > 0 ? -offset : 0.0;
                        final height =
                            baseBackdropHeight + (offset < 0 ? -offset : 0.0);
                        return Stack(
                          children: [
                            Positioned(
                              top: top,
                              left: 0,
                              right: 0,
                              height: height,
                              child: child!,
                            ),
                          ],
                        );
                      },
                      child: AnimatedOpacity(
                        duration:
                            MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        opacity: showBackdrop ? 1 : 0,
                        child:
                            !showBackdrop
                                ? const SizedBox.expand()
                                : _BookDetailsCoverBackdrop(
                                  image: _backdropImage!,
                                  pageBg: pageBg,
                                  dark: dark,
                                ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                top: topBoundary,
                child: ClipRect(
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: scrollView,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _details(BuildContext context, NovelInfo info) {
    final colors = Theme.of(context).colorScheme;
    final apple = Theme.of(context).platform == TargetPlatform.iOS;
    final resume = _resumeChapter;
    final target = resume ?? _firstChapter;
    final allOpen = _open.length == widget.volumes.length;
    final captionStyle = (Theme.of(context).textTheme.bodySmall ??
            const TextStyle())
        .copyWith(color: colors.onSurfaceVariant);
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
    final VoidCallback? onRead =
        target == null ? null : () => widget.onRead!(target);
    final readStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, 56),
      padding: apple ? const EdgeInsets.symmetric(horizontal: 16) : null,
    );
    final readButton =
        apple
            ? IosSolidPillButton(
              key: const ValueKey('detail-read'),
              minHeight: actionHeight,
              onPressed: onRead,
              child: readContent,
            )
            : AppButton.filled(
              key: const ValueKey('detail-read'),
              onPressed: onRead,
              style: readStyle,
              child: readContent,
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
                    symbol: widget.inShelf ? 'bookmark.fill' : 'bookmark',
                    tint: widget.inShelf ? colors.primary : null,
                    preserveTint: widget.inShelf,
                    color: widget.inShelf ? colors.onPrimary : colors.onSurface,
                    keepGlassInSheets: true,
                    keepGlassInHorizontalCover: true,
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
              Expanded(child: readButton),
            ],
          ),
          // Keep the rows below the button still when reading progress arrives.
          if (apple || resume != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                resume?.title ?? '\u00a0',
                semanticsLabel: resume == null ? '' : null,
                maxLines: apple ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: captionStyle,
                strutStyle:
                    apple
                        ? StrutStyle.fromTextStyle(
                          captionStyle,
                          forceStrutHeight: true,
                        )
                        : null,
              ),
            ),
        ],
      ),
    );
    return [
      SliverToBoxAdapter(child: actions),
      if (_description.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: InkWell(
              key: const ValueKey('detail-introduction'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => _showIntroduction(context, info.introduce),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '简介',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _description,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
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
                style:
                    apple
                        ? TextButton.styleFrom(
                          foregroundColor: colors.onSurface,
                        )
                        : null,
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
            return IosSolidCard(
              key: ValueKey('volume-row-$volumeIndex'),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              clipBehavior: Clip.antiAlias,
              pressFeedback: true,
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
                          color:
                              apple ? colors.onSurfaceVariant : colors.primary,
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
              clipBehavior: Clip.antiAlias,
              child: IosPressFeedback(
                passive: true,
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

class BookDetailTagsButton extends StatelessWidget {
  const BookDetailTagsButton({
    super.key,
    required this.tags,
    this.onTag,
    this.color,
    this.iconSize,
  });

  final List<String> tags;
  final ValueChanged<String>? onTag;
  final Color? color;
  final double? iconSize;

  Set<String> get _labels => {
    for (final tag in tags)
      if (tag.trim().isNotEmpty) tag.trim(),
  };

  Future<void> showTags(BuildContext context) async {
    final labels = _labels;
    if (labels.isEmpty) return;
    final tag = await _showBookInfoSheet<String>(
      context,
      (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .6,
        ),
        child: SingleChildScrollView(
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _BookInfoSheetHeading(
                  title: '书籍标签',
                  icon: Icons.sell_outlined,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final label in labels)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap:
                            onTag == null
                                ? null
                                : () => Navigator.pop(sheetContext, label),
                        child: Ink(
                          decoration: BoxDecoration(
                            color: Theme.of(sheetContext).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(sheetContext).dividerColor,
                              width: 0,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text(label),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      enableDrag: true,
    );
    if (tag != null &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent != false) {
      onTag?.call(tag);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_labels.isEmpty) return const SizedBox.shrink();
    return AppIconButton(
      tooltip: '书籍标签',
      color: color,
      iconSize: iconSize,
      icon: Icon(usesAppleGlass ? CupertinoIcons.tag : Icons.sell_outlined),
      onPressed: () => showTags(context),
    );
  }
}

Future<void> _showIntroduction(BuildContext context, String introduction) =>
    _showBookInfoSheet<void>(
      context,
      (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .5,
        minChildSize: .5,
        maxChildSize: 1,
        snap: true,
        builder: (context, controller) {
          final theme = Theme.of(context);
          return ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              const _BookInfoSheetHeading(
                title: '简介',
                icon: Icons.description_outlined,
              ),
              SelectionArea(
                child: Html(
                  data: introduction,
                  style: {
                    'body': Style(
                      margin: Margins.zero,
                      padding: HtmlPaddings.zero,
                      color: theme.colorScheme.onSurface,
                      fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                      fontSize: FontSize(16),
                    ),
                  },
                ),
              ),
            ],
          );
        },
      ),
      enableDrag: false,
    );

Future<T?> _showBookInfoSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  required bool enableDrag,
}) async {
  final navigator = Navigator.of(context);
  final apple = usesAppleGlass;
  final route = ModalBottomSheetRoute<T>(
    builder: builder,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: enableDrag,
    showDragHandle: false,
    clipBehavior: Clip.antiAlias,
    backgroundColor: apple ? Theme.of(context).scaffoldBackgroundColor : null,
    shape:
        apple
            ? const ContinuousRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(36)),
            )
            : null,
    sheetAnimationStyle:
        MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

class _BookInfoSheetHeading extends StatelessWidget {
  const _BookInfoSheetHeading({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 36,
            height: 5,
            margin: const EdgeInsets.only(top: 8, bottom: 16),
            decoration: ShapeDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .4),
              shape: const StadiumBorder(),
            ),
          ),
        ),
        Row(
          children: [
            Icon(icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
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

String _effectiveCoverUrl(NovelInfo? info, BookDetailHint? hint) {
  final url = info?.imgUrl ?? '';
  return url.isEmpty ? hint?.coverUrl ?? '' : url;
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
    this.coverImageProvider,
    this.renderBackdrop = true,
    this.onBackdropChanged,
  });
  final NovelInfo? info;
  final BookDetailHint? hint;
  final SourceId source;
  final int? volumes, chapters;
  final VoidCallback? onAuthor;
  final ImageProvider? coverImageProvider;
  final bool renderBackdrop;
  final ValueChanged<ui.Image?>? onBackdropChanged;
  String get _coverUrl => _effectiveCoverUrl(info, hint);

  @override
  State<BookDetailsHeader> createState() => _BookDetailsHeaderState();
}

class _BookDetailsHeaderState extends State<BookDetailsHeader> {
  static const int _kBackdropWidth = 160;
  static const int _kBackdropHeight = 240;
  static const double _kBackdropBlurSigma = 4.2;

  ui.Image? _backdropImage;
  int _backdropGeneration = 0;
  String _backdropIdentity = '';

  String _currentIdentity() =>
      '${widget.source.name}:${sourceRevision.value}:${widget._coverUrl}';

  @override
  void initState() {
    super.initState();
    _backdropIdentity = _currentIdentity();
    sourceRevision.addListener(_onSourceRevisionChanged);
  }

  void _onSourceRevisionChanged() {
    final nextIdentity = _currentIdentity();
    if (nextIdentity == _backdropIdentity) return;
    ++_backdropGeneration;
    _backdropIdentity = nextIdentity;
    final previous = _backdropImage;
    _backdropImage = null;
    if (mounted) {
      if (widget.renderBackdrop) setState(() {});
      widget.onBackdropChanged?.call(null);
    }
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  @override
  void didUpdateWidget(covariant BookDetailsHeader old) {
    super.didUpdateWidget(old);
    final nextIdentity = _currentIdentity();
    final switchedBook =
        nextIdentity != _backdropIdentity ||
        old.coverImageProvider != widget.coverImageProvider;
    if (switchedBook) {
      ++_backdropGeneration;
      final previous = _backdropImage;
      _backdropImage = null;
      _backdropIdentity = nextIdentity;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    }
  }

  Future<void> _handleCoverImage(ui.Image? sourceImage) async {
    final generation = ++_backdropGeneration;
    final identity = _currentIdentity();
    if (sourceImage == null) {
      if (!mounted) return;
      final previous = _backdropImage;
      if (widget.renderBackdrop) {
        setState(() {
          _backdropImage = null;
        });
      } else {
        _backdropImage = null;
      }
      widget.onBackdropChanged?.call(null);
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
      return;
    }
    ui.Image? baked;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const targetSize = Size(_kBackdropWidth * 1.0, _kBackdropHeight * 1.0);
      // Expand draw rect past target bounds so Gaussian blur never samples
      // transparent borders around the header edges, while keeping a gentle
      // sigma on a 160x240 bounded texture so cover contours stay recognizable.
      const bleedRect = Rect.fromLTWH(
        -14,
        -14,
        _kBackdropWidth + 28,
        _kBackdropHeight + 28,
      );
      final sourceSize = Size(
        sourceImage.width.toDouble(),
        sourceImage.height.toDouble(),
      );
      final fitted = applyBoxFit(BoxFit.cover, sourceSize, bleedRect.size);
      final srcRect = const Alignment(
        0,
        -0.2,
      ).inscribe(fitted.source, Offset.zero & sourceSize);
      canvas.clipRect(Offset.zero & targetSize);
      canvas.saveLayer(
        bleedRect,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: _kBackdropBlurSigma,
            sigmaY: _kBackdropBlurSigma,
            tileMode: TileMode.decal,
          ),
      );
      canvas.drawImageRect(
        sourceImage,
        srcRect,
        bleedRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      final picture = recorder.endRecording();
      try {
        baked = await picture.toImage(_kBackdropWidth, _kBackdropHeight);
      } finally {
        picture.dispose();
      }
      if (!mounted ||
          generation != _backdropGeneration ||
          identity != _currentIdentity()) {
        baked.dispose();
        return;
      }
      final previous = _backdropImage;
      if (widget.renderBackdrop) {
        setState(() {
          _backdropImage = baked;
        });
      } else {
        _backdropImage = baked;
      }
      widget.onBackdropChanged?.call(baked);
      if (previous != null && !identical(previous, baked)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    } catch (_) {
      baked?.dispose();
    } finally {
      sourceImage.dispose();
    }
  }

  @override
  void dispose() {
    sourceRevision.removeListener(_onSourceRevisionChanged);
    ++_backdropGeneration;
    final previous = _backdropImage;
    _backdropImage = null;
    previous?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final apple = theme.platform == TargetPlatform.iOS;
    final info = widget.info;
    final title = info?.title ?? widget.hint?.title ?? '作品详情';
    final cover = widget._coverUrl;
    final author = info?.author.trim() ?? '',
        status = info?.status.trim() ?? '';
    final topInset =
        apple && widget.renderBackdrop
            ? MediaQuery.paddingOf(context).top
            : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth >= 700
                ? 166.0
                : constraints.maxWidth < 350
                ? 96.0
                : 112.0;
        final content = Padding(
          padding: EdgeInsets.fromLTRB(18, 18 + topInset, 18, 18),
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
                  imageProvider: widget.coverImageProvider,
                  preferPaintedSize: true,
                  fit: BoxFit.contain,
                  borderRadius: BorderRadius.circular(apple ? 10 : 16),
                  onImage: apple ? _handleCoverImage : null,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: apple ? colors.onSurface : null,
                      ),
                    ),
                    if (author.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: apple ? 8 : 12),
                        child: GestureDetector(
                          onTap: widget.onAuthor,
                          child: Text(
                            author,
                            style: theme.textTheme.bodyMedium?.copyWith(
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
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                      if (status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            status,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (widget.volumes != null && widget.chapters != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${widget.volumes} 卷 · ${widget.chapters} 章',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (info?.finUpdate.trim().isNotEmpty ?? false)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '更新 ${info!.finUpdate}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
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
        if (!widget.renderBackdrop) {
          return content;
        }
        final pageBg = theme.scaffoldBackgroundColor;
        final dark = theme.brightness == Brightness.dark;
        final hasCoverSource =
            cover.isNotEmpty || widget.coverImageProvider != null;
        final backdrop = _backdropImage;
        final showBackdrop = hasCoverSource && backdrop != null;

        return RepaintBoundary(
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: pageBg,
                    child: AnimatedOpacity(
                      duration:
                          MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      opacity: showBackdrop ? 1 : 0,
                      child:
                          !showBackdrop
                              ? const SizedBox.expand()
                              : _BookDetailsCoverBackdrop(
                                image: backdrop,
                                pageBg: pageBg,
                                dark: dark,
                              ),
                    ),
                  ),
                ),
                content,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BookDetailsCoverBackdrop extends StatelessWidget {
  const _BookDetailsCoverBackdrop({
    required this.image,
    required this.pageBg,
    required this.dark,
  });

  final ui.Image image;
  final Color pageBg;
  final bool dark;

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('ios-detail-cover-backdrop'),
    fit: StackFit.expand,
    children: [
      RawImage(
        image: image,
        fit: BoxFit.cover,
        alignment: const Alignment(0, -0.2),
        filterQuality: FilterQuality.medium,
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.46, 0.78, 1.0],
            colors: [
              pageBg.withValues(alpha: dark ? 0.26 : 0.18),
              pageBg.withValues(alpha: dark ? 0.34 : 0.26),
              pageBg.withValues(alpha: dark ? 0.68 : 0.64),
              pageBg,
            ],
          ),
        ),
      ),
    ],
  );
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
