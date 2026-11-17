import 'dart:async';

import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:flutter/material.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart'
    show LocalShelfEntry, coverForBook, selectSource;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/widgets/cf_action_loader.dart';
import 'package:wild/widgets/novel_card.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/pages/local_epub_library_page.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/ios_dock_insets.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/models/book_detail_hint.dart';
import 'package:wild/widgets/book_card_ink.dart';
import 'package:wild/settings/settings_widgets.dart' show chooseSetting;

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  Widget _localLibraryButton(BuildContext context) => AppButton.textIcon(
    icon: const Icon(Icons.folder_open_rounded),
    label: const Text('本地书籍'),
    onPressed:
        () => Navigator.of(context).push(
          HorizontalCoverPageRoute(
            builder: (_) => const LocalEpubLibraryPage(),
          ),
        ),
  );

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BookshelfCubit, BookshelfState>(
      builder: _buildMainScaffold,
    );
  }

  SourceId? _sourceFilter;
  bool _openingBook = false;

  Widget _buildMainScaffold(BuildContext context, BookshelfState state) {
    final cubit = context.read<BookshelfCubit>();
    final sources = <SourceId?>[
      null,
      if (state.wenku8Enabled) SourceId.wenku8,
      for (final entry in state.localBooks.entries)
        if (entry.value.isNotEmpty) entry.key,
    ];
    final source = sources.contains(_sourceFilter) ? _sourceFilter : null;
    final wenku8Only = source == SourceId.wenku8;
    final showWenku8 = state.wenku8Enabled && (source == null || wenku8Only);
    final selecting = wenku8Only && state.isSelecting;
    final books = <LocalShelfEntry>[
      if (showWenku8)
        for (final book
            in wenku8Only
                ? state.getCurrentBooks() ?? const <BookcaseItem>[]
                : state.wenku8Books)
          (book: book, coverUrl: ''),
      for (final entry in state.localBooks.entries)
        if (source == null || source == entry.key) ...entry.value,
    ];

    Future<void> refresh() async {
      await Future.wait([
        if (showWenku8) cubit.loadBookcases(),
        if (!wenku8Only) cubit.loadLocalShelves(refresh: true),
      ]);
      await cubit.refreshUnreadCounts();
    }

    final filters = SizedBox(
      height: 48,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 12),
          child: AppButton.textIcon(
            label: Text(source?.label ?? '全部书源'),
            icon: const Icon(Icons.expand_more_rounded),
            onPressed:
                sources.length == 1
                    ? null
                    : () async {
                      final index = await chooseSetting(context, '书架筛选', {
                        for (var i = 0; i < sources.length; i++)
                          i: sources[i]?.label ?? '全部书源',
                      }, sources.indexOf(source));
                      if (!mounted || index == null) return;
                      if (cubit.state.isSelecting) cubit.toggleSelectMode();
                      setState(() => _sourceFilter = sources[index]);
                    },
          ),
        ),
      ),
    );
    final groups =
        wenku8Only && state.bookcases.isNotEmpty
            ? _filterBar(
              labels: state.bookcases.map((group) => group.title).toList(),
              index: state.bookcases.indexWhere(
                (group) => group.id == state.currentCaseId,
              ),
              onSelect:
                  (index) => cubit.selectBookcase(state.bookcases[index].id),
            )
            : null;
    final isRefreshing = showWenku8 && state.isRefreshing;
    final hasBooks = books.isNotEmpty;
    final padding = IosDockInsets.scrollPadding(
      context,
      const EdgeInsets.all(8),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          if (supportsLocalEpub && !selecting) _localLibraryButton(context),
          if (selecting) ...[
            AppIconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed:
                  state.selectedBids.isEmpty
                      ? null
                      : () => _showDeleteConfirmDialog(context),
            ),
            AppIconButton(
              icon: const Icon(Icons.move_to_inbox),
              onPressed:
                  state.selectedBids.isEmpty
                      ? null
                      : () => _showMoveDialog(context),
            ),
            AppIconButton(
              icon: const Icon(Icons.close),
              onPressed: cubit.toggleSelectMode,
            ),
          ] else if (wenku8Only && state.bookcases.isNotEmpty) ...[
            if (state.tip.isNotEmpty)
              AppIconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showTipDialog(context, state.tip),
              ),
            AppIconButton(
              icon: const Icon(Icons.select_all),
              onPressed: cubit.toggleSelectMode,
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            48 +
                (groups == null ? 0 : (usesAppleGlass ? 60 : 48)) +
                (isRefreshing ? 3 : 0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              filters,
              if (groups != null) groups,
              if (isRefreshing) const LinearProgressIndicator(minHeight: 3),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (showWenku8 && state.errorMessage != null)
            MaterialBanner(
              content: Text('文库8 · ${state.errorMessage!}'),
              actions: [
                if (wenku8Only)
                  const SourceWebsiteLink(source: SourceId.wenku8),
                AppButton.text(
                  onPressed: isRefreshing ? null : cubit.loadBookcases,
                  child: const Text('重试'),
                ),
              ],
            ),
          if (!wenku8Only && state.localReadFailed)
            MaterialBanner(
              content: const Text('部分本机收藏暂时无法读取'),
              actions: [
                AppButton.text(
                  onPressed:
                      state.isLoadingLocalBooks
                          ? null
                          : () => cubit.loadLocalShelves(refresh: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          Expanded(
            child:
                wenku8Only && isRefreshing && state.getCurrentBooks() == null
                    ? SourceLoadingIndicator(
                      source: SourceId.wenku8,
                      requestKey: state.currentCaseId,
                    )
                    : RefreshIndicator(
                      onRefresh: refresh,
                      child: CustomScrollView(
                        key: PageStorageKey(source?.name ?? 'all-bookshelves'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          if (showWenku8 &&
                              state.status == BookshelfStatus.initial)
                            SliverToBoxAdapter(
                              child: Center(
                                child: AppButton.text(
                                  onPressed: cubit.loadBookcases,
                                  child: const Text('加载文库8书架'),
                                ),
                              ),
                            ),
                          if (!hasBooks && !isRefreshing)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                  child:
                                      !wenku8Only && state.isLoadingLocalBooks
                                          ? const CircularProgressIndicator()
                                          : const Text('书架为空'),
                                ),
                              ),
                            ),
                          if (hasBooks)
                            SliverPadding(
                              padding: padding,
                              sliver: SliverGrid(
                                gridDelegate: const BookGridDelegate(
                                  childAspectRatio: 0.7,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final (book: item, :coverUrl) = books[index];
                                  final bookSource = sourceOf(item.aid);
                                  return _BookCard(
                                    key: ValueKey(item.aid),
                                    item: item,
                                    source: bookSource,
                                    storedCoverUrl: coverUrl,
                                    unreadCount: state.unreadCounts[item.aid],
                                    showSource: source == null,
                                    canSelect: wenku8Only,
                                    selecting: selecting,
                                    selected: state.isBookSelected(item.bid),
                                    onOpen:
                                        (cover) =>
                                            _openBook(item, bookSource, cover),
                                  );
                                }, childCount: books.length),
                              ),
                            ),
                        ],
                      ),
                    ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar({
    required List<String> labels,
    required int index,
    required ValueChanged<int> onSelect,
  }) {
    if (usesAppleGlass) {
      return AppleGlassFilterBar(
        labels: labels,
        index: index,
        onSelect: onSelect,
      );
    }
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: labels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder:
            (context, i) => Center(
              child: FilterChip(
                label: Text(labels[i]),
                selected: i == index,
                onSelected: (selected) {
                  if (selected) onSelect(i);
                },
              ),
            ),
      ),
    );
  }

  Future<void> _openBook(
    BookcaseItem item,
    SourceId source,
    String cover,
  ) async {
    if (_openingBook) return;
    _openingBook = true;
    final route = ModalRoute.of(context);
    try {
      // This source's existing site session is only active while selected.
      if (source == SourceId.bili && activeSource.value != source) {
        await selectSource(source);
      }
      if (!mounted || route?.isCurrent == false) return;
      BookDetailHint.remember(item.aid, item.title, cover);
      await Navigator.pushNamed(context, '/novel/info', arguments: item.aid);
      if (mounted) {
        unawaited(context.read<BookshelfCubit>().refreshUnreadCounts());
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法打开这本书，请重试。')));
      }
    } finally {
      _openingBook = false;
    }
  }

  void _showDeleteConfirmDialog(BuildContext context) {
    showAdaptiveDialog(
      context: context,
      builder:
          (ctx) => AlertDialog.adaptive(
            title: const Text('确认删除'),
            content: const Text('确定要删除选中的书籍吗？'),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              AppButton.text(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final cubit = context.read<BookshelfCubit>();
                  try {
                    await cubit.moveSelectedBooks('-1');
                  } catch (e) {
                    if (!context.mounted) return;
                    _showCfActionForMove(context, cubit, '-1');
                  }
                },
                child: const Text('删除'),
              ),
            ],
          ),
    );
  }

  void _showCfActionForMove(
    BuildContext context,
    BookshelfCubit cubit,
    String toBookcaseId,
  ) {
    final state = cubit.state;
    final bids = state.selectedBids.toList();
    final fromId = state.currentCaseId ?? '';
    final apiHost = context.read<ApiHostCubit>().state;
    final effectiveHost = apiHost.isEmpty ? 'https://www.wenku8.net' : apiHost;

    final bidsJs = bids
        .map(
          (b) => '''
      (function(){ var i=document.createElement('input');i.type='hidden';i.name='checkid[]';i.value='$b';f.appendChild(i); })();
    ''',
        )
        .join('');

    final jsAction = '''
(function() {
  var f = document.createElement('form');
  f.method = 'POST';
  f.action = '$effectiveHost/modules/article/bookcase.php';
  $bidsJs
  var fields = {classlist: '$fromId', checkall: 'checkall', newclassid: '$toBookcaseId', classid: '$fromId'};
  Object.keys(fields).forEach(function(k) {
    var i = document.createElement('input');
    i.type = 'hidden'; i.name = k; i.value = fields[k];
    f.appendChild(i);
  });
  document.body.appendChild(f);
  f.submit();
})();
''';

    showAdaptiveDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => Dialog.fullscreen(
            child: CfActionLoader(
              apiHost: effectiveHost,
              jsAction: jsAction,
              successUrlKeyword: 'bookcase.php',
              successBodyKeyword: '处理成功',
              onSuccess: () {
                Navigator.of(ctx).pop();
                cubit.loadBookcases();
              },
              onError: (err) {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('操作失敗: $err')));
              },
            ),
          ),
    );
  }

  void _showTipDialog(BuildContext context, String tip) {
    showAdaptiveDialog(
      context: context,
      builder:
          (context) => AlertDialog.adaptive(
            title: const Text('书架容量'),
            content: Text(tip),
          ),
    );
  }

  void _showMoveDialog(BuildContext context) {
    final state = context.read<BookshelfCubit>().state;
    showAdaptiveDialog(
      context: context,
      builder:
          (context) => AlertDialog.adaptive(
            title: const Text('移动到书架'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: state.bookcases.length,
                itemBuilder: (context, index) {
                  final bookcase = state.bookcases[index];
                  if (bookcase.id == state.currentCaseId) {
                    return const SizedBox.shrink();
                  }
                  return ListTile(
                    title: Text(bookcase.title),
                    onTap: () async {
                      Navigator.pop(context);
                      final cubit = context.read<BookshelfCubit>();
                      try {
                        await cubit.moveSelectedBooks(bookcase.id);
                      } catch (e) {
                        if (!context.mounted) return;
                        _showCfActionForMove(context, cubit, bookcase.id);
                      }
                    },
                  );
                },
              ),
            ),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.item,
    required this.source,
    required this.storedCoverUrl,
    required this.unreadCount,
    required this.showSource,
    required this.canSelect,
    required this.selecting,
    required this.selected,
    required this.onOpen,
  });

  final BookcaseItem item;
  final SourceId source;
  final String storedCoverUrl;
  final int? unreadCount;
  final bool showSource, canSelect, selecting, selected;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<BookshelfCubit>();
    final cover = _coverUrl;
    final count = unreadCount;

    void onTap() {
      if (selecting) {
        cubit.toggleBookSelection(item.bid);
      } else {
        onOpen(cover);
      }
    }

    void onLongPress() {
      if (!selecting) {
        cubit.toggleSelectMode();
        cubit.toggleBookSelection(item.bid);
      }
    }

    final content = Stack(
      children: [
        NovelCard(
          title: item.title,
          coverUrl: cover,
          source: source,
          padding: const EdgeInsets.all(8.0),
          author: showSource ? source.label : null,
          showAuthor: showSource,
          coverBadge: count != null && count > 0 ? _UnreadCorner(count) : null,
        ),
        if (selecting)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:
                    selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surface,
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      selected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                  width: 2,
                ),
              ),
              child:
                  selected
                      ? Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: Theme.of(context).colorScheme.onPrimary,
                      )
                      : null,
            ),
          ),
      ],
    );
    if (usesMaterialYou) {
      return BookCardInk(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: canSelect ? onLongPress : null,
        child: content,
      );
    }
    return GestureDetector(
      onTap: onTap,
      onLongPress: canSelect ? onLongPress : null,
      child: content,
    );
  }

  String get _coverUrl {
    if (source == SourceId.wenku8) {
      final id = int.tryParse(item.aid);
      if (id == null || id <= 0) return '';
      return 'https://img.wenku8.com/image/${id ~/ 1000}/${item.aid}/${item.aid}s.jpg';
    }
    final cached = coverForBook(item.aid);
    return cached.isNotEmpty ? cached : storedCoverUrl;
  }
}

class _UnreadCorner extends StatelessWidget {
  const _UnreadCorner(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '未读 $count 章',
      excludeSemantics: true,
      child: IgnorePointer(
        child: ClipPath(
          clipper: const _CornerTriangle(),
          child: ColoredBox(
            color: colors.primary,
            child: SizedBox.square(
              dimension: count > 99 ? 51 : 39,
              child: Padding(
                padding: const EdgeInsets.only(top: 7, left: 8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    count > 999 ? '999+' : '$count',
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CornerTriangle extends CustomClipper<Path> {
  const _CornerTriangle();

  @override
  Path getClip(Size size) =>
      Path()
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close();

  @override
  bool shouldReclip(_CornerTriangle oldClipper) => false;
}
