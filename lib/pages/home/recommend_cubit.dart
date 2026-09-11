import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/src/rust/wenku8/models.dart' as w8;

abstract class RecommendState {}

class RecommendInitial extends RecommendState {}

class RecommendLoading extends RecommendState {}

class RecommendLoaded extends RecommendState {
  final List<w8.HomeBlock> blocks;
  final List<LightNovelShelfBook> lightNovelShelfBooks;

  RecommendLoaded(this.blocks, {this.lightNovelShelfBooks = const []});
}

class RecommendError extends RecommendState {
  final String message;

  RecommendError(this.message);
}

class RecommendCubit extends Cubit<RecommendState> {
  RecommendCubit({
    Future<List<w8.HomeBlock>> Function()? loadWenku8,
    Future<List<LightNovelShelfBook>> Function(bool forceRefresh)? loadShelf,
  }) : _loadWenku8 = loadWenku8 ?? w8.index,
       _loadShelf =
           loadShelf ??
           ((forceRefresh) => LightNovelShelfService.instance.fetchLatestBooks(
             forceRefresh: forceRefresh,
           )),
       super(RecommendInitial());

  final Future<List<w8.HomeBlock>> Function() _loadWenku8;
  final Future<List<LightNovelShelfBook>> Function(bool forceRefresh)
  _loadShelf;
  int _loadGeneration = 0;

  Future<void> load({bool forceRefresh = false}) async {
    final generation = ++_loadGeneration;
    emit(RecommendLoading());
    // The optional feed must never prevent the existing Wenku8 page loading.
    final shelfBooks = _loadOptionalShelf(forceRefresh);
    try {
      final blocks = await _loadWenku8();
      if (isClosed || generation != _loadGeneration) return;
      emit(RecommendLoaded(blocks));
      final books = await shelfBooks;
      if (isClosed || generation != _loadGeneration || books.isEmpty) return;
      emit(RecommendLoaded(blocks, lightNovelShelfBooks: books));
    } catch (e) {
      final books = await shelfBooks;
      if (isClosed || generation != _loadGeneration) return;
      if (books.isNotEmpty) {
        emit(RecommendLoaded(const [], lightNovelShelfBooks: books));
      } else {
        emit(RecommendError(e.toString()));
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
}
