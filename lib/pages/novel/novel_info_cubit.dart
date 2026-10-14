import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/sources/shelf_session.dart';

import '../../src/rust/wenku8/models.dart';

abstract class NovelInfoState {}

class NovelInfoInitial extends NovelInfoState {}

class NovelInfoLoading extends NovelInfoState {}

class NovelInfoLoaded extends NovelInfoState {
  final NovelInfo novelInfo;
  final List<Volume> volumes;
  final w8.ReadingHistory? readingHistory;

  NovelInfoLoaded({
    required this.novelInfo,
    required this.volumes,
    this.readingHistory,
  });
}

class NovelInfoError extends NovelInfoState {
  final String message;
  final bool loginRequired;
  final Object? cause;

  NovelInfoError(this.message, {this.loginRequired = false, this.cause});
}

class NovelInfoCubit extends Cubit<NovelInfoState> {
  final String novelId;
  List<Volume> _volumes = [];
  int _loadGeneration = 0;
  final Future<NovelInfo> Function({required String aid}) _loadInfo;
  final Future<List<Volume>> Function({required String aid}) _loadVolumes;
  final Future<w8.ReadingHistory?> Function({required String novelId})
  _loadHistory;

  NovelInfoCubit(
    this.novelId, {
    Future<NovelInfo> Function({required String aid})? loadInfo,
    Future<List<Volume>> Function({required String aid})? loadVolumes,
    Future<w8.ReadingHistory?> Function({required String novelId})? loadHistory,
  }) : _loadInfo = loadInfo ?? w8.novelInfo,
       _loadVolumes = loadVolumes ?? w8.novelReader,
       _loadHistory = loadHistory ?? w8.novelHistoryById,
       super(NovelInfoInitial());

  List<Volume> get volumes => _volumes;

  Future<void> load() async {
    if (isClosed) return;
    final generation = ++_loadGeneration;
    final revision = sourceRevision.value;
    bool current() =>
        !isClosed &&
        generation == _loadGeneration &&
        (sourceOf(novelId) != SourceId.bili ||
            (activeSource.value == SourceId.bili &&
                sourceRevision.value == revision));
    emit(NovelInfoLoading());
    try {
      final novelInfo = await _loadInfo(aid: novelId);
      if (!current()) return;
      final volumes = await _loadVolumes(aid: novelId);
      if (!current()) return;
      final readingHistory = await _loadHistory(novelId: novelId);
      if (!current()) return;
      _volumes = volumes;
      emit(
        NovelInfoLoaded(
          novelInfo: novelInfo,
          volumes: _volumes,
          readingHistory: readingHistory,
        ),
      );
    } catch (e) {
      if (!current()) return;
      emit(
        NovelInfoError(
          e.toString(),
          loginRequired: e is ShelfSignInRequired,
          cause: e,
        ),
      );
    }
  }

  Future<void> loadHistory() async {
    final generation = _loadGeneration;
    final revision = sourceRevision.value;
    final readingHistory = await _loadHistory(novelId: novelId);
    if (isClosed || generation != _loadGeneration) return;
    if (sourceOf(novelId) == SourceId.bili &&
        (activeSource.value != SourceId.bili ||
            sourceRevision.value != revision)) {
      return;
    }
    if (state is NovelInfoLoaded) {
      final currentState = state as NovelInfoLoaded;
      emit(
        NovelInfoLoaded(
          novelInfo: currentState.novelInfo,
          volumes: currentState.volumes,
          readingHistory: readingHistory,
        ),
      );
    }
  }
}
