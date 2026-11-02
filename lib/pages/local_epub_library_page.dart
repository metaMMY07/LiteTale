import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:wild/services/epub/apple_books_opener.dart';
import 'package:wild/services/epub/epub_library_query.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/epub/local_epub_organization.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/widgets/platform_controls.dart';

import 'local_epub_library_controls.dart';

class LocalEpubLibraryPage extends StatefulWidget {
  const LocalEpubLibraryPage({
    super.key,
    this.library,
    this.pickFiles,
    this.opener,
  });
  final LocalEpubLibrary? library;
  final Future<List<XFile>> Function()? pickFiles;
  final AppleBooksOpener? opener;

  @override
  State<LocalEpubLibraryPage> createState() => _LocalEpubLibraryPageState();
}

class _LocalEpubLibraryPageState extends State<LocalEpubLibraryPage> {
  late final _library = widget.library ?? LocalEpubLibrary.instance;
  late final _organization = _library.organization;
  late final _queue = _library.imports;
  late final _opener = widget.opener ?? AppleBooksOpener.instance;
  final _search = TextEditingController();
  final _selected = <String>{};
  bool _picking = false, _busy = false, _selecting = false, _choosing = false;
  String? _error;
  String _query = '';

  bool get _canEdit => !_busy && !_picking && !_queue.isRunning;

  Future<void> _import() async {
    if (!_canEdit) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final files =
          await (widget.pickFiles?.call() ??
              openFiles(
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
              ));
      if (files.isEmpty || !mounted) return;
      String? target;
      if (_organization.isReady && _organization.collections.isNotEmpty) {
        setState(() => _choosing = true);
        target = await chooseEpubCollection(
          context,
          _organization,
          title: '导入 ${files.length} 本 EPUB',
          initial: _organization.selectedCollection,
          allowUnfiled: true,
        );
        if (mounted) setState(() => _choosing = false);
        if (target == null || !mounted) return;
      }
      if (_organization.isReady &&
          _organization.selectedCollection !=
              (target == null || target.isEmpty ? allEpubs : target)) {
        // Display the target shelf so successful imports are visible immediately.
        // A preference write failure must not stop the archive import.
        try {
          await _organization.selectCollection(
            target == null || target.isEmpty ? allEpubs : target,
          );
        } catch (_) {}
        if (!mounted) return;
      }
      _search.clear();
      setState(() {
        _query = '';
        _selected.clear();
        _selecting = false;
        _picking = false;
      });
      // The queue is library-owned and continues after this route leaves.
      final completion = _queue.start(
        files,
        collectionId: target == '' ? null : target,
        afterImport: _invalidateImportedPresentation,
      );
      final generation = _queue.generation;
      await completion;
      if (generation != _queue.generation) return;
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final results = _queue.items;
      if (files.length == 1 &&
          results.length == 1 &&
          results.single.result != null &&
          _opener.isSupported) {
        await _open(results.single.result!.book);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is EpubImportException
                      ? error.message
                      : '未能导入，请检查文件、文件提供器或存储空间后重试。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _choosing = false;
        });
      }
    }
  }

  Future<void> _organize(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is EpubOrganizationException
                      ? error.message
                      : '未能保存分类，请稍后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectCollection(String id) async {
    await _organize(() => _organization.selectCollection(id));
    if (mounted) {
      setState(() {
        _selected.clear();
        _selecting = false;
      });
    }
  }

  Future<void> _addToCollection(Set<String> bookIds) async {
    if (!_canEdit || !_organization.isReady || bookIds.isEmpty) return;
    if (_organization.collections.isEmpty) {
      await _manageCollections();
      if (!mounted || _organization.collections.isEmpty) return;
    }
    final target = await chooseEpubCollection(
      context,
      _organization,
      title: '将 ${bookIds.length} 本加入分类',
    );
    if (target == null || !mounted) return;
    await _organize(
      () => _organization.addBooks(target, bookIds.where(_library.contains)),
    );
  }

  Future<void> _manageCollections() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalEpubCollectionsPage(library: _library),
      ),
    );
    if (mounted) {
      setState(() {
        _selected.clear();
        _selecting = false;
      });
    }
  }

  Future<void> _open(LocalEpubBook book) async {
    if (!mounted || !_library.contains(book.id)) return;
    // This records a real open action, never a made-up Apple Books reading status.
    if (_organization.isReady) {
      unawaited(_organization.recordOpened(book.id).catchError((Object _) {}));
    }
    if (_opener.isSupported) {
      try {
        await _opener.open(
          _library,
          book.id,
          isActive:
              () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
        );
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未能打开原 EPUB，请重新导入后重试。')));
        }
      }
      return;
    }
    await Navigator.pushNamed(context, '/novel/info', arguments: book.id);
  }

  Future<void> _remove(LocalEpubBook book) async {
    if (!_canEdit) return;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog.adaptive(
            title: const Text('移除本地书籍'),
            content: Text('移除《${book.title}》及其本机阅读记录？原 EPUB 文件会保留。'),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              AppButton.filled(
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
      if (identical(_library, LocalEpubLibrary.instance)) {
        await api.removeLocalEpub(book.id);
      } else {
        await _library.remove(book.id);
      }
      if (book.coverUrl.isNotEmpty) {
        await CachedImageProvider(
          book.coverUrl,
          source: SourceId.localEpub,
        ).evict();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '移除或分类清理未能完成，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _bookDetails(LocalEpubBook book) {
    final categories = _organization.collections
        .where((c) => _organization.contains(c.id, book.id))
        .map((c) => c.name)
        .join('、');
    showAdaptiveDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog.adaptive(
            title: Text(book.title),
            content: SingleChildScrollView(
              child: Text(
                [
                  '作者：${book.author}',
                  '章节：${book.chapters.length}',
                  '文件：${book.fileName}',
                  if (book.language.isNotEmpty) '语言：${book.language}',
                  '分类：${categories.isEmpty ? '未分类' : categories}',
                  if (book.warnings.isNotEmpty) '\n${book.warnings.join('\n')}',
                ].join('\n'),
              ),
            ),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成'),
              ),
            ],
          ),
    );
  }

  void _toggleSelection(String id) => setState(() {
    _selecting = true;
    if (!_selected.add(id)) _selected.remove(id);
  });

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_library, _organization, _queue]),
    builder: (context, _) {
      final all = _library.books;
      _selected.removeWhere((id) => !_library.contains(id));
      final books = queryLocalEpubs(all, _organization, query: _query);
      final active =
          _organization.isReady ? _organization.selectedCollection : allEpubs;
      final error =
          _error ?? _library.initializationError ?? _organization.loadError;
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(
          title: Text(_selecting ? '已选 ${_selected.length} 本' : '本地书籍'),
          leading:
              _selecting
                  ? AppIconButton(
                    tooltip: '退出多选',
                    icon: const Icon(Icons.close),
                    onPressed:
                        () => setState(() {
                          _selecting = false;
                          _selected.clear();
                        }),
                  )
                  : null,
          actions: [
            if (_selecting)
              AppButton.text(
                onPressed:
                    () => setState(() {
                      if (books.every((b) => _selected.contains(b.id))) {
                        _selected.clear();
                      } else {
                        _selected.addAll(books.map((b) => b.id));
                      }
                    }),
                child: Text(
                  books.isNotEmpty &&
                          books.every((b) => _selected.contains(b.id))
                      ? '取消全选'
                      : '全选',
                ),
              ),
            if (!_selecting && all.isNotEmpty)
              AppIconButton(
                tooltip: '多选书籍',
                icon: const Icon(Icons.checklist_rounded),
                onPressed:
                    _canEdit ? () => setState(() => _selecting = true) : null,
              ),
            if (!_selecting)
              AppIconButton(
                tooltip: '导入 EPUB',
                icon: const Icon(Icons.file_open_outlined),
                onPressed:
                    _canEdit && _library.initializationError == null
                        ? _import
                        : null,
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: AppTextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: '查找本地书名、作者',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(28)),
                      ),
                    ),
                    onChanged:
                        (value) => setState(() {
                          _query = value;
                          _selected.clear();
                        }),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppDropdownButtonFormField<String>(
                          key: const ValueKey('epub-collection-filter'),
                          value: active,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '分类书架'),
                          items: [
                            DropdownMenuItem(
                              value: allEpubs,
                              child: Text('全部 (${all.length})'),
                            ),
                            DropdownMenuItem(
                              value: unfiledEpubs,
                              child: Text(
                                '未分类 (${all.where((b) => _organization.isUnfiled(b.id)).length})',
                              ),
                            ),
                            for (final c in _organization.collections)
                              DropdownMenuItem(
                                value: c.id,
                                child: Text(
                                  '${c.name} (${all.where((b) => _organization.contains(c.id, b.id)).length})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged:
                              _organization.isReady && !_busy && !_picking
                                  ? (id) {
                                    if (id != null) {
                                      unawaited(_selectCollection(id));
                                    }
                                  }
                                  : null,
                        ),
                      ),
                      AppPopupMenuButton<EpubLibrarySort>(
                        tooltip: '书籍排序',
                        icon: const Icon(Icons.sort_rounded),
                        enabled: _organization.isReady && !_busy,
                        onSelected:
                            (sort) =>
                                _organize(() => _organization.setSort(sort)),
                        itemBuilder:
                            (_) => [
                              for (final sort in EpubLibrarySort.values)
                                PopupMenuItem(
                                  value: sort,
                                  child: Text(
                                    '${_organization.sort == sort ? '✓ ' : ''}${_sortLabel(sort)}',
                                  ),
                                ),
                            ],
                      ),
                      AppIconButton(
                        tooltip: '管理分类',
                        icon: const Icon(Icons.folder_copy_outlined),
                        onPressed:
                            _organization.isReady && _canEdit
                                ? _manageCollections
                                : null,
                      ),
                    ],
                  ),
                ),
              ),
              if ((_picking && !_choosing) || _busy)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const AppLoadingIndicator(size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _picking ? '正在准备文件，可在文件选择器中多选…' : '正在处理本地书籍…',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: EpubImportPanel(queue: _queue)),
              if (error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: AppleGlassCard.filled(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(error, style: TextStyle(color: colors.error)),
                            if (_library.initializationError != null ||
                                _organization.loadError != null)
                              AppButton.text(
                                onPressed:
                                    !_canEdit
                                        ? null
                                        : () => _organize(() async {
                                          if (_library.initializationError !=
                                              null) {
                                            await _library
                                                .retryInitialization();
                                          } else {
                                            await _organization
                                                .retryInitialization();
                                          }
                                        }),
                                child: const Text('重试'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_organization.warning != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(_organization.warning!),
                  ),
                ),
              if (_library.loadWarnings.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      [
                        ..._library.loadWarnings.take(3),
                        if (_library.loadWarnings.length > 3)
                          '另有 ${_library.loadWarnings.length - 3} 条本地书库提示。',
                      ].join('\n'),
                    ),
                  ),
                ),
              if (all.any((b) => b.needsStyleUpgrade))
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text('旧版导入的书籍可再次选择原 EPUB 来更新原书样式，阅读记录会保留。'),
                  ),
                ),
              if (_selecting)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppButton.filledIcon(
                          onPressed:
                              _selected.isNotEmpty &&
                                      _canEdit &&
                                      _organization.isReady
                                  ? () => _addToCollection({..._selected})
                                  : null,
                          icon: const Icon(Icons.drive_file_move_outlined),
                          label: const Text('加入分类'),
                        ),
                        if (_organization.hasCollection(active))
                          AppButton.outlined(
                            onPressed:
                                _selected.isNotEmpty && _canEdit
                                    ? () => _organize(() async {
                                      await _organization.removeBooks(active, {
                                        ..._selected,
                                      });
                                      if (mounted) {
                                        setState(() => _selected.clear());
                                      }
                                    })
                                    : null,
                            child: const Text('从当前分类移出'),
                          ),
                      ],
                    ),
                  ),
                ),
              if (books.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
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
                            _query.trim().isNotEmpty
                                ? '没有找到这本书'
                                : all.isEmpty
                                ? '把喜欢的故事放进书架'
                                : '这个分类还没有书籍',
                            style: Theme.of(context).textTheme.titleLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _query.trim().isNotEmpty
                                ? '试试其他书名或作者。'
                                : all.isEmpty
                                ? _opener.isSupported
                                    ? '可一次选择多本 EPUB，点击书籍后在 Apple Books 中阅读。'
                                    : '可一次选择多本 EPUB，离线保留原书排版。'
                                : '在「全部」中长按书籍，即可批量加入分类。',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          if (all.isEmpty)
                            AppButton.filledIcon(
                              onPressed: _canEdit ? _import : null,
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('导入 EPUB'),
                            ),
                          if (all.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 16),
                              child: Text(
                                '支持无 DRM 的 EPUB，每本最大 128 MB。',
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (books.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  sliver: SliverGrid.builder(
                    gridDelegate: const BookGridDelegate(
                      childAspectRatio: .64,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: books.length,
                    itemBuilder: (_, index) => _bookCard(books[index]),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _bookCard(LocalEpubBook book) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected.contains(book.id);
    return Semantics(
      selected: _selecting ? selected : null,
      child: AppleGlassCard(
        key: ValueKey('local-book-${book.id}'),
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap:
              _busy
                  ? null
                  : () => _selecting ? _toggleSelection(book.id) : _open(book),
          onLongPress: _canEdit ? () => _toggleSelection(book.id) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    book.coverUrl.isEmpty
                        ? ColoredBox(
                          color: colors.primaryContainer,
                          child: Center(
                            child: Icon(
                              Icons.menu_book_rounded,
                              size: 56,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        )
                        : CachedImage(
                          url: book.coverUrl,
                          source: SourceId.localEpub,
                          fit: BoxFit.contain,
                          cacheWidth: 480,
                        ),
                    if (_selecting)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surface,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color:
                                  selected ? colors.primary : colors.onSurface,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
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
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (!_selecting)
                      AppPopupMenuButton<String>(
                        tooltip: '${book.title}的操作',
                        enabled: _canEdit,
                        onSelected: (action) {
                          if (action == 'remove') {
                            unawaited(_remove(book));
                          } else if (action == 'classify') {
                            unawaited(_addToCollection({book.id}));
                          } else {
                            _bookDetails(book);
                          }
                        },
                        itemBuilder:
                            (_) => const [
                              PopupMenuItem(
                                value: 'classify',
                                child: Text('加入分类'),
                              ),
                              PopupMenuItem(value: 'info', child: Text('书籍信息')),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('移除书籍'),
                              ),
                            ],
                      )
                    else
                      const SizedBox(height: 44, width: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _sortLabel(EpubLibrarySort sort) => switch (sort) {
  EpubLibrarySort.imported => '导入时间',
  EpubLibrarySort.title => '书名',
  EpubLibrarySort.author => '作者',
  EpubLibrarySort.recent => '最近打开',
};

void _invalidateImportedPresentation(EpubImportResult result) {
  if (result.upgraded) api.invalidateLocalEpubPresentation(result.book.id);
}
