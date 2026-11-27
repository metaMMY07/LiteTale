import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/source_api.dart';

class NovelDownloadState {
  final List<NovelDownload> downloads;
  final bool isLoading;
  final String? error;

  NovelDownloadState({
    this.downloads = const [],
    this.isLoading = false,
    this.error,
  });

  NovelDownloadState copyWith({
    List<NovelDownload>? downloads,
    bool? isLoading,
    String? error,
  }) {
    return NovelDownloadState(
      downloads: downloads ?? this.downloads,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class NovelDownloadCubit extends Cubit<NovelDownloadState> {
  NovelDownloadCubit() : super(NovelDownloadState());

  int _request = 0;

  Future<void> loadDownloads({bool keepVisible = false}) async {
    if (isClosed) return;
    final request = ++_request;
    final refreshing = keepVisible && state.downloads.isNotEmpty;
    if (!refreshing || state.isLoading || state.error != null) {
      emit(state.copyWith(isLoading: !refreshing));
    }
    try {
      final downloads = await allDownloads();
      if (isClosed || request != _request) return;
      emit(state.copyWith(downloads: downloads, isLoading: false));
    } catch (e) {
      if (isClosed || request != _request || refreshing) return;
      emit(state.copyWith(error: e.toString(), isLoading: false));
    }
  }
}
