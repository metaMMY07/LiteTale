import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';

class LocalEpubLibraryPage extends StatefulWidget {
  const LocalEpubLibraryPage({super.key, this.library});
  final LocalEpubLibrary? library;

  @override
  State<LocalEpubLibraryPage> createState() => _LocalEpubLibraryPageState();
}

class _LocalEpubLibraryPageState extends State<LocalEpubLibraryPage> {
  late final _library = widget.library ?? LocalEpubLibrary.instance;
  bool _picking = false;
  bool _busy = false;
  String _query = '';
  final _search = TextEditingController();
  String? _error;

  Future<void> _import() async {
    if (_busy || _picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'EPUB 电子书',
            extensions: ['epub'],
            mimeTypes: [
              'application/epub+zip',
              'application/zip',
              'application/octet-stream',
            ],
            uniformTypeIdentifiers: ['org.idpf.epub-container'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      setState(() => _busy = true);
      final result = await _library.importFile(file);
      if (result.upgraded) {
        api.invalidateLocalEpubPresentation(result.book.id);
      }
      if (!mounted) return;
      _search.clear();
      setState(() => _query = '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.alreadyImported
                ? '《${result.book.title}》已在本地书籍中'
                : result.upgraded
                ? '已更新《${result.book.title}》的原书样式，阅读记录已保留'
                : '已导入《${result.book.title}》',
          ),
          action: SnackBarAction(
            label: '打开',
            onPressed: () => _open(result.book),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is EpubImportException
                      ? error.message
                      : '导入失败，请检查文件后重试',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _retryInitialization() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _library.retryInitialization();
    } catch (_) {
      if (mounted) setState(() => _error = '本地书库仍不可用，请检查存储空间后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(LocalEpubBook book) async {
    if (!mounted || !_library.contains(book.id)) return;
    await Navigator.pushNamed(context, '/novel/info', arguments: book.id);
  }

  Future<void> _remove(LocalEpubBook book) async {
    if (_busy || _picking) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('移除本地书籍'),
            content: Text('移除《${book.title}》及其本机阅读记录？原 EPUB 文件会保留。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('移除'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.removeLocalEpub(book.id);
      if (book.coverUrl.isNotEmpty) {
        await CachedImageProvider(
          book.coverUrl,
          source: SourceId.localEpub,
        ).evict();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '移除未能完成，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _bookDetails(LocalEpubBook book) {
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(book.title),
            content: SingleChildScrollView(
              child: Text(
                [
                  '作者：${book.author}',
                  '章节：${book.chapters.length}',
                  '文件：${book.fileName}',
                  if (book.language.isNotEmpty) '语言：${book.language}',
                  if (book.warnings.isNotEmpty) '\n${book.warnings.join('\n')}',
                ].join('\n'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成'),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _library,
    builder: (context, _) {
      final query = _query.trim().toLowerCase();
      final books =
          _library.books
              .where(
                (book) =>
                    query.isEmpty ||
                    '${book.title}\n${book.author}'.toLowerCase().contains(
                      query,
                    ),
              )
              .toList();
      final error = _error ?? _library.initializationError;
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(
          title: const Text('本地书籍'),
          actions: [
            IconButton(
              tooltip: '导入 EPUB',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _busy || _picking ? null : _import,
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: '查找本地书名、作者',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(28)),
                  ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: ExpressiveLoadingIndicator(size: 24),
                    ),
                    SizedBox(width: 12),
                    Text('正在处理本地书籍…'),
                  ],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.errorContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error,
                        style: TextStyle(color: colors.onErrorContainer),
                      ),
                      if (_library.initializationError != null)
                        TextButton(
                          onPressed: _busy ? null : _retryInitialization,
                          child: const Text('重试'),
                        ),
                    ],
                  ),
                ),
              ),
            if (_library.loadWarnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  '部分本地书籍暂不可用，可重新导入原文件。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            if (_library.books.any((book) => book.needsStyleUpgrade))
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('旧版导入的书籍可再次选择原 EPUB 来更新原书样式，阅读记录会保留。'),
              ),
            Expanded(
              child:
                  books.isEmpty
                      ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.auto_stories_outlined,
                                  size: 64,
                                  color: colors.primary,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  query.isEmpty ? '把喜欢的故事放进书架' : '没有找到这本书',
                                  style: Theme.of(context).textTheme.titleLarge,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  query.isEmpty
                                      ? '导入 EPUB 后即可离线阅读，沿用你的字体、双页和翻页设置。'
                                      : '试试其他书名或作者。',
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                FilledButton.icon(
                                  onPressed: _busy || _picking ? null : _import,
                                  icon: const Icon(Icons.add_rounded),
                                  label: const Text('导入 EPUB'),
                                ),
                                const SizedBox(height: 16),
                                if (query.isEmpty)
                                  const Text(
                                    '支持 EPUB 2 / 3 流式图文书籍（最大 128 MB）。\n暂不支持 DRM 加密与固定版式。',
                                    textAlign: TextAlign.center,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      )
                      : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        gridDelegate: const BookGridDelegate(
                          childAspectRatio: 0.64,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: books.length,
                        itemBuilder: (context, index) {
                          final book = books[index];
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            margin: EdgeInsets.zero,
                            child: InkWell(
                              onTap: _busy ? null : () => _open(book),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      width: double.infinity,
                                      child:
                                          book.coverUrl.isEmpty
                                              ? ColoredBox(
                                                color: colors.primaryContainer,
                                                child: Center(
                                                  child: Icon(
                                                    Icons.menu_book_rounded,
                                                    size: 56,
                                                    color:
                                                        colors
                                                            .onPrimaryContainer,
                                                  ),
                                                ),
                                              )
                                              : CachedImage(
                                                url: book.coverUrl,
                                                source: SourceId.localEpub,
                                                fit: BoxFit.contain,
                                                cacheWidth: 480,
                                              ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      10,
                                      12,
                                      0,
                                    ),
                                    child: Text(
                                      book.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 12),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            book.author,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                Theme.of(
                                                  context,
                                                ).textTheme.bodySmall,
                                          ),
                                        ),
                                        PopupMenuButton<String>(
                                          tooltip: '${book.title}的操作',
                                          enabled: !_busy && !_picking,
                                          onSelected:
                                              (value) =>
                                                  value == 'remove'
                                                      ? _remove(book)
                                                      : _bookDetails(book),
                                          itemBuilder:
                                              (_) => const [
                                                PopupMenuItem(
                                                  value: 'info',
                                                  child: Text('书籍信息'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'remove',
                                                  child: Text('移除书籍'),
                                                ),
                                              ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      );
    },
  );
}
