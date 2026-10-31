import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/sources/book_source.dart';
import 'package:wild/services/read_request.dart';

abstract class HistoryState {}

class HistoryInitial extends HistoryState {}

class HistoryLoading extends HistoryState {}

class HistoryLoaded extends HistoryState {
  final List<w8.ReadingHistory> histories;

  HistoryLoaded(this.histories);
}

class HistoryError extends HistoryState {
  final String message;

  HistoryError(this.message);
}

class HistoryCubit extends Cubit<HistoryState> {
  int _request = 0;
  ReadRequest? _opening;
  bool localOnly = false;
  SourceId get historySource =>
      localOnly ? SourceId.localEpub : activeSource.value;
  HistoryCubit() : super(HistoryInitial());

  void showLocal(bool local) {
    if (localOnly == local) return;
    localOnly = local;
    _opening?.cancel();
    load();
  }

  Future<SourceBookDetail> loadDetail(String aid) async {
    _opening?.cancel();
    final request = _opening = ReadRequest();
    final source = historySource;
    final revision = sourceRevision.value;
    final detail = await ReadRequest.run(
      request,
      () => request.wait(w8.loadBookDetail(aid: aid)),
    );
    request.check();
    if (isClosed ||
        historySource != source ||
        sourceRevision.value != revision) {
      throw const ReadCancelled();
    }
    return detail;
  }

  @override
  Future<void> close() {
    _opening?.cancel();
    return super.close();
  }

  Future<void> load() async {
    final request = ++_request;
    emit(HistoryLoading());
    try {
      final histories = await w8.listReadingHistory(
        offset: 0,
        limit: 100,
        source: historySource,
      );
      if (isClosed || request != _request) return;
      emit(HistoryLoaded(histories));
    } catch (e) {
      if (isClosed || request != _request) return;
      emit(HistoryError(e.toString()));
    }
  }

  Future<void> deleteHistory(String novelId) async {
    if (state is! HistoryLoaded) return;
    final request = _request;
    final original = state as HistoryLoaded;
    if (!original.histories.any((h) => h.novelId == novelId)) return;
    try {
      await w8.deleteHistoryByNovelId(novelId: novelId);
      if (isClosed || request != _request || state is! HistoryLoaded) return;
      final currentState = state as HistoryLoaded;
      final updatedHistories =
          currentState.histories.where((h) => h.novelId != novelId).toList();
      emit(HistoryLoaded(updatedHistories));
    } catch (e) {
      if (isClosed || request != _request) return;
      emit(HistoryError(e.toString()));
    }
  }
}
