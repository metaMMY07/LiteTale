import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:flutter/material.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' show coverForBook;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/widgets/cf_action_loader.dart';
import 'package:wild/widgets/novel_card.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/pages/local_epub_library_page.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

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

  Widget _buildMainScaffold(BuildContext context, BookshelfState state) {
    // 仍在 CF 驗證且還沒有任何書架資料時顯示純 loading
    final isCfLoading = state.isRefreshing;
    final hasData = state.bookcases.isNotEmpty;

    if (state.status == BookshelfStatus.loading || (isCfLoading && !hasData)) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('我的书架'),
          actions: [_localLibraryButton(context)],
        ),
        body: const CenteredLoadingIndicator(),
      );
    }

    if (state.status == BookshelfStatus.error && !isCfLoading && !hasData) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('我的书架'),
          actions: [_localLibraryButton(context)],
        ),
        body: RefreshIndicator(
          onRefresh: () => context.read<BookshelfCubit>().loadBookcases(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '加载失败 (下拉刷新)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.errorMessage ?? '未知错误',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.start,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (state.bookcases.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('我的书架'),
          actions: [_localLibraryButton(context)],
        ),
        body: const Center(child: Text('暂无书架')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          if (!state.isSelecting) _localLibraryButton(context),
          if (state.isSelecting) ...[
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
              onPressed:
                  () => context.read<BookshelfCubit>().toggleSelectMode(),
            ),
          ] else ...[
            if (state.tip.isNotEmpty)
              AppIconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showTipDialog(context, state.tip),
              ),
            AppIconButton(
              icon: const Icon(Icons.select_all),
              onPressed:
                  () => context.read<BookshelfCubit>().toggleSelectMode(),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(isCfLoading ? 51 : 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCfLoading) const LinearProgressIndicator(minHeight: 3),
              if (usesAppleGlass)
                AppleGlassFilterBar(
                  labels:
                      state.bookcases
                          .map((bookcase) => bookcase.title)
                          .toList(),
                  index: state.bookcases.indexWhere(
                    (bookcase) => bookcase.id == state.currentCaseId,
                  ),
                  onSelect:
                      (index) => context.read<BookshelfCubit>().selectBookcase(
                        state.bookcases[index].id,
                      ),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children:
                        state.bookcases.map((bookcase) {
                          final isSelected = bookcase.id == state.currentCaseId;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(bookcase.title),
                              selected: isSelected,
                              onSelected: (selected) {
                                if (selected) {
                                  context.read<BookshelfCubit>().selectBookcase(
                                    bookcase.id,
                                  );
                                }
                              },
                            ),
                          );
                        }).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (state.errorMessage != null)
            MaterialBanner(
              content: Text(state.errorMessage!),
              actions: [
                AppButton.text(
                  onPressed:
                      state.isRefreshing
                          ? null
                          : () =>
                              context.read<BookshelfCubit>().loadBookcases(),
                  child: const Text('重试'),
                ),
              ],
            ),
          Expanded(
            child:
                state.isRefreshing && state.getCurrentBooks() == null
                    ? const CenteredLoadingIndicator()
                    : RefreshIndicator(
                      onRefresh:
                          () => context.read<BookshelfCubit>().loadBookcases(),
                      child:
                          state.getCurrentBooks()?.isEmpty ?? true
                              ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  Padding(
                                    padding: EdgeInsets.all(32),
                                    child: Center(child: Text('书架为空')),
                                  ),
                                ],
                              )
                              : GridView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.all(8),
                                gridDelegate: const BookGridDelegate(
                                  childAspectRatio: 0.7,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                itemCount: state.getCurrentBooks()?.length ?? 0,
                                itemBuilder: (context, index) {
                                  final item = state.getCurrentBooks()![index];
                                  return _BookCard(item: item);
                                },
                              ),
                    ),
          ),
        ],
      ),
    );
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
  final BookcaseItem item;

  const _BookCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BookshelfCubit>().state;
    final isSelected = state.isSelecting && state.isBookSelected(item.bid);

    return GestureDetector(
      onLongPress: () {
        if (!state.isSelecting) {
          context.read<BookshelfCubit>().toggleSelectMode();
          context.read<BookshelfCubit>().toggleBookSelection(item.bid);
        }
      },
      onTap: () {
        if (state.isSelecting) {
          context.read<BookshelfCubit>().toggleBookSelection(item.bid);
        } else {
          Navigator.pushNamed(context, '/novel/info', arguments: item.aid);
        }
      },
      child: Stack(
        children: [
          NovelCard(
            title: item.title,
            coverUrl: _getCoverUrl(item.aid),
            source: sourceOf(item.aid),
            padding: const EdgeInsets.all(8.0),
            showAuthor: false,
          ),
          if (state.isSelecting)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color:
                      isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                    width: 2,
                  ),
                ),
                child:
                    isSelected
                        ? Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: Theme.of(context).colorScheme.onPrimary,
                        )
                        : null,
              ),
            ),
        ],
      ),
    );
  }

  String _getCoverUrl(String aid) {
    if (sourceOf(aid) != SourceId.wenku8) return coverForBook(aid);
    try {
      final id = int.parse(aid);
      return 'https://img.wenku8.com/image/${id ~/ 1000}/$aid/${aid}s.jpg';
    } catch (e) {
      return 'https://img.wenku8.com/image/0/0/0s.jpg';
    }
  }
}
