import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/utils/wenku8_network_error.dart';

enum BookshelfStatus { initial, loading, success, error, cloudflareChallenge }

class BookshelfState {
  final String tip;
  final BookshelfStatus status;
  final List<Bookcase> bookcases;
  final String? currentCaseId;
  final Map<String, List<BookcaseItem>> bookcaseContents;
  final String? errorMessage;
  final Set<String> selectedBids; // 选中的书籍 bid 集合
  final bool isSelecting; // 是否处于多选模式
  final bool isRefreshing;
  final bool wenku8Enabled;
  final Map<SourceId, List<LocalShelfEntry>> localBooks;
  final bool isLoadingLocalBooks;
  final bool localReadFailed;
  final Map<String, int> unreadCounts;

  BookshelfState({
    required this.tip,
    required this.status,
    required this.bookcases,
    this.currentCaseId,
    required this.bookcaseContents,
    this.errorMessage,
    this.selectedBids = const {},
    this.isSelecting = false,
    this.isRefreshing = false,
    this.wenku8Enabled = false,
    this.localBooks = const {},
    this.isLoadingLocalBooks = false,
    this.localReadFailed = false,
    this.unreadCounts = const {},
  });

  BookshelfState copyWith({
    String? tip,
    BookshelfStatus? status,
    List<Bookcase>? bookcases,
    String? currentCaseId,
    Map<String, List<BookcaseItem>>? bookcaseContents,
    String? errorMessage,
    Set<String>? selectedBids,
    bool? isSelecting,
    bool? isRefreshing,
    Map<SourceId, List<LocalShelfEntry>>? localBooks,
    bool? isLoadingLocalBooks,
    bool? localReadFailed,
    Map<String, int>? unreadCounts,
  }) {
    return BookshelfState(
      tip: tip ?? this.tip,
      status: status ?? this.status,
      bookcases: bookcases ?? this.bookcases,
      currentCaseId:
          bookcases?.isEmpty == true
              ? null
              : currentCaseId ?? this.currentCaseId,
      bookcaseContents: bookcaseContents ?? this.bookcaseContents,
      errorMessage: errorMessage,
      selectedBids: selectedBids ?? this.selectedBids,
      isSelecting: isSelecting ?? this.isSelecting,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      wenku8Enabled: wenku8Enabled,
      localBooks: localBooks ?? this.localBooks,
      isLoadingLocalBooks: isLoadingLocalBooks ?? this.isLoadingLocalBooks,
      localReadFailed: localReadFailed ?? this.localReadFailed,
      unreadCounts: unreadCounts ?? this.unreadCounts,
    );
  }

  List<BookcaseItem>? getCurrentBooks() {
    if (currentCaseId == null) return null;
    return bookcaseContents[currentCaseId];
  }

  Iterable<BookcaseItem> get wenku8Books sync* {
    final seen = <String>{};
    for (final group in bookcases) {
      for (final book in bookcaseContents[group.id] ?? const <BookcaseItem>[]) {
        if (seen.add(book.aid)) yield book;
      }
    }
  }

  bool isBookInBookshelf(String aid) => getBookBid(aid) != null;

  String? getBookBid(String aid) {
    final source = sourceOf(aid);
    if (source != SourceId.wenku8) {
      for (final entry in localBooks[source] ?? const <LocalShelfEntry>[]) {
        if (entry.book.aid == aid) return entry.book.bid;
      }
      return null;
    }
    for (final books in bookcaseContents.values) {
      for (final book in books) {
        if (book.aid == aid && book.bid.isNotEmpty) return book.bid;
      }
    }
    return null;
  }

  bool isBookSelected(String bid) => selectedBids.contains(bid);
}

class BookshelfCubit extends Cubit<BookshelfState> {
  BookshelfCubit({
    Future<List<Bookcase>> Function()? loadCases,
    Future<BookcaseDto> Function({required String caseId})? loadCase,
    Object Function()? scope,
    Iterable<SourceId> Function()? localSources,
    Future<List<LocalShelfEntry>> Function(SourceId)? loadLocal,
    Future<Map<String, int>> Function(Iterable<String>)? loadUnread,
    this.requestTimeout = const Duration(seconds: 40),
  }) : _loadCases = loadCases ?? (() => bookcaseList(source: SourceId.wenku8)),
       _loadCase = loadCase ?? wenku8BookInCase,
       _scope = scope ?? (() => readerSessionGeneration('1')),
       _localSources = localSources ?? (() => localShelfSources),
       _loadLocal = loadLocal ?? loadLocalShelf,
       _loadUnread = loadUnread ?? loadShelfUnreadCounts,
       super(
         BookshelfState(
           tip: '',
           status: BookshelfStatus.initial,
           bookcases: const [],
           bookcaseContents: const {},
         ),
       );

  final Future<List<Bookcase>> Function() _loadCases;
  final Future<BookcaseDto> Function({required String caseId}) _loadCase;
  final Object Function() _scope;
  final Iterable<SourceId> Function() _localSources;
  final Future<List<LocalShelfEntry>> Function(SourceId) _loadLocal;
  final Future<Map<String, int>> Function(Iterable<String>) _loadUnread;
  final Duration requestTimeout;
  Object? _loadedScope;
  Future<void>? _refresh;
  final _caseLoads = <String, Future<BookcaseDto>>{};
  int _request = 0;
  bool _wenku8Enabled = true;
  Future<void>? _localRefresh;
  int? _localRevision;
  int _localRequest = 0;
  Future<void>? _unreadRefresh;
  bool _unreadDirty = false;

  void setWenku8Enabled(bool enabled) {
    if (isClosed ||
        (_wenku8Enabled == enabled && state.wenku8Enabled == enabled)) {
      return;
    }
    _wenku8Enabled = enabled;
    invalidateWenku8();
  }

  void invalidateWenku8() {
    if (isClosed) return;
    _request++;
    _refresh = null;
    _caseLoads.clear();
    _loadedScope = null;
    emit(
      BookshelfState(
        tip: '',
        status: BookshelfStatus.initial,
        bookcases: const [],
        bookcaseContents: const {},
        wenku8Enabled: _wenku8Enabled,
        localBooks: state.localBooks,
        isLoadingLocalBooks: state.isLoadingLocalBooks,
        localReadFailed: state.localReadFailed,
        unreadCounts: {
          for (final entry in state.unreadCounts.entries)
            if (sourceOf(entry.key) != SourceId.wenku8) entry.key: entry.value,
        },
      ),
    );
  }

  Future<void> loadLocalShelves({bool refresh = false}) {
    if (isClosed) return Future.value();
    final revision = sourceRevision.value;
    final sources = _localSources().toSet();
    if (_localRevision != revision) {
      _localRequest++;
      _localRefresh = null;
      _localRevision = revision;
      emit(
        state.copyWith(
          localBooks: {
            for (final entry in state.localBooks.entries)
              if (sources.contains(entry.key)) entry.key: entry.value,
          },
          errorMessage: state.errorMessage,
          unreadCounts: const {},
        ),
      );
    } else {
      if (_localRefresh case final pending?) return pending;
      if (!refresh) return Future.value();
    }
    final request = _localRequest;
    late final Future<void> pending;
    pending = _refreshLocalShelves(sources, revision, request).whenComplete(() {
      if (identical(_localRefresh, pending)) _localRefresh = null;
    });
    _localRefresh = pending;
    return pending;
  }

  Future<void> _refreshLocalShelves(
    Set<SourceId> sources,
    int revision,
    int request,
  ) async {
    bool current() =>
        !isClosed &&
        revision == sourceRevision.value &&
        request == _localRequest;

    emit(
      state.copyWith(
        isLoadingLocalBooks: true,
        errorMessage: state.errorMessage,
      ),
    );
    final books = Map<SourceId, List<LocalShelfEntry>>.of(state.localBooks);
    final clock = Stopwatch()..start();
    var failed = false;
    for (final source in sources) {
      final remaining = requestTimeout - clock.elapsed;
      if (!current()) return;
      if (remaining <= Duration.zero) {
        failed = true;
        break;
      }
      try {
        const perSource = Duration(seconds: 2);
        books[source] = await _loadLocal(
          source,
        ).timeout(remaining < perSource ? remaining : perSource);
      } catch (_) {
        failed = true;
      }
    }
    if (!current()) return;
    emit(
      state.copyWith(
        localBooks: Map.unmodifiable(books),
        isLoadingLocalBooks: false,
        localReadFailed: failed,
        errorMessage: state.errorMessage,
      ),
    );
    unawaited(refreshUnreadCounts());
  }

  Future<void> refreshUnreadCounts() {
    if (isClosed) return Future.value();
    _unreadDirty = true;
    return _unreadRefresh ??= _refreshUnreadCounts();
  }

  Future<void> _refreshUnreadCounts() async {
    await Future<void>.value();
    try {
      while (_unreadDirty && !isClosed) {
        _unreadDirty = false;
        final request = _request,
            localRequest = _localRequest,
            scope = _scope();
        final ids = {
          for (final book in state.wenku8Books) book.aid,
          for (final entries in state.localBooks.values)
            for (final entry in entries) entry.book.aid,
        };
        Map<String, int> counts;
        try {
          counts = ids.isEmpty ? const {} : await _loadUnread(ids);
        } catch (_) {
          counts = const {};
        }
        if (!_current(request, scope) ||
            localRequest != _localRequest ||
            _unreadDirty) {
          continue;
        }
        emit(
          state.copyWith(
            unreadCounts: Map.unmodifiable({
              for (final entry in counts.entries)
                if (ids.contains(entry.key) && entry.value > 0)
                  entry.key: entry.value,
            }),
            errorMessage: state.errorMessage,
          ),
        );
      }
    } finally {
      _unreadRefresh = null;
    }
  }

  bool _current(int request, Object scope) =>
      !isClosed && request == _request && scope == _scope();

  Future<BookcaseDto> _case(String id) => _caseLoads.putIfAbsent(id, () {
    late final Future<BookcaseDto> pending;
    pending = Future<BookcaseDto>.sync(
      () => _loadCase(caseId: id),
    ).timeout(requestTimeout).whenComplete(() {
      if (identical(_caseLoads[id], pending)) _caseLoads.remove(id);
    });
    return pending;
  });

  Future<void> loadBookcases() {
    if (isClosed || !_wenku8Enabled) return Future.value();
    final scope = _scope();
    if (_loadedScope != scope) {
      invalidateWenku8();
      _loadedScope = scope;
    }
    if (_refresh case final pending?) return pending;
    final request = _request;
    late final Future<void> pending;
    pending = _refreshCurrent(request, scope).whenComplete(() {
      if (identical(_refresh, pending)) _refresh = null;
    });
    _refresh = pending;
    return pending;
  }

  Future<void> _refreshCurrent(int request, Object scope) async {
    var accepting = true;
    final hasData = state.bookcaseContents.isNotEmpty;
    emit(
      state.copyWith(
        status: hasData ? BookshelfStatus.success : BookshelfStatus.loading,
        isRefreshing: true,
      ),
    );
    try {
      // One refresh owns one group. Other groups load when selected, not as
      // unsolicited account requests behind a foreground book opening.
      final snapshot = await (() async {
        final groups = await _loadCases();
        if (!accepting || !_current(request, scope) || groups.isEmpty) {
          return (groups, null, null);
        }
        final id =
            groups.any((b) => b.id == state.currentCaseId)
                ? state.currentCaseId!
                : groups.first.id;
        return (groups, id, await _case(id));
      })().timeout(requestTimeout);
      if (!_current(request, scope)) return;
      final (bookcases, id, content) = snapshot;
      if (bookcases.isEmpty) {
        emit(
          state.copyWith(
            tip: '',
            status: BookshelfStatus.success,
            bookcases: const [],
            bookcaseContents: const {},
            isRefreshing: false,
            isSelecting: false,
            selectedBids: const {},
          ),
        );
        unawaited(refreshUnreadCounts());
        return;
      }
      final current = state.currentCaseId;
      final selected =
          bookcases.any((group) => group.id == current) ? current! : id!;
      final contents = <String, List<BookcaseItem>>{
        for (final entry in state.bookcaseContents.entries)
          if (bookcases.any((b) => b.id == entry.key)) entry.key: entry.value,
        id!: content!.items,
      };
      emit(
        state.copyWith(
          tip: selected == id ? content.tip : state.tip,
          status: BookshelfStatus.success,
          bookcases: bookcases,
          currentCaseId: selected,
          bookcaseContents: contents,
          isRefreshing: _caseLoads.containsKey(selected),
        ),
      );
      unawaited(refreshUnreadCounts());
    } catch (e) {
      accepting = false;
      if (!_current(request, scope)) return;
      _readFailed(e);
    } finally {
      accepting = false;
    }
  }

  void _readFailed(Object error) => emit(
    state.copyWith(
      status:
          state.bookcaseContents.isEmpty
              ? BookshelfStatus.error
              : BookshelfStatus.success,
      isRefreshing: false,
      errorMessage: wenku8ReadErrorMessage(error),
    ),
  );

  Future<void> selectBookcase(String caseId) async {
    if (isClosed || !state.bookcases.any((b) => b.id == caseId)) return;
    final request = _request, scope = _scope();
    if (_loadedScope != scope) {
      await loadBookcases();
      return;
    }
    emit(
      state.copyWith(
        currentCaseId: caseId,
        isRefreshing: true,
        selectedBids: {},
        isSelecting: false,
      ),
    );
    try {
      final content = await _case(caseId);
      if (!_current(request, scope) ||
          !state.bookcases.any((group) => group.id == caseId)) {
        return;
      }
      final selected = state.currentCaseId == caseId;
      emit(
        state.copyWith(
          bookcaseContents: {...state.bookcaseContents, caseId: content.items},
          isRefreshing: selected ? false : state.isRefreshing,
          tip: selected ? content.tip : state.tip,
          errorMessage: selected ? null : state.errorMessage,
        ),
      );
      unawaited(refreshUnreadCounts());
    } catch (error) {
      if (_current(request, scope) && state.currentCaseId == caseId) {
        _readFailed(error);
      }
    }
  }

  void toggleSelectMode() {
    emit(
      state.copyWith(
        isSelecting: !state.isSelecting,
        selectedBids: state.isSelecting ? {} : state.selectedBids,
      ),
    );
  }

  void toggleBookSelection(String bid) {
    final newSelectedBids = Set<String>.from(state.selectedBids);
    if (newSelectedBids.contains(bid)) {
      newSelectedBids.remove(bid);
    } else {
      newSelectedBids.add(bid);
    }
    emit(state.copyWith(selectedBids: newSelectedBids));
  }

  Future<void> moveSelectedBooks(String toBookcaseId) async {
    if (!_wenku8Enabled ||
        state.selectedBids.isEmpty ||
        state.currentCaseId == null) {
      return;
    }

    final bidsToMove = Set<String>.from(state.selectedBids);
    final fromId = state.currentCaseId!;
    final request = _request, scope = _scope();

    try {
      await moveBookcase(
        bidList: bidsToMove.toList(),
        fromBookcaseId: fromId,
        toBookcaseId: toBookcaseId,
      );
    } catch (e) {
      if (!_current(request, scope)) return;
      if (shouldUseWenku8WebViewFallback(e)) {
        rethrow; // 讓 UI 層用 WebView 重試
      }
      _readFailed(e);
      return;
    }
    if (!_current(request, scope)) return;
    _request++;
    _refresh = null;
    _caseLoads.clear();

    // 寫入成功 → 樂觀更新本地狀態，無需等伺服器回傳
    final newContents = Map<String, List<BookcaseItem>>.from(
      state.bookcaseContents,
    );
    final affected =
        toBookcaseId == '-1' ? newContents.keys.toList() : [fromId];
    for (final id in affected) {
      newContents[id] =
          (newContents[id] ?? [])
              .where((b) => !bidsToMove.contains(b.bid))
              .toList();
    }
    emit(
      state.copyWith(
        bookcaseContents: newContents,
        selectedBids: {},
        isSelecting: false,
      ),
    );
    unawaited(refreshUnreadCounts());

    // 背景刷新伺服器資料（失敗不影響已更新的 UI）
    unawaited(_refreshBookcasesInBackground());
  }

  Future<void> addToBookshelf(String aid) async {
    if (sourceOf(aid) != SourceId.wenku8) {
      await addBookshelf(aid: aid);
      await _reloadLocalBooks();
      return;
    }
    if (!_wenku8Enabled) throw StateError('请先登录文库8');
    final request = _request, scope = _scope();
    try {
      await addBookshelf(aid: aid);
    } catch (e) {
      if (!_current(request, scope)) return;
      if (shouldUseWenku8WebViewFallback(e)) {
        rethrow; // 讓 novel_info_page 用 WebView 重試
      }
      _readFailed(e);
      return;
    }
    if (!_current(request, scope)) return;
    _request++;
    _refresh = null;
    _caseLoads.clear();

    // 寫入成功 → 觸發完整書架刷新（loadBookcases 有 CF 備援）
    await loadBookcases();
  }

  Future<void> removeFromBookshelf(String aid) async {
    final bid = state.getBookBid(aid);
    if (bid == null) return;
    final source = sourceOf(aid);
    if (source != SourceId.wenku8) {
      await deleteBookcase(bid: bid);
      if (isClosed) return;
      if (state.localBooks[source] case final books?) {
        emit(
          state.copyWith(
            localBooks: {
              ...state.localBooks,
              source: books.where((item) => item.book.aid != aid).toList(),
            },
            errorMessage: state.errorMessage,
          ),
        );
      }
      await _reloadLocalBooks();
      return;
    }
    if (!_wenku8Enabled) return;
    final request = _request, scope = _scope();

    try {
      await deleteBookcase(bid: bid);
    } catch (e) {
      if (!_current(request, scope)) return;
      if (shouldUseWenku8WebViewFallback(e)) {
        rethrow; // 讓 novel_info_page 用 WebView 重試
      }
      _readFailed(e);
      return;
    }
    if (!_current(request, scope)) return;
    _request++;
    _refresh = null;
    _caseLoads.clear();

    // 寫入成功 → 樂觀從本地狀態移除
    final newContents = <String, List<BookcaseItem>>{};
    for (final entry in state.bookcaseContents.entries) {
      newContents[entry.key] = entry.value.where((b) => b.bid != bid).toList();
    }
    emit(state.copyWith(bookcaseContents: newContents));
    unawaited(refreshUnreadCounts());

    // 背景刷新伺服器資料（失敗不影響已更新的 UI）
    unawaited(_refreshBookcasesInBackground());
  }

  /// 背景靜默刷新書架，失敗時不改變 UI 狀態
  Future<void> _refreshBookcasesInBackground() async {
    await loadBookcases();
  }

  Future<void> _reloadLocalBooks() {
    _localRequest++;
    _localRefresh = null;
    return loadLocalShelves(refresh: true);
  }
}
