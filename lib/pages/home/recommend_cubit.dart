import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/huanmeng_source.dart' show HuanmengSourceException;
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/src/rust/wenku8/models.dart' as w8;

abstract class RecommendState {}

class RecommendInitial extends RecommendState {}

class RecommendLoading extends RecommendState {}

class RecommendLoaded extends RecommendState {
  final List<w8.HomeBlock> blocks;
  final List<LightNovelShelfBook> lightNovelShelfBooks;
  final bool isWenku8WebViewFallback;
  final List<w8.NovelCover> moreBooks;
  final int page;
  final bool hasMore, loadingMore;
  final String? moreError;
  final Object? moreCause;

  RecommendLoaded(
    this.blocks, {
    this.lightNovelShelfBooks = const [],
    this.isWenku8WebViewFallback = false,
    this.moreBooks = const [],
    this.page = 0,
    this.hasMore = false,
    this.loadingMore = false,
    this.moreError,
    this.moreCause,
  });

  RecommendLoaded more({
    List<w8.NovelCover>? books,
    int? page,
    bool? hasMore,
    bool loading = false,
    String? error,
    Object? cause,
  }) => RecommendLoaded(
    blocks,
    lightNovelShelfBooks: lightNovelShelfBooks,
    isWenku8WebViewFallback: isWenku8WebViewFallback,
    moreBooks: books ?? moreBooks,
    page: page ?? this.page,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loading,
    moreError: error,
    moreCause: cause,
  );
}

class RecommendError extends RecommendState {
  final String message;
  final Object? cause;

  RecommendError(this.message, {this.cause});
}

class RecommendCubit extends Cubit<RecommendState> {
  RecommendCubit({
    Future<List<w8.HomeBlock>> Function()? loadWenku8,
    Future<List<LightNovelShelfBook>> Function(bool forceRefresh)? loadShelf,
    Future<w8.PageStatsNovelCover> Function(SourceId source, int page)?
    loadMore,
  }) : _loadWenku8 = loadWenku8 ?? w8.index,
       _loadShelf =
           loadShelf ??
           ((forceRefresh) => LightNovelShelfService.instance.fetchLatestBooks(
             forceRefresh: forceRefresh,
           )),
       _loadMore = loadMore ?? _page,
       super(RecommendInitial());

  final Future<List<w8.HomeBlock>> Function() _loadWenku8;
  final Future<List<LightNovelShelfBook>> Function(bool forceRefresh)
  _loadShelf;
  int _loadGeneration = 0;
  ReadRequest? _readRequest, _moreRequest;
  bool _paging = false;
  final Future<w8.PageStatsNovelCover> Function(SourceId, int) _loadMore;
  static Future<w8.PageStatsNovelCover> _page(SourceId source, int page) {
    if (source == SourceId.huanmeng) return w8.huanmengSource.list(page: page);
    if (source == SourceId.esj) return w8.esjSource.list(page: page);
    if (source == SourceId.bili) {
      return w8.biliSource.listPage(page, mode: 'all');
    }
    if (source == SourceId.lnovel) return w8.lnovelSource.list(page: page);
    if (source == SourceId.lightNovelShelf) {
      return w8.shelfSource.list(page: page);
    }
    throw UnsupportedError('此书源未提供首页续页，请从全部页面浏览');
  }

  Future<void> loadMore() {
    final before = state;
    if (_paging || before is! RecommendLoaded || !before.hasMore) {
      return Future.value();
    }
    _moreRequest?.cancel();
    final request = _moreRequest = ReadRequest();
    return ReadRequest.run(request, _loadMorePage);
  }

  Future<void> _loadMorePage() async {
    final before = state;
    if (_paging || before is! RecommendLoaded || !before.hasMore) return;
    final generation = _loadGeneration,
        source = activeSource.value,
        revision = sourceRevision.value;
    bool current() =>
        !isClosed &&
        generation == _loadGeneration &&
        source == activeSource.value &&
        revision == sourceRevision.value;
    _paging = true;
    emit(before.more(loading: true));
    try {
      final result = await _loadMore(source, before.page + 1);
      if (!current()) return;
      final seen = {
        for (final block in before.blocks)
          for (final book in block.list) book.aid,
        for (final book in before.moreBooks) book.aid,
      };
      final additional =
          result.records.where((book) => seen.add(book.aid)).toList();
      if ((source == SourceId.huanmeng || source == SourceId.esj) &&
          result.records.isNotEmpty &&
          additional.isEmpty) {
        throw const HuanmengSourceException('原站续页未提供新书籍，请稍后刷新。');
      }
      final books = [...before.moreBooks, ...additional];
      emit(
        before.more(
          books: books,
          page: result.currentPage,
          hasMore:
              result.records.isNotEmpty && result.maxPage > result.currentPage,
        ),
      );
    } catch (e) {
      if (current()) emit(before.more(error: '更多书籍加载失败，点击重试', cause: e));
    } finally {
      if (current()) _paging = false;
    }
  }

  /// Applies a validated Wenku8 DOM result and invalidates older API retries.
  /// Source checking here prevents a late WebView result from entering another
  /// source's discovery state.
  bool showWenku8WebViewFallback(List<w8.HomeBlock> blocks) {
    if (isClosed ||
        activeSource.value != SourceId.wenku8 ||
        blocks.isEmpty ||
        blocks.every((block) => block.list.isEmpty)) {
      return false;
    }
    ++_loadGeneration;
    emit(
      RecommendLoaded(List.unmodifiable(blocks), isWenku8WebViewFallback: true),
    );
    return true;
  }

  Future<void> load({bool forceRefresh = false}) async {
    _readRequest?.cancel();
    _moreRequest?.cancel();
    final request = _readRequest = ReadRequest();
    await ReadRequest.run(request, () => _load(forceRefresh: forceRefresh));
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final generation = ++_loadGeneration;
    _paging = false;
    final source = activeSource.value;
    final revision = sourceRevision.value;
    bool current() =>
        !isClosed &&
        generation == _loadGeneration &&
        source == activeSource.value &&
        revision == sourceRevision.value;
    emit(RecommendLoading());
    // The optional feed must never prevent the existing Wenku8 page loading.
    final shelfBooks =
        source == SourceId.huanmeng || source == SourceId.esj
            ? Future.value(const <LightNovelShelfBook>[])
            : _loadOptionalShelf(forceRefresh);
    try {
      final first =
          source == SourceId.huanmeng || source == SourceId.esj
              ? await _loadMore(source, 1)
              : null;
      final blocks =
          first == null
              ? await _loadWenku8()
              : [
                w8.HomeBlock(
                  title: '${source.label} · 最新更新',
                  list: first.records,
                ),
              ];
      if (!current()) return;
      emit(
        RecommendLoaded(
          blocks,
          page: first?.currentPage ?? 0,
          hasMore:
              first == null
                  ? source != SourceId.wenku8 && !source.isRule
                  : first.currentPage < first.maxPage,
        ),
      );
      final books = await shelfBooks;
      if (!current() || books.isEmpty) return;
      final currentState = state;
      emit(
        RecommendLoaded(
          blocks,
          lightNovelShelfBooks: books,
          moreBooks:
              currentState is RecommendLoaded
                  ? currentState.moreBooks
                  : const [],
          page: currentState is RecommendLoaded ? currentState.page : 0,
          hasMore: currentState is RecommendLoaded && currentState.hasMore,
        ),
      );
    } catch (e) {
      final books = await shelfBooks;
      if (!current()) return;
      if (books.isNotEmpty) {
        emit(RecommendLoaded(const [], lightNovelShelfBooks: books));
      } else {
        emit(RecommendError(e.toString(), cause: e));
      }
    }
  }

  Future<List<LightNovelShelfBook>> _loadOptionalShelf(
    bool forceRefresh,
  ) async {
    try {
      return await _loadShelf(forceRefresh);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> close() {
    _loadGeneration++;
    _readRequest?.cancel();
    _moreRequest?.cancel();
    return super.close();
  }
}
