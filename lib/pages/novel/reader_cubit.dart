import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/services/reader_position.dart';
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
  }) : super(ReaderInitial());

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
    final request = ++_request;
    try {
      emit(ReaderLoading(super.state.showControls));
      initialAid = aid ?? initialAid;
      initialCid = cid ?? initialCid;

      final targetAid = initialAid;
      final targetCid = initialCid;

      final chapterTitle = _findChapterTitle(targetAid, targetCid);
      final volume = _findVolume(targetAid, targetCid);
      final content = await chapterContent(aid: targetAid, cid: targetCid);
      if (isClosed || request != _request) return;
      _loadedContent = content;
      _contentAid = targetAid;
      _contentCid = targetCid;

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
      _position = ReaderPosition.at(pages, pageIndex);
      final characterCount = _calculateCharacterCountUpToPage(pages, pageIndex);

      // 更新阅读历史
      await updateHistory(
        novelId: targetAid,
        novelName: novelInfo.title,
        volumeId: volume.id,
        volumeName: volume.title,
        chapterId: targetCid,
        chapterTitle: chapterTitle,
        progress: characterCount,
        progressPage: pageIndex,
        cover: novelInfo.imgUrl,
        author: novelInfo.author,
      );

      if (isClosed || request != _request) return;
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
    } catch (e) {
      if (isClosed || request != _request) return;
      emit(ReaderError(e.toString()));
    }
  }

  Future reloadCurrentPage() async {
    if (state is! ReaderLoaded) return;
    final request = ++_request;
    try {
      final targetAid = initialAid;
      final targetCid = initialCid;

      final chapterTitle = _findChapterTitle(targetAid, targetCid);
      final content =
          _contentAid == targetAid &&
                  _contentCid == targetCid &&
                  _loadedContent != null
              ? _loadedContent!
              : await chapterContent(aid: targetAid, cid: targetCid);
      if (isClosed || request != _request) return;

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
      await _savePageHistory(state as ReaderLoaded);
    } catch (e) {
      if (isClosed || request != _request) return;
      emit(ReaderError(e.toString()));
    }
  }

  void onPageChanged(int index) {
    if (state is ReaderLoaded) {
      final currentState = state as ReaderLoaded;
      if (index < 0 || index >= currentState.pages.length) return;
      _position = ReaderPosition.at(currentState.pages, index);
      emit(currentState.copyWith(currentPageIndex: index));

      _savePageHistory(state as ReaderLoaded);
    }
  }

  Future<void> _savePageHistory(ReaderLoaded currentState) async {
    final index = currentState.currentPageIndex;
    // 计算从第一页到当前页的累计字数
    final characterCount = _calculateCharacterCountUpToPage(
      currentState.pages,
      index,
    );

    // 更新阅读历史中的页码
    await updateHistory(
      novelId: currentState.aid,
      novelName: novelInfo.title,
      volumeId: _findVolume(currentState.aid, currentState.cid).id,
      volumeName: _findVolume(currentState.aid, currentState.cid).title,
      chapterId: currentState.cid,
      chapterTitle: currentState.title,
      progress: characterCount,
      progressPage: index,
      cover: novelInfo.imgUrl,
      author: novelInfo.author,
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

  /// 计算从第一页到指定页码的累计字数
  int _calculateCharacterCountUpToPage(List<ReaderPage> pages, int pageIndex) {
    int totalCharacters = 0;
    for (int i = 0; i <= pageIndex && i < pages.length; i++) {
      final page = pages[i];
      if (!page.isImage) {
        // 只计算文本页面的字数，排除图片页面
        totalCharacters += page.content.length;
      }
    }
    return totalCharacters;
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
    final fontFamily = fontSettingsCubit.state.resolveReaderFamily(
      chapterFont(aid, cid),
    );
    final pages = paginateReaderContent(
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

  ReaderError(this.error);

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
