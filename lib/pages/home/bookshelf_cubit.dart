import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';

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

  BookshelfState({
    required this.tip,
    required this.status,
    required this.bookcases,
    this.currentCaseId,
    required this.bookcaseContents,
    this.errorMessage,
    this.selectedBids = const {},
    this.isSelecting = false,
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
        orElse: () => BookcaseItem(
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
  BookshelfCubit() : super(BookshelfState(
    tip: '',
    status: BookshelfStatus.initial,
    bookcases: const [],
    bookcaseContents: const {},
  ));

  Future<void> loadBookcases() async {
    try {
      emit(state.copyWith(status: BookshelfStatus.loading));
      final bookcases = await bookcaseList();
      if (bookcases.isEmpty) {
        emit(state.copyWith(
          status: BookshelfStatus.success,
          bookcases: const [],
          bookcaseContents: const {},
        ));
        return;
      }

      final contents = <String, List<BookcaseItem>>{};

      // 先載入第一個書架，立即 emit 讓 UI 顯示
      final firstBk = await bookInCase(caseId: bookcases.first.id);
      contents[bookcases.first.id] = firstBk.items;
      emit(state.copyWith(
        tip: firstBk.tip,
        status: BookshelfStatus.success,
        bookcases: bookcases,
        currentCaseId: bookcases.first.id,
        bookcaseContents: Map.from(contents),
      ));

      // 後續書架在背景繼續載入，每載完一個就更新
      for (int i = 1; i < bookcases.length; i++) {
        final bk = await bookInCase(caseId: bookcases[i].id);
        contents[bookcases[i].id] = bk.items;
        emit(state.copyWith(
          tip: bk.tip,
          bookcaseContents: Map.from(contents),
        ));
      }
    } catch (e) {
      final msg = e.toString();
      // 403 / CF 封鎖 → 改用 WebView 繞過
      if (msg.contains('403') || msg.contains('Cloudflare') || msg.contains('cf_')) {
        emit(state.copyWith(status: BookshelfStatus.cloudflareChallenge));
      } else {
        emit(state.copyWith(status: BookshelfStatus.error, errorMessage: msg));
      }
    }
  }

  /// WebView 成功取得書架資料後呼叫
  void loadFromWebViewData(
    List<Bookcase> bookcases,
    Map<String, BookcaseDto> bookcaseContents,
  ) {
    final tip = bookcaseContents.values.isNotEmpty
        ? bookcaseContents.values.last.tip
        : '';
    final contents = bookcaseContents.map(
      (k, v) => MapEntry(k, v.items),
    );
    emit(state.copyWith(
      tip: tip,
      status: BookshelfStatus.success,
      bookcases: bookcases,
      currentCaseId: bookcases.isNotEmpty ? bookcases.first.id : null,
      bookcaseContents: contents,
    ));
  }

  void setError(String message) {
    emit(state.copyWith(status: BookshelfStatus.error, errorMessage: message));
  }

  void selectBookcase(String caseId) {
    emit(state.copyWith(currentCaseId: caseId));
  }

  void toggleSelectMode() {
    emit(state.copyWith(
      isSelecting: !state.isSelecting,
      selectedBids: state.isSelecting ? {} : state.selectedBids,
    ));
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

    try {
      await moveBookcase(
        bidList: bidsToMove.toList(),
        fromBookcaseId: fromId,
        toBookcaseId: toBookcaseId,
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('403') || msg.contains('Cloudflare') || msg.contains('cf_')) {
        rethrow; // 讓 UI 層用 WebView 重試
      }
      emit(state.copyWith(status: BookshelfStatus.error, errorMessage: msg));
      return;
    }

    // 寫入成功 → 樂觀更新本地狀態，無需等伺服器回傳
    final newContents = Map<String, List<BookcaseItem>>.from(state.bookcaseContents);
    newContents[fromId] = (newContents[fromId] ?? [])
        .where((b) => !bidsToMove.contains(b.bid))
        .toList();
    emit(state.copyWith(
      bookcaseContents: newContents,
      selectedBids: {},
      isSelecting: false,
    ));

    // 背景刷新伺服器資料（失敗不影響已更新的 UI）
    unawaited(_refreshBookcasesInBackground());
  }

  Future<void> addToBookshelf(String aid) async {
    try {
      await addBookshelf(aid: aid);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('403') || msg.contains('Cloudflare') || msg.contains('cf_')) {
        rethrow; // 讓 novel_info_page 用 WebView 重試
      }
      emit(state.copyWith(status: BookshelfStatus.error, errorMessage: msg));
      return;
    }

    // 寫入成功 → 觸發完整書架刷新（loadBookcases 有 CF 備援）
    await loadBookcases();
  }

  Future<void> removeFromBookshelf(String aid) async {
    final bid = state.getBookBid(aid);
    if (bid == null) return;

    try {
      await deleteBookcase(bid: bid);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('403') || msg.contains('Cloudflare') || msg.contains('cf_')) {
        rethrow; // 讓 novel_info_page 用 WebView 重試
      }
      emit(state.copyWith(status: BookshelfStatus.error, errorMessage: msg));
      return;
    }

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
    try {
      final contents = <String, List<BookcaseItem>>{};
      for (final bookcase in state.bookcases) {
        final bk = await bookInCase(caseId: bookcase.id);
        contents[bookcase.id] = bk.items;
      }
      emit(state.copyWith(bookcaseContents: contents));
    } catch (_) {}
  }
}
