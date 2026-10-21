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
  }) {
    return BookshelfState(
      tip: tip ?? this.tip,
      status: status ?? this.status,
      bookcases: bookcases ?? this.bookcases,
      currentCaseId: currentCaseId ?? this.currentCaseId,
      bookcaseContents: bookcaseContents ?? this.bookcaseContents,
      errorMessage: errorMessage,
      selectedBids: selectedBids ?? this.selectedBids,
      isSelecting: isSelecting ?? this.isSelecting,
      isRefreshing: isRefreshing ?? this.isRefreshing,
    );
  }

  List<BookcaseItem>? getCurrentBooks() {
    if (currentCaseId == null) return null;
    return bookcaseContents[currentCaseId];
  }

  bool isBookInBookshelf(String aid) {
    for (final books in bookcaseContents.values) {
      if (books.any((book) => book.aid == aid)) {
        return true;
      }
    }
    return false;
  }

  String? getBookBid(String aid) {
    for (final books in bookcaseContents.values) {
      final book = books.firstWhere(
        (book) => book.aid == aid,
        orElse:
            () => BookcaseItem(
              aid: '',
              bid: '',
              title: '',
              author: '',
              cid: '',
              chapterName: '',
            ),
      );
      if (book.bid.isNotEmpty) {
        return book.bid;
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
    this.requestTimeout = const Duration(seconds: 40),
  }) : _loadCases = loadCases ?? bookcaseList,
       _loadCase = loadCase ?? bookInCase,
       _scope =
           scope ??
           (() => (
             activeSource.value,
             sourceRevision.value,
             readerSessionGeneration('1'),
           )),
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
  final Duration requestTimeout;
  Object? _loadedScope;
  Future<void>? _refresh;
  final _caseLoads = <String, Future<BookcaseDto>>{};
  int _request = 0;
  void resetForGuest() {
    _request++;
    _refresh = null;
    _caseLoads.clear();
    _loadedScope = null;
    emit(
      BookshelfState(
        tip: '请在设置中登录文库8',
        status: BookshelfStatus.success,
        bookcases: const [],
        bookcaseContents: const {},
      ),
    );
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
    if (isClosed) return Future.value();
    final scope = _scope();
    if (_loadedScope != scope) {
      _request++;
      _loadedScope = scope;
      _refresh = null;
      _caseLoads.clear();
      emit(
        BookshelfState(
          tip: '',
          status: BookshelfStatus.initial,
          bookcases: const [],
          bookcaseContents: const {},
        ),
      );
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
          BookshelfState(
            tip: '',
            status: BookshelfStatus.success,
            bookcases: const [],
            bookcaseContents: const {},
          ),
        );
        return;
      }
      final contents = <String, List<BookcaseItem>>{
        for (final entry in state.bookcaseContents.entries)
          if (bookcases.any((b) => b.id == entry.key)) entry.key: entry.value,
        id!: content!.items,
      };
      emit(
        state.copyWith(
          tip: content.tip,
          status: BookshelfStatus.success,
          bookcases: bookcases,
          currentCaseId: id,
          bookcaseContents: contents,
          isRefreshing: false,
        ),
      );
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
      errorMessage:
          activeSource.value == SourceId.wenku8
              ? wenku8ReadErrorMessage(error)
              : '书架暂时无法加载，请稍后重试。',
    ),
  );

  /// WebView 成功取得書架資料後呼叫
  void loadFromWebViewData(
    List<Bookcase> bookcases,
    Map<String, BookcaseDto> bookcaseContents,
  ) {
    final tip =
        bookcaseContents.values.isNotEmpty
            ? bookcaseContents.values.last.tip
            : '';
    final contents = bookcaseContents.map((k, v) => MapEntry(k, v.items));
    emit(
      state.copyWith(
        tip: tip,
        status: BookshelfStatus.success,
        bookcases: bookcases,
        currentCaseId: bookcases.isNotEmpty ? bookcases.first.id : null,
        bookcaseContents: contents,
      ),
    );
  }

  void setError(String message) {
    emit(state.copyWith(status: BookshelfStatus.error, errorMessage: message));
  }

  Future<void> selectBookcase(String caseId) async {
    if (isClosed || !state.bookcases.any((b) => b.id == caseId)) return;
    final request = _request, scope = _scope();
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
      if (!_current(request, scope)) return;
      emit(
        state.copyWith(
          bookcaseContents: {...state.bookcaseContents, caseId: content.items},
          isRefreshing:
              state.currentCaseId == caseId ? false : state.isRefreshing,
          tip: content.tip,
        ),
      );
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
    if (state.selectedBids.isEmpty || state.currentCaseId == null) return;

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
    newContents[fromId] =
        (newContents[fromId] ?? [])
            .where((b) => !bidsToMove.contains(b.bid))
            .toList();
    emit(
      state.copyWith(
        bookcaseContents: newContents,
        selectedBids: {},
        isSelecting: false,
      ),
    );

    // 背景刷新伺服器資料（失敗不影響已更新的 UI）
    unawaited(_refreshBookcasesInBackground());
  }

  Future<void> addToBookshelf(String aid) async {
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

    // 背景刷新伺服器資料（失敗不影響已更新的 UI）
    unawaited(_refreshBookcasesInBackground());
  }

  /// 背景靜默刷新書架，失敗時不改變 UI 狀態
  Future<void> _refreshBookcasesInBackground() async {
    await loadBookcases();
  }
}
