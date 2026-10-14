import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_pagination_cache.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import '../../src/rust/wenku8/models.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/cubits/font_settings_cubit.dart';

class ReaderCubit extends Cubit<ReaderState> {
  int _request = 0;
  String? _loadedContent;
  String? _contentAid;
  String? _contentCid;
  ReaderPosition? _position;
  ReaderPageOffsets? _offsets;
  String? _sourceFont;
  int? _contentSession;
  bool _closing = false;
  final Future<SourceChapter> Function({
    required String aid,
    required String cid,
  })
  _read;
  final int Function(String aid) _session;
  final ReadingProgressQueue _progress;
  final NovelInfo novelInfo;
  String initialAid;
  String initialCid;
  final List<Volume> initialVolumes;
  final FontSizeCubit fontSizeCubit;
  final ParagraphSpacingCubit paragraphSpacingCubit;
  final LineHeightCubit lineHeightCubit;
  final TopBarHeightCubit topBarHeightCubit;
  final BottomBarHeightCubit bottomBarHeightCubit;
  final LeftPaddingCubit leftPaddingCubit;
  final RightPaddingCubit rightPaddingCubit;
  final FontSettingsCubit fontSettingsCubit;

  ReaderCubit({
    required this.novelInfo,
    required this.initialAid,
    required this.initialCid,
    required this.initialVolumes,
    required this.fontSizeCubit,
    required this.paragraphSpacingCubit,
    required this.lineHeightCubit,
    required this.topBarHeightCubit,
    required this.bottomBarHeightCubit,
    required this.leftPaddingCubit,
    required this.rightPaddingCubit,
    required this.fontSettingsCubit,
    Future<SourceChapter> Function({required String aid, required String cid})?
    read,
    int Function(String aid)? sessionGeneration,
    ReadingProgressQueue? progress,
  }) : _read = read ?? readerChapter,
       _session = sessionGeneration ?? readerSessionGeneration,
       _progress = progress ?? ReadingProgressQueue.instance,
       super(ReaderInitial());

  String _findChapterTitle(String aid, String cid) {
    for (final volume in initialVolumes) {
      for (final chapter in volume.chapters) {
        if (chapter.aid == aid && chapter.cid == cid) {
          return chapter.title;
        }
      }
    }
    return '';
  }

  Volume _findVolume(String aid, String cid) {
    for (final volume in initialVolumes) {
      for (final chapter in volume.chapters) {
        if (chapter.aid == aid && chapter.cid == cid) {
          return volume;
        }
      }
    }
    throw Exception('Volume not found');
  }

  Future<void> loadChapter({String? aid, String? cid, int? initialPage}) async {
    if (_closing || isClosed) return;
    final request = ++_request;
    final targetAid = aid ?? initialAid;
    final targetCid = cid ?? initialCid;
    final session = _session(targetAid);
    final revision = sourceRevision.value;
    bool sourceMatches() =>
        sourceOf(targetAid) != SourceId.bili ||
        (activeSource.value == SourceId.bili &&
            sourceRevision.value == revision);
    try {
      unawaited(_progress.flushBounded());
      emit(ReaderLoading(super.state.showControls));
      initialAid = targetAid;
      initialCid = targetCid;

      final chapterTitle = _findChapterTitle(targetAid, targetCid);
      final chapter = await _read(aid: targetAid, cid: targetCid);
      if (_closing || isClosed || request != _request || !sourceMatches()) {
        return;
      }
      if (_session(targetAid) != session) {
        emit(ReaderError('账号已变化，请重新打开章节。'));
        return;
      }
      final content = chapter.content;
      _loadedContent = content;
      _contentAid = targetAid;
      _contentCid = targetCid;
      _sourceFont = chapter.fontFamily;
      _contentSession = session;

      final fontSize = fontSizeCubit.state;
      final paragraphSpacing = paragraphSpacingCubit.state;
      final lineHeight = lineHeightCubit.state;

      // 分页内容
      final pagination = _paginateContent(
        targetAid,
        targetCid,
        chapterTitle,
        content,
        fontSize,
        paragraphSpacing,
        lineHeight,
      );
      final pages = pagination.pages;

      // 验证并设置初始页码
      int pageIndex = 0;
      if (initialPage != null) {
        if (initialPage >= 0 && initialPage < pages.length) {
          pageIndex = initialPage;
        }
      }

      // 计算从第一页到当前页的累计字数
      _offsets = ReaderPageOffsets(pages);
      _position = _offsets!.at(pageIndex);

      if (isClosed || request != _request || !sourceMatches()) return;
      emit(
        ReaderLoaded(
          aid: targetAid,
          cid: targetCid,
          title: chapterTitle,
          volumes: initialVolumes,
          pages: pages,
          layout: pagination.layout,
          fontFamily: pagination.fontFamily,
          currentPageIndex: pageIndex,
          showControls: super.state.showControls,
        ),
      );
      _savePageHistory(state as ReaderLoaded);
    } catch (e) {
      if (isClosed || request != _request || !sourceMatches()) return;
      final sessionMatches = _session(targetAid) == session;
      emit(
        ReaderError(
          sessionMatches ? e.toString() : '账号已变化，请重新打开章节。',
          cause: sessionMatches ? e : null,
        ),
      );
    }
  }

  Future reloadCurrentPage() async {
    if (_closing || state is! ReaderLoaded) return;
    final request = ++_request;
    final targetAid = initialAid;
    final targetCid = initialCid;
    final session = _session(targetAid);
    final revision = sourceRevision.value;
    bool sourceMatches() =>
        sourceOf(targetAid) != SourceId.bili ||
        (activeSource.value == SourceId.bili &&
            sourceRevision.value == revision);
    try {
      if (_contentSession != session) {
        emit(ReaderError('账号已变化，请重新打开章节。'));
        return;
      }

      final chapterTitle = _findChapterTitle(targetAid, targetCid);
      final content =
          _contentAid == targetAid &&
                  _contentCid == targetCid &&
                  _loadedContent != null
              ? _loadedContent!
              : (await _read(aid: targetAid, cid: targetCid)).content;
      if (isClosed || request != _request || !sourceMatches()) return;

      // Paging remains available while the content request is pending. Read
      // the latest position now, not the one at the start of that request.
      final latest = state;
      if (latest is! ReaderLoaded ||
          latest.aid != targetAid ||
          latest.cid != targetCid) {
        return;
      }
      final position =
          _position ?? ReaderPosition.at(latest.pages, latest.currentPageIndex);

      final fontSize = fontSizeCubit.state;
      final paragraphSpacing = paragraphSpacingCubit.state;
      final lineHeight = lineHeightCubit.state;

      final pagination = _paginateContent(
        targetAid,
        targetCid,
        chapterTitle,
        content,
        fontSize,
        paragraphSpacing,
        lineHeight,
      );
      final pages = pagination.pages;

      final currentPageIndex = position.pageIn(pages);
      _offsets = ReaderPageOffsets(pages);

      emit(
        ReaderLoaded(
          aid: targetAid,
          cid: targetCid,
          title: chapterTitle,
          volumes: initialVolumes,
          pages: pages,
          layout: pagination.layout,
          fontFamily: pagination.fontFamily,
          currentPageIndex: currentPageIndex,
          showControls: super.state.showControls,
        ),
      );
      _savePageHistory(state as ReaderLoaded);
    } catch (e) {
      if (isClosed || request != _request || !sourceMatches()) return;
      final sessionMatches = _session(targetAid) == session;
      emit(
        ReaderError(
          sessionMatches ? e.toString() : '账号已变化，请重新打开章节。',
          cause: sessionMatches ? e : null,
        ),
      );
    }
  }

  void onPageChanged(int index) {
    if (state is ReaderLoaded) {
      final currentState = state as ReaderLoaded;
      if (index < 0 || index >= currentState.pages.length) return;
      _position = (_offsets ??= ReaderPageOffsets(currentState.pages)).at(
        index,
      );
      emit(currentState.copyWith(currentPageIndex: index));

      _savePageHistory(state as ReaderLoaded);
    }
  }

  void _savePageHistory(ReaderLoaded currentState) {
    final index = currentState.currentPageIndex;
    final characterCount = (_offsets ??= ReaderPageOffsets(currentState.pages))
        .charactersThrough(index);
    final session = _contentSession;
    final sessionFor = _session;
    final bookId = currentState.aid;

    // 更新阅读历史中的页码
    _progress.enqueue(
      ReadingProgress(
        bookId: currentState.aid,
        title: novelInfo.title,
        volumeId: _findVolume(currentState.aid, currentState.cid).id,
        volumeTitle: _findVolume(currentState.aid, currentState.cid).title,
        chapterId: currentState.cid,
        chapterTitle: currentState.title,
        characters: characterCount,
        page: index,
        cover: novelInfo.imgUrl,
        author: novelInfo.author,
      ),
      isValid: () => sessionFor(bookId) == session,
    );
  }

  Future goToPreviousChapter() async {
    if (!_canGoPrevious()) return;

    final currentVolumeIndex = _findCurrentVolumeIndex();
    final currentChapterIndex = _findCurrentChapterIndex();

    Volume volume;
    Chapter chapter;
    if (currentChapterIndex > 0) {
      // 同一卷的上一章
      volume = initialVolumes[currentVolumeIndex];
      chapter =
          initialVolumes[currentVolumeIndex].chapters[currentChapterIndex - 1];
      await loadChapter(aid: chapter.aid, cid: chapter.cid, initialPage: 0);
    } else if (currentVolumeIndex > 0) {
      // 上一卷的最后一章
      volume = initialVolumes[currentVolumeIndex - 1];
      chapter = volume.chapters.last;
      await loadChapter(aid: chapter.aid, cid: chapter.cid, initialPage: 0);
    } else {
      // 已经是第一章
      return;
    }
  }

  void goToNextChapter() async {
    if (!_canGoNext()) return;

    final currentVolumeIndex = _findCurrentVolumeIndex();
    final currentChapterIndex = _findCurrentChapterIndex();

    Volume volume;
    Chapter chapter;
    if (currentChapterIndex <
        initialVolumes[currentVolumeIndex].chapters.length - 1) {
      // 同一卷的下一章
      volume = initialVolumes[currentVolumeIndex];
      chapter =
          initialVolumes[currentVolumeIndex].chapters[currentChapterIndex + 1];
      await loadChapter(aid: chapter.aid, cid: chapter.cid, initialPage: 0);
    } else if (currentVolumeIndex < initialVolumes.length - 1) {
      // 下一卷的第一章
      volume = initialVolumes[currentVolumeIndex + 1];
      chapter = volume.chapters.first;
      await loadChapter(aid: chapter.aid, cid: chapter.cid, initialPage: 0);
    } else {
      // 已经是最后一章
      return;
    }
  }

  bool _canGoPrevious() {
    if (initialVolumes.isEmpty) return false;
    final currentVolumeIndex = _findCurrentVolumeIndex();
    final currentChapterIndex = _findCurrentChapterIndex();
    return currentChapterIndex > 0 || currentVolumeIndex > 0;
  }

  bool _canGoNext() {
    if (initialVolumes.isEmpty) return false;
    final currentVolumeIndex = _findCurrentVolumeIndex();
    final currentChapterIndex = _findCurrentChapterIndex();
    return currentChapterIndex <
            initialVolumes[currentVolumeIndex].chapters.length - 1 ||
        currentVolumeIndex < initialVolumes.length - 1;
  }

  int _findCurrentVolumeIndex() {
    for (var i = 0; i < initialVolumes.length; i++) {
      final volume = initialVolumes[i];
      if (volume.chapters.any(
        (chapter) => chapter.aid == initialAid && chapter.cid == initialCid,
      )) {
        return i;
      }
    }
    return -1;
  }

  int _findCurrentChapterIndex() {
    final volumeIndex = _findCurrentVolumeIndex();
    if (volumeIndex == -1) return -1;
    final volume = initialVolumes[volumeIndex];
    for (var i = 0; i < volume.chapters.length; i++) {
      final chapter = volume.chapters[i];
      if (chapter.aid == initialAid && chapter.cid == initialCid) {
        return i;
      }
    }
    return -1;
  }

  ({List<ReaderPage> pages, ReaderViewportLayout layout, String fontFamily})
  _paginateContent(
    String aid,
    String cid,
    String title,
    String content,
    double fontSize,
    double paragraphSpacing,
    double lineHeight,
  ) {
    final metrics = MediaQueryData.fromView(
      WidgetsBinding.instance.platformDispatcher.views.first,
    );
    final layout = ReaderViewportLayout(
      size: metrics.size,
      systemPadding: metrics.padding,
      topBarHeight: topBarHeightCubit.state,
      bottomBarHeight: bottomBarHeightCubit.state,
      leftPadding: leftPaddingCubit.state,
      rightPadding: rightPaddingCubit.state,
      textScaler: metrics.textScaler,
      boldText: metrics.boldText,
    );
    final fontFamily = fontSettingsCubit.state.resolveReaderFamily(_sourceFont);
    final pages = ReaderPaginationCache.instance.paginate(
      sourceId: sourceOf(aid).name,
      bookId: aid,
      chapterId: cid,
      sessionGeneration: _contentSession ?? _session(aid),
      content: content,
      canvasWidth: layout.contentWidth,
      canvasHeight: layout.contentHeight,
      fontSize: fontSize,
      paragraphSpacing: paragraphSpacing,
      lineHeight: lineHeight,
      fontFamily: fontFamily,
      textScaler: layout.textScaler,
      boldText: layout.boldText,
    );
    return (pages: pages, layout: layout, fontFamily: fontFamily);
  }

  void toggleControls() {
    if (state is ReaderLoaded) {
      final currentState = state as ReaderLoaded;
      emit(currentState.copyWith(showControls: !currentState.showControls));
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    _request++;
    await super.close();
    await _progress.flushBounded();
  }
}

abstract class ReaderState {
  bool get showControls;
}

class ReaderInitial extends ReaderState {
  @override
  get showControls => false;
}

class ReaderLoading extends ReaderState {
  @override
  final bool showControls;

  ReaderLoading(this.showControls);
}

class ReaderError extends ReaderState {
  final String error;
  final Object? cause;

  ReaderError(this.error, {this.cause});

  @override
  get showControls => false;
}

class ReaderLoaded extends ReaderState {
  final String aid;
  final String cid;
  final String title;
  final List<ReaderPage> pages;
  final ReaderViewportLayout layout;
  final String fontFamily;
  final List<Volume> volumes;
  final int currentPageIndex;
  @override
  final bool showControls;

  ReaderLoaded({
    required this.aid,
    required this.cid,
    required this.title,
    required this.volumes,
    required this.pages,
    required this.layout,
    required this.fontFamily,
    required this.currentPageIndex,
    required this.showControls,
  });

  ReaderLoaded copyWith({
    String? aid,
    String? cid,
    String? title,
    List<ReaderPage>? pages,
    List<Volume>? volumes,
    int? currentPageIndex,
    bool? showControls,
  }) {
    return ReaderLoaded(
      aid: aid ?? this.aid,
      cid: cid ?? this.cid,
      title: title ?? this.title,
      volumes: volumes ?? this.volumes,
      pages: pages ?? this.pages,
      layout: layout,
      fontFamily: fontFamily,
      currentPageIndex: currentPageIndex ?? this.currentPageIndex,
      showControls: showControls ?? this.showControls,
    );
  }
}
