import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/models/book_detail_hint.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/local_epub_library_page.dart';
import 'package:wild/services/bookshelf_organization.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart'
    show LocalShelfEntry, coverForBook, selectSource;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/ios_dock_insets.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/bookshelf_grid.dart';
import 'package:wild/widgets/bookshelf_sheets.dart';
import 'package:wild/widgets/bookshelf_tile.dart';
import 'package:wild/widgets/cf_action_loader.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/source_website.dart';

enum _ShelfMode { browse, select, reorder }

typedef _ShelfScope =
    ({
      SourceId? source,
      String? folder,
      String? group,
      int revision,
      Object? account,
    });

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key}) : folderId = null, initialSource = null;

  const BookshelfPage._folder({
    required this.folderId,
    required this.initialSource,
  });

  final String? folderId;
  final SourceId? initialSource;

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  late SourceId? _sourceFilter = widget.initialSource;
  late final BookshelfCubit _cubit = context.read<BookshelfCubit>();
  BookshelfOrganization get _organization => _cubit.organization;
  _ShelfMode _mode = _ShelfMode.browse;
  _ShelfScope? _editingScope;
  final _selection = <String>{};
  bool _busy = false, _openingBook = false;

  @override
  void initState() {
    super.initState();
    unawaited(_organization.load());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _organization,
    builder:
        (context, _) =>
            BlocBuilder<BookshelfCubit, BookshelfState>(builder: _buildShelf),
  );

  Widget _buildShelf(BuildContext context, BookshelfState state) {
    final folderId = widget.folderId;
    final folder = folderId == null ? null : _organization.folder(folderId);
    final sources = <SourceId?>[
      null,
      if (state.wenku8Enabled) SourceId.wenku8,
      for (final entry in state.localBooks.entries)
        if (entry.key != SourceId.esj || entry.value.isNotEmpty) entry.key,
    ];
    final source =
        folderId != null || sources.contains(_sourceFilter)
            ? _sourceFilter
            : null;
    final wenku8Only = source == SourceId.wenku8;
    final showWenku8 = state.wenku8Enabled && (source == null || wenku8Only);
    final scope = (
      source: source,
      folder: folderId,
      group: wenku8Only ? state.currentCaseId : null,
      revision: sourceRevision.value,
      account: showWenku8 ? _cubit.wenku8Scope : null,
    );
    final mode = _editingScope == scope ? _mode : _ShelfMode.browse;
    final editing = mode != _ShelfMode.browse;
    final allBooks = <String, LocalShelfEntry>{
      if (state.wenku8Enabled)
        for (final book in state.wenku8Books)
          book.aid: (book: book, coverUrl: ''),
      for (final entries in state.localBooks.values)
        for (final entry in entries) entry.book.aid: entry,
    };
    final books =
        source == null
            ? allBooks
            : wenku8Only
            ? {
              if (showWenku8)
                for (final book
                    in state.getCurrentBooks() ?? const <BookcaseItem>[])
                  book.aid: (book: book, coverUrl: ''),
            }
            : {
              for (final entry
                  in state.localBooks[source] ?? const <LocalShelfEntry>[])
                entry.book.aid: entry,
            };
    final ids =
        folderId == null
            ? _organization.rootKeys(books.keys, source: source)
            : [
              for (final id in folder?.books ?? const <String>[])
                if (books.containsKey(id)) id,
            ];
    final selected =
        mode == _ShelfMode.select
            ? ids.where(_selection.contains).toSet()
            : <String>{};
    final selectedBooks = selected.where(books.containsKey).toSet();
    final selectedFolders = selected.difference(selectedBooks);
    final destinations =
        selectedBooks.isEmpty || selectedFolders.isNotEmpty
            ? const <BookshelfDestination>[]
            : _destinations(state, scope, selectedBooks);
    final editAvailable = _organization.isReady && !_busy;
    final actions = <AppleGlassAction>[
      if (!editing) ...[
        AppleGlassAction(
          id: folderId == null ? 'new-folder' : 'rename-folder',
          label: folderId == null ? '新建文件夹' : '重命名文件夹',
          symbol: folderId == null ? 'folder.badge.plus' : 'pencil',
          fallbackIcon:
              folderId == null
                  ? (usesAppleGlass
                      ? CupertinoIcons.folder_badge_plus
                      : Icons.create_new_folder_outlined)
                  : (usesAppleGlass
                      ? CupertinoIcons.pencil
                      : Icons.edit_outlined),
          onPressed:
              editAvailable && (folderId == null || folder != null)
                  ? () => _nameFolder(scope, folder)
                  : null,
        ),
        AppleGlassAction(
          id: 'edit',
          label: '编辑书架',
          symbol: 'square.and.pencil',
          fallbackIcon:
              usesAppleGlass
                  ? CupertinoIcons.square_pencil
                  : Icons.edit_note_rounded,
          onPressed:
              editAvailable && ids.isNotEmpty
                  ? () => _setMode(scope, _ShelfMode.select)
                  : null,
        ),
      ] else ...[
        AppleGlassAction(
          id: 'interaction',
          label: mode == _ShelfMode.select ? '切换到拖动排序' : '切换到多选',
          symbol:
              mode == _ShelfMode.select
                  ? 'arrow.up.arrow.down'
                  : 'checkmark.circle',
          fallbackIcon:
              mode == _ShelfMode.select
                  ? (usesAppleGlass
                      ? CupertinoIcons.arrow_up_arrow_down
                      : Icons.swap_vert_rounded)
                  : (usesAppleGlass
                      ? CupertinoIcons.check_mark_circled
                      : Icons.check_circle_outline),
          onPressed:
              _busy
                  ? null
                  : () => _setMode(
                    scope,
                    mode == _ShelfMode.select
                        ? _ShelfMode.reorder
                        : _ShelfMode.select,
                  ),
        ),
        AppleGlassAction(
          id: 'move',
          label: '移动所选书籍',
          symbol: 'folder',
          fallbackIcon:
              usesAppleGlass
                  ? CupertinoIcons.folder
                  : Icons.drive_file_move_outline,
          onPressed:
              editAvailable && destinations.isNotEmpty
                  ? () => _move(scope, selectedBooks, destinations)
                  : null,
        ),
        AppleGlassAction(
          id: 'delete',
          label: '删除所选项目',
          symbol: 'trash',
          fallbackIcon:
              usesAppleGlass
                  ? CupertinoIcons.trash
                  : Icons.delete_outline_rounded,
          onPressed:
              editAvailable && selected.isNotEmpty
                  ? () => _delete(scope, selectedBooks, selectedFolders)
                  : null,
        ),
        AppleGlassAction(
          id: 'close',
          label: '退出编辑',
          symbol: 'xmark',
          fallbackIcon:
              usesAppleGlass ? CupertinoIcons.xmark : Icons.close_rounded,
          onPressed: _busy ? null : () => _setMode(scope, _ShelfMode.browse),
        ),
      ],
    ];
    final showFilters = !editing && folderId == null;
    final showGroups = showFilters && wenku8Only && state.bookcases.isNotEmpty;
    final refreshing = showWenku8 && state.isRefreshing;
    final padding = IosDockInsets.scrollPadding(
      context,
      const EdgeInsets.fromLTRB(16, 4, 16, 12),
    );
    final title = folder?.title ?? (folderId == null ? '书架' : '文件夹');
    final routeScope =
        '${source?.name ?? 'all'}/${scope.group ?? ''}/${folderId ?? ''}';

    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        centerTitle: !editing,
        automaticallyImplyLeading: folderId != null,
        titleTextStyle: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        leading:
            folderId != null && usesAppleGlass
                ? Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: Center(
                    child: AppleGlassActions(
                      actions: [
                        AppleGlassAction(
                          id: 'back',
                          label: '返回',
                          symbol: 'chevron.left',
                          fallbackIcon: CupertinoIcons.chevron_left,
                          onPressed: () => Navigator.maybePop(context),
                        ),
                      ],
                    ),
                  ),
                )
                : null,
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: _toolbar(actions),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            (showFilters ? 44 : 0) +
                (showGroups ? 44 : 0) +
                (refreshing || _busy ? 3 : 0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showFilters)
                Row(
                  children: [
                    Expanded(
                      child: _ShelfFilters(
                        key: const ValueKey('bookshelf-sources'),
                        labels: [
                          for (final value in sources) value?.label ?? '全部书源',
                        ],
                        selected: sources.indexOf(source),
                        onSelect:
                            (index) =>
                                setState(() => _sourceFilter = sources[index]),
                      ),
                    ),
                    if (supportsLocalEpub)
                      AppButton.textIcon(
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('本地书籍'),
                        onPressed: _openLocalLibrary,
                      ),
                  ],
                ),
              if (showGroups)
                Row(
                  children: [
                    Expanded(
                      child: _ShelfFilters(
                        labels: [
                          for (final group in state.bookcases) group.title,
                        ],
                        selected: state.bookcases.indexWhere(
                          (group) => group.id == scope.group,
                        ),
                        onSelect:
                            (index) => _cubit.selectBookcase(
                              state.bookcases[index].id,
                            ),
                      ),
                    ),
                    if (state.tip.isNotEmpty)
                      AppIconButton(
                        icon: const Icon(Icons.info_outline, size: 19),
                        tooltip: '原站书架容量',
                        onPressed: () => _showCapacity(state.tip),
                      ),
                  ],
                ),
              if (refreshing || _busy)
                const LinearProgressIndicator(minHeight: 3),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh:
            () => _refresh(showWenku8: showWenku8, wenku8Only: wenku8Only),
        child: CustomScrollView(
          key: PageStorageKey('bookshelf/$routeScope'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_organization.loadFailed)
              SliverToBoxAdapter(
                child: _notice('书架文件夹暂时无法读取', _organization.load),
              ),
            if (showWenku8 && state.errorMessage != null)
              SliverToBoxAdapter(
                child: _notice(
                  '文库8 · ${state.errorMessage!}',
                  refreshing ? null : _cubit.loadBookcases,
                  source: wenku8Only ? SourceId.wenku8 : null,
                ),
              ),
            if (!wenku8Only && state.localReadFailed)
              SliverToBoxAdapter(
                child: _notice(
                  '部分本机收藏暂时无法读取',
                  state.isLoadingLocalBooks
                      ? null
                      : () => _cubit.loadLocalShelves(refresh: true),
                ),
              ),
            if (showWenku8 &&
                folderId == null &&
                state.status == BookshelfStatus.initial)
              SliverToBoxAdapter(
                child: Center(
                  child: AppButton.text(
                    onPressed: _cubit.loadBookcases,
                    child: const Text('加载文库8书架'),
                  ),
                ),
              ),
            if (ids.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child:
                        refreshing || (!wenku8Only && state.isLoadingLocalBooks)
                            ? const CircularProgressIndicator()
                            : Text(folderId == null ? '书架为空' : '文件夹为空'),
                  ),
                ),
              ),
            if (ids.isNotEmpty)
              SliverPadding(
                padding: padding,
                sliver: BookshelfGrid(
                  key: ValueKey(scope),
                  ids: ids,
                  showSource: source == null,
                  reordering: mode == _ShelfMode.reorder && !_busy,
                  onReorder:
                      (order) => _save(
                        () => _organization.reorder(
                          order,
                          folderId: folderId,
                          allRootKeys: _organization.rootKeys(allBooks.keys),
                        ),
                      ),
                  tile: (context, id) {
                    final selecting = mode == _ShelfMode.select;
                    final book = books[id];
                    if (book != null) {
                      return BookshelfTile(
                        title: book.book.title,
                        cover: BookshelfBookCover(_cover(book)),
                        showSource: source == null,
                        sourceLabel: sourceOf(id).label,
                        unreadCount: state.unreadCounts[id],
                        selected: selected.contains(id),
                        onTap:
                            _busy
                                ? null
                                : selecting
                                ? () => _toggle(id)
                                : editing
                                ? null
                                : () => _openBook(book),
                      );
                    }
                    final tileFolder = _organization.folder(id)!;
                    final previews =
                        tileFolder.books
                            .where(books.containsKey)
                            .take(4)
                            .map((bookId) => _cover(books[bookId]!))
                            .toList();
                    return BookshelfTile(
                      title: tileFolder.title,
                      cover: BookshelfFolderCover(previews),
                      folder: true,
                      showSource: source == null,
                      selected: selected.contains(id),
                      onTap:
                          _busy
                              ? null
                              : selecting
                              ? () => _toggle(id)
                              : editing
                              ? null
                              : () => _openFolder(tileFolder, source),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(List<AppleGlassAction> actions) {
    if (usesAppleGlass) return AppleGlassActions(actions: actions);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions)
            SizedBox.square(
              dimension: 44,
              child: IconButton(
                tooltip: action.label,
                icon: Icon(action.fallbackIcon, size: 22),
                onPressed: action.onPressed,
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice(String message, VoidCallback? retry, {SourceId? source}) =>
      MaterialBanner(
        content: Text(message),
        actions: [
          if (source != null) SourceWebsiteLink(source: source),
          AppButton.text(onPressed: retry, child: const Text('重试')),
        ],
      );

  Future<void> _refresh({
    required bool showWenku8,
    required bool wenku8Only,
  }) async {
    if (_busy) return;
    await Future.wait([
      if (showWenku8) _cubit.loadBookcases(),
      if (!wenku8Only) _cubit.loadLocalShelves(refresh: true),
    ]);
    await _cubit.refreshUnreadCounts();
  }

  void _setMode(_ShelfScope scope, _ShelfMode mode) => setState(() {
    _editingScope = scope;
    _mode = mode;
    _selection.clear();
  });

  void _toggle(String id) => setState(() {
    if (!_selection.remove(id)) _selection.add(id);
  });

  bool _stillCurrent(_ShelfScope scope) =>
      mounted &&
      scope.revision == sourceRevision.value &&
      (scope.account == null ||
          (_cubit.state.wenku8Enabled &&
              scope.account == _cubit.wenku8Scope)) &&
      (scope.group == null || scope.group == _cubit.state.currentCaseId);

  Future<void> _save(Future<void> Function() edit) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await edit();
    } catch (_) {
      _message('书架操作未能完成，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _nameFolder(_ShelfScope scope, BookshelfFolder? folder) async {
    final title = await showBookshelfFolderName(
      context,
      initialName: folder?.title,
    );
    if (title == null || !_stillCurrent(scope)) return;
    await _save(
      () =>
          folder == null
              ? _organization.createFolder(title, source: scope.source)
              : _organization.renameFolder(folder.id, title),
    );
  }

  List<BookshelfDestination> _destinations(
    BookshelfState state,
    _ShelfScope scope,
    Set<String> ids,
  ) => [
    if (scope.folder != null)
      (title: '书架根目录', folderId: null, siteGroupId: null),
    for (final folder in _organization.folders)
      if (folder.id != scope.folder &&
          folder.visibleFor(scope.source) &&
          ids.every(folder.accepts))
        (title: folder.title, folderId: folder.id, siteGroupId: null),
    if (scope.source == SourceId.wenku8 && scope.group != null)
      for (final group in state.bookcases)
        if (group.id != scope.group)
          (title: group.title, folderId: null, siteGroupId: group.id),
  ];

  Future<void> _move(
    _ShelfScope scope,
    Set<String> ids,
    List<BookshelfDestination> destinations,
  ) async {
    final destination = await showBookshelfMoveSheet(
      context,
      bookCount: ids.length,
      destinations: destinations,
    );
    if (destination == null || !_stillCurrent(scope)) return;
    await _save(() async {
      if (destination.siteGroupId case final group?) {
        final moved = await _cubit.moveWenku8Books(
          ids,
          from: scope.group!,
          to: group,
          confirm: _confirmWenku8Action,
        );
        if (moved.isEmpty) {
          _message('未能移动到原站分组，请重试。');
          return;
        }
      } else {
        await _organization.moveBooks(ids, folderId: destination.folderId);
      }
      if (mounted) setState(_selection.clear);
    });
  }

  Future<void> _delete(
    _ShelfScope scope,
    Set<String> books,
    Set<String> folders,
  ) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder:
          (dialog) => AlertDialog.adaptive(
            title: const Text('删除所选项目？'),
            content: Text(
              [
                if (books.isNotEmpty) '所选 ${books.length} 本书将从书架移除。',
                if (folders.isNotEmpty) '所选文件夹中的书籍会移回书架根目录。',
              ].join('\n'),
            ),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              AppButton.text(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirmed != true || !_stillCurrent(scope)) return;
    await _save(() async {
      final removed = await _cubit.removeShelfBooks(
        books,
        confirm: _confirmWenku8Action,
      );
      await _organization.removeItems(books: removed, folderIds: folders);
      if (!mounted) return;
      setState(() => _selection.removeAll({...removed, ...folders}));
      final remaining = books.length - removed.length;
      if (remaining > 0) _message('有 $remaining 本书未能移除，可重试。');
    });
  }

  Future<bool> _confirmWenku8Action(Wenku8ShelfAction action) async {
    if (!mounted) return false;
    final digits = RegExp(r'^\d{1,12}$');
    if (!digits.hasMatch(action.from) ||
        (action.to != '-1' && !digits.hasMatch(action.to)) ||
        !action.bids.every(digits.hasMatch)) {
      return false;
    }
    final apiHost = context.read<ApiHostCubit>().state;
    final effectiveHost = apiHost.isEmpty ? 'https://www.wenku8.net' : apiHost;
    final bidsJs = action.bids
        .map(
          (bid) => '''
        (function(){ var i=document.createElement('input');i.type='hidden';i.name='checkid[]';i.value='$bid';f.appendChild(i); })();
      ''',
        )
        .join('');
    final jsAction = '''
(function() {
  var f = document.createElement('form');
  f.method = 'POST';
  f.action = '$effectiveHost/modules/article/bookcase.php';
  $bidsJs
  var fields = {classlist: '${action.from}', checkall: 'checkall', newclassid: '${action.to}', classid: '${action.from}'};
  Object.keys(fields).forEach(function(k) {
    var i = document.createElement('input'); i.type = 'hidden'; i.name = k; i.value = fields[k];
    f.appendChild(i);
  });
  document.body.appendChild(f);
  f.submit();
})();
''';
    return await showAdaptiveDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder:
              (dialog) => Dialog.fullscreen(
                child: CfActionLoader(
                  apiHost: effectiveHost,
                  jsAction: jsAction,
                  successUrlKeyword: 'bookcase.php',
                  successBodyKeyword: '处理成功',
                  onSuccess: () => Navigator.pop(dialog, true),
                  onError: (_) => Navigator.pop(dialog, false),
                ),
              ),
        ) ??
        false;
  }

  void _showCapacity(String tip) => showAdaptiveDialog<void>(
    context: context,
    builder:
        (_) =>
            AlertDialog.adaptive(title: const Text('书架容量'), content: Text(tip)),
  );

  void _openLocalLibrary() => Navigator.of(context).push(
    HorizontalCoverPageRoute(builder: (_) => const LocalEpubLibraryPage()),
  );

  void _openFolder(BookshelfFolder folder, SourceId? source) => Navigator.of(
    context,
  ).push(
    HorizontalCoverPageRoute(
      builder:
          (_) =>
              BookshelfPage._folder(folderId: folder.id, initialSource: source),
    ),
  );

  ShelfCover _cover(LocalShelfEntry entry) {
    final aid = entry.book.aid, source = sourceOf(entry.book.aid);
    if (source == SourceId.wenku8) {
      final id = int.tryParse(aid);
      return (
        source: source,
        url:
            id == null || id <= 0
                ? ''
                : 'https://img.wenku8.com/image/${id ~/ 1000}/$aid/${aid}s.jpg',
      );
    }
    final cached = coverForBook(aid);
    return (source: source, url: cached.isEmpty ? entry.coverUrl : cached);
  }

  Future<void> _openBook(LocalShelfEntry entry) async {
    if (_openingBook) return;
    _openingBook = true;
    final route = ModalRoute.of(context);
    try {
      final item = entry.book;
      final cover = _cover(entry);
      if (cover.source == SourceId.bili && activeSource.value != cover.source) {
        await selectSource(cover.source);
      }
      if (!mounted || route?.isCurrent == false) return;
      BookDetailHint.remember(item.aid, item.title, cover.url);
      await Navigator.pushNamed(context, '/novel/info', arguments: item.aid);
      if (mounted) unawaited(_cubit.refreshUnreadCounts());
    } catch (_) {
      _message('暂时无法打开这本书，请重试。');
    } finally {
      _openingBook = false;
    }
  }
}

class _ShelfFilters extends StatelessWidget {
  const _ShelfFilters({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: colors.surfaceContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 34,
          child: LayoutBuilder(
            builder: (context, box) {
              final minimum = math.min(
                120.0,
                box.maxWidth / math.min(labels.length, 3),
              );
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: labels.length,
                itemBuilder: (context, index) {
                  final active = index == selected;
                  return Semantics(
                    button: true,
                    selected: active,
                    child: Ink(
                      decoration: ShapeDecoration(
                        color:
                            active
                                ? (usesAppleGlass
                                    ? colors.surfaceContainerHighest
                                    : colors.primaryContainer)
                                : Colors.transparent,
                        shape: const StadiumBorder(),
                      ),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: () => onSelect(index),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: minimum,
                            maxWidth: 170,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: Center(
                              widthFactor: 1,
                              child: Text(
                                labels[index],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(
                                  context,
                                ).textTheme.labelMedium?.copyWith(
                                  color:
                                      active && !usesAppleGlass
                                          ? colors.onPrimaryContainer
                                          : colors.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
