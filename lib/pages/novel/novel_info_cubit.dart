import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/read_diagnostics.dart';
import 'package:wild/utils/wenku8_network_error.dart';
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
  ReadRequest? _readRequest;
  final Future<SourceBookDetail> Function({required String aid}) _loadDetail;
  final Future<w8.ReadingHistory?> Function({required String novelId})
  _loadHistory;
  final Duration loadTimeout;

  NovelInfoCubit(
    this.novelId, {
    Future<NovelInfo> Function({required String aid})? loadInfo,
    Future<List<Volume>> Function({required String aid})? loadVolumes,
    Future<SourceBookDetail> Function({required String aid})? loadDetail,
    Future<w8.ReadingHistory?> Function({required String novelId})? loadHistory,
    this.loadTimeout = const Duration(seconds: 45),
  }) : _loadDetail =
           loadDetail ??
           (loadInfo == null && loadVolumes == null
               ? w8.loadBookDetail
               : (({required String aid}) async {
                 final revision = sourceRevision.value;
                 final info = await (loadInfo ?? w8.novelInfo)(aid: aid);
                 ReadRequest.current?.check();
                 if (sourceOf(aid) == SourceId.bili &&
                     (activeSource.value != SourceId.bili ||
                         sourceRevision.value != revision)) {
                   throw const ReadCancelled();
                 }
                 return SourceBookDetail(
                   info,
                   await (loadVolumes ?? w8.novelReader)(aid: aid),
                 );
               })),
       _loadHistory = loadHistory ?? w8.novelHistoryById,
       super(NovelInfoInitial());

  List<Volume> get volumes => _volumes;

  Future<void> load() async {
    if (isClosed) return;
    final generation = ++_loadGeneration;
    _readRequest?.cancel();
    final readRequest = _readRequest = ReadRequest();
    final clock = ReadDiagnostics.enabled ? (Stopwatch()..start()) : null;
    final revision = sourceRevision.value;
    bool current() =>
        !isClosed &&
        generation == _loadGeneration &&
        (sourceOf(novelId) != SourceId.bili ||
            (activeSource.value == SourceId.bili &&
                sourceRevision.value == revision));
    emit(NovelInfoLoading());
    try {
      // Local progress is optional. A busy database must not keep a complete
      // network book behind the loading screen, nor fail its detail page.
      Future<w8.ReadingHistory?> optionalHistory() async {
        try {
          return await ReadDiagnostics.measure(
            sourceOf(novelId).name,
            'progress_read',
            () => _loadHistory(
              novelId: novelId,
            ).timeout(const Duration(seconds: 2)),
          );
        } catch (_) {
          return null;
        }
      }

      final history =
          sourceOf(novelId) == SourceId.wenku8 ? optionalHistory() : null;
      final detail = await ReadRequest.run(
        readRequest,
        () => readRequest
            .wait(_loadDetail(aid: novelId))
            .timeout(
              loadTimeout,
              onTimeout: () {
                final error = TimeoutException('作品详情与目录请求超时', loadTimeout);
                readRequest.cancel(error);
                throw error;
              },
            ),
      );
      final novelInfo = detail.info, volumes = detail.volumes;
      if (!current()) return;
      final readingHistory = await (history ?? optionalHistory());
      if (!current()) return;
      _volumes = volumes;
      ReadDiagnostics.record(
        sourceOf(novelId).name,
        'detail_state_ready',
        clock?.elapsed ?? Duration.zero,
      );
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
          sourceOf(novelId) == SourceId.wenku8
              ? wenku8ReadErrorMessage(e)
              : e.toString(),
          loginRequired: e is ShelfSignInRequired,
          cause: e,
        ),
      );
    }
  }

  @override
  Future<void> close() {
    _loadGeneration++;
    _readRequest?.cancel();
    return super.close();
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
