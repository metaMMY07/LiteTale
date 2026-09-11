import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/source_api.dart' as w8;

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
  HistoryCubit() : super(HistoryInitial());

  Future<void> load() async {
    final request = ++_request;
    emit(HistoryLoading());
    try {
      final histories = await w8.listReadingHistory(offset: 0, limit: 100);
      if (isClosed || request != _request) return;
      emit(HistoryLoaded(histories));
    } catch (e) {
      if (isClosed || request != _request) return;
      emit(HistoryError(e.toString()));
    }
  }

  Future<void> deleteHistory(String novelId) async {
    if (state is! HistoryLoaded) return;

    try {
      await w8.deleteHistoryByNovelId(novelId: novelId);
      final currentState = state as HistoryLoaded;
      final updatedHistories = currentState.histories.where((h) => h.novelId != novelId).toList();
      emit(HistoryLoaded(updatedHistories));
    } catch (e) {
      emit(HistoryError(e.toString()));
    }
  }
}
