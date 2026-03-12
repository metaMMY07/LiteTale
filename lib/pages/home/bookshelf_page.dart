import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/widgets/cf_action_loader.dart';
import 'package:wild/widgets/cf_bookshelf_loader.dart';
import 'package:wild/widgets/novel_card.dart';
import 'package:wild/src/rust/wenku8/models.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  final _cfKey = GlobalKey<CfBookshelfLoaderState>();
  bool _cfActive = false;

  @override
  Widget build(BuildContext context) {
    final apiHost = context.read<ApiHostCubit>().state;
    final effectiveHost = apiHost.isEmpty ? 'https://www.wenku8.net' : apiHost;

    return BlocConsumer<BookshelfCubit, BookshelfState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          curr.status == BookshelfStatus.cloudflareChallenge,
      listener: (context, state) {
        // 觸發背景 WebView 開始載入書架
        _cfKey.currentState?.reload();
        setState(() => _cfActive = true);
      },
      builder: (context, state) {
        return Stack(
          children: [
            _buildMainScaffold(context, state),

            // WebView 永久在背景存活（1×1px），CF clearance 只需取得一次
            Positioned(
              left: 0, top: 0, width: 1, height: 1,
              child: CfBookshelfLoader(
                key: _cfKey,
                apiHost: effectiveHost,
                onPartialData: (bookcases, contents) {
                  context.read<BookshelfCubit>().loadFromWebViewData(bookcases, contents);
                },
                onSuccess: (bookcases, contents) {
                  context.read<BookshelfCubit>().loadFromWebViewData(bookcases, contents);
                  setState(() => _cfActive = false);
                },
                onError: (err) {
                  context.read<BookshelfCubit>().setError(err);
                  setState(() => _cfActive = false);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMainScaffold(BuildContext context, BookshelfState state) {
    // 仍在 CF 驗證且還沒有任何書架資料時顯示純 loading
    final isCfLoading = _cfActive;
    final hasData = state.bookcases.isNotEmpty;

    if (state.status == BookshelfStatus.loading ||
        (isCfLoading && !hasData)) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('我的书架'),
          bottom: isCfLoading
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(3),
                  child: LinearProgressIndicator(),
                )
              : null,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (state.status == BookshelfStatus.error && !isCfLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('我的书架')),
        body: RefreshIndicator(
          onRefresh: () => context.read<BookshelfCubit>().loadBookcases(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.grey),
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
        appBar: AppBar(title: const Text('我的书架')),
        body: const Center(child: Text('暂无书架')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          if (state.isSelecting) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: state.selectedBids.isEmpty
                  ? null
                  : () => _showDeleteConfirmDialog(context),
            ),
            IconButton(
              icon: const Icon(Icons.move_to_inbox),
              onPressed: state.selectedBids.isEmpty
                  ? null
                  : () => _showMoveDialog(context),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => context.read<BookshelfCubit>().toggleSelectMode(),
            ),
          ] else ...[
            if (state.tip.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showTipDialog(context, state.tip),
              ),
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: () => context.read<BookshelfCubit>().toggleSelectMode(),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(isCfLoading ? 51 : 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCfLoading) const LinearProgressIndicator(minHeight: 3),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: state.bookcases.map((bookcase) {
                    final isSelected = bookcase.id == state.currentCaseId;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(bookcase.title),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            context.read<BookshelfCubit>().selectBookcase(bookcase.id);
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
      body: state.getCurrentBooks()?.isEmpty ?? true
          ? const Center(child: Text('书架为空'))
          : RefreshIndicator(
              onRefresh: () => context.read<BookshelfCubit>().loadBookcases(),
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
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
    );
  }

  void _showDeleteConfirmDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除选中的书籍吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
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

  void _showCfActionForMove(BuildContext context, BookshelfCubit cubit, String toBookcaseId) {
    final state = cubit.state;
    final bids = state.selectedBids.toList();
    final fromId = state.currentCaseId ?? '';
    final apiHost = context.read<ApiHostCubit>().state;
    final effectiveHost = apiHost.isEmpty ? 'https://www.wenku8.net' : apiHost;

    final bidsJs = bids.map((b) => '''
      (function(){ var i=document.createElement('input');i.type='hidden';i.name='checkid[]';i.value='$b';f.appendChild(i); })();
    ''').join('');

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

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog.fullscreen(
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('操作失敗: $err')),
            );
          },
        ),
      ),
    );
  }

  void _showTipDialog(BuildContext context, String tip) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('书架容量'),
        content: Text(tip),
      ),
    );
  }

  void _showMoveDialog(BuildContext context) {
    final state = context.read<BookshelfCubit>().state;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移动到书架'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.bookcases.length,
            itemBuilder: (context, index) {
              final bookcase = state.bookcases[index];
              if (bookcase.id == state.currentCaseId) return const SizedBox.shrink();
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
          TextButton(
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
          Navigator.pushNamed(
            context,
            '/novel/info',
            arguments: item.aid,
          );
        }
      },
      child: Stack(
        children: [
          NovelCard(
            title: item.title,
            coverUrl: _getCoverUrl(item.aid),
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
                  color: isSelected ? Colors.blue : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.blue : Colors.grey,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  String _getCoverUrl(String aid) {
    try {
      final id = int.parse(aid);
      return 'https://img.wenku8.com/image/${id ~/ 1000}/$aid/${aid}s.jpg';
    } catch (e) {
      return 'https://img.wenku8.com/image/0/0/0s.jpg';
    }
  }
}
