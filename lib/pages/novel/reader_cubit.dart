import 'dart:async';
import 'package:wild/services/read_request.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/epub/epub_css_reader.dart';
import 'theme_cubit.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/models/reader_mark.dart';
import 'package:wild/services/reader_mark_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_pagination_cache.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/services/reader_chapter_prefetch.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/services/epub_reader_position.dart';
import 'package:wild/services/epub_book_flow.dart';
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
  EpubCssReader? _cssReader;
  final ReaderTheme Function()? readerTheme;
  final Future<void>? layoutReady;
  Future<bool>? _initialRouteArrival;
  EpubBookFlow? _bookFlow;
  EpubFlowWindow? _bookWindow;
  bool _warmingBook = false;
  bool _reflowingBook = false;
  int _request = 0;
  int _seekGeneration = 0;
  ReadRequest? _readRequest;
  String? _loadedContent;
  ReaderDocument? _loadedDocument;
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
    required bool Function() isCurrent,
  })
  _read;
  final int Function(String aid) _session;
  final ReadingProgressQueue _progress;
  final ReaderChapterPrefetch? _prefetch;
  final Future<ReaderPosition?> Function(String bookId, String chapterId)?
  _loadPosition;
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
    this.readerTheme,
    this.layoutReady,
    Future<bool>? initialRouteArrival,
    Future<SourceChapter> Function({required String aid, required String cid})?
    read,
    int Function(String aid)? sessionGeneration,
    ReadingProgressQueue? progress,
    ReaderPrefetchLoad? prefetch,
    Future<ReaderPosition?> Function(String bookId, String chapterId)?
    loadPosition,
  }) : _initialRouteArrival = initialRouteArrival,
       _read =
           read == null
               ? readerChapter
               : (({
                 required String aid,
                 required String cid,
                 required bool Function() isCurrent,
               }) => read(aid: aid, cid: cid)),
       _session = sessionGeneration ?? readerSessionGeneration,
       _progress = progress ?? ReadingProgressQueue.instance,
       _loadPosition =
           loadPosition ??
           (read == null ? EpubReaderPositionStore.instance.read : null),
       _prefetch =
           read != null && prefetch == null
               ? null
               : ReaderChapterPrefetch(prefetch ?? prefetchReaderChapter),
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

  Future<void> loadChapter({
    String? aid,
    String? cid,
    int? initialPage,
    int? initialTextOffset,
    ReaderMark? readerMark,
  }) async {
    if (_closing || isClosed) return;
    final request = ++_request;
    _readRequest?.cancel();
    final readRequest = _readRequest = ReadRequest();
    final targetAid = aid ?? initialAid;
    final targetCid = cid ?? initialCid;
    if (sourceOf(targetAid) == SourceId.localEpub) {
      final anchor = readerMark?.location;
      await _loadLocalBook(
        targetAid,
        targetCid,
        request,
        initialPage:
            anchor?.axis == ReaderMarkAxis.page ? anchor!.offset : initialPage,
        initialTextOffset: readerMark == null ? initialTextOffset : null,
        position:
            anchor == null || anchor.axis == ReaderMarkAxis.page
                ? null
                : ReaderPosition(
                  anchor.axis == ReaderMarkAxis.text ? anchor.offset : 0,
                  anchor.imageIndex ?? 0,
                  anchor.imageIndex != null,
                  epubOffset:
                      anchor.axis == ReaderMarkAxis.epubDom
                          ? anchor.offset
                          : null,
                ),
      );
      return;
    }
    _prefetch?.foreground(targetAid, targetCid);
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
      final chapter = await ReadRequest.run(
        readRequest,
        () => readRequest.wait(
          _read(
            aid: targetAid,
            cid: targetCid,
            isCurrent:
                () =>
                    !_closing &&
                    !isClosed &&
                    request == _request &&
                    sourceMatches() &&
                    _session(targetAid) == session,
          ),
        ),
      );
      if (_closing || isClosed || request != _request || !sourceMatches()) {
        return;
      }
      if (_initialRouteArrival case final arrival?) {
        // Start the source request immediately. Only the first synchronous
        // page layout waits for the iOS slide and its final system insets.
        if (!await readRequest.wait(arrival)) return;
        if (layoutReady case final ready?) await readRequest.wait(ready);
        _initialRouteArrival = null;
        if (_closing || isClosed || request != _request || !sourceMatches()) {
          return;
        }
      }
      if (_session(targetAid) != session) {
        emit(ReaderError('账号已变化，请重新打开章节。'));
        return;
      }
      final content = chapter.content;
      _loadedContent = content;
      _loadedDocument = chapter.document;
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
      final savedPosition =
          _loadedDocument != null && initialTextOffset != null
              ? await _loadPosition?.call(targetAid, targetCid)
              : null;
      if (_closing ||
          isClosed ||
          request != _request ||
          !sourceMatches() ||
          _session(targetAid) != session) {
        return;
      }

      // 验证并设置初始页码
      int pageIndex = 0;
      if (initialPage != null) {
        if (initialPage >= 0 && initialPage < pages.length) {
          pageIndex = initialPage;
        }
      }
      if (savedPosition != null) {
        pageIndex = savedPosition.pageIn(pages);
      } else if (_loadedDocument != null &&
          initialTextOffset != null &&
          initialTextOffset >= 0) {
        final priorImage =
            initialPage != null &&
            initialPage >= 0 &&
            initialPage < pages.length &&
            pages[initialPage].isImage &&
            pages[initialPage].textStart == initialTextOffset;
        pageIndex =
            priorImage
                ? initialPage
                : ReaderPosition(initialTextOffset, 0, false).pageIn(pages);
      }
      if (readerMark != null) {
        pageIndex =
            _markPageIndex(
              readerMark,
              pages,
              readerMarkText(content, chapter.document),
            ) ??
            pageIndex;
      }

      // 计算从第一页到当前页的累计字数
      _offsets = ReaderPageOffsets(pages);
      _position = savedPosition ?? _offsets!.at(pageIndex);

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
      _prefetch?.schedule(
        aid: targetAid,
        cid: targetCid,
        volumes: initialVolumes,
        isCurrent:
            () =>
                !_closing &&
                !isClosed &&
                _session(targetAid) == session &&
                (sourceOf(targetAid) == SourceId.localEpub ||
                    (sourceRevision.value == revision &&
                        activeSource.value == sourceOf(targetAid))),
      );
    } catch (e) {
      if (isClosed || request != _request || !sourceMatches()) return;
      final sessionMatches = _session(targetAid) == session;
      emit(
        ReaderError(
          sessionMatches
              ? (sourceOf(targetAid) == SourceId.wenku8
                  ? wenku8ReadErrorMessage(e)
                  : e.toString())
              : '账号已变化，请重新打开章节。',
          cause: sessionMatches ? e : null,
        ),
      );
    }
  }

  Future reloadCurrentPage() async {
    if (_closing || state is! ReaderLoaded) return;
    if (_bookFlow != null && _bookWindow != null) {
      final loaded = state as ReaderLoaded;
      final request = ++_request;
      await _loadLocalBook(
        loaded.aid,
        loaded.cid,
        request,
        position: _position,
        preserveControls: loaded.showControls,
        showLoading: false,
      );
      return;
    }
    final request = ++_request;
    final targetAid = initialAid;
    _readRequest?.cancel();
    final readRequest = _readRequest = ReadRequest();
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
      var content = _loadedContent;
      if (_contentAid != targetAid ||
          _contentCid != targetCid ||
          content == null) {
        final chapter = await ReadRequest.run(
          readRequest,
          () => readRequest.wait(
            _read(
              aid: targetAid,
              cid: targetCid,
              isCurrent:
                  () =>
                      !_closing &&
                      !isClosed &&
                      request == _request &&
                      sourceMatches() &&
                      _session(targetAid) == session,
            ),
          ),
        );
        if (_closing ||
            isClosed ||
            request != _request ||
            !sourceMatches() ||
            _session(targetAid) != session) {
          return;
        }
        content = chapter.content;
        _loadedContent = content;
        _loadedDocument = chapter.document;
        _sourceFont = chapter.fontFamily;
        _contentAid = targetAid;
        _contentCid = targetCid;
      }
      if (isClosed ||
          request != _request ||
          !sourceMatches() ||
          _session(targetAid) != session) {
        return;
      }

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
          sessionMatches
              ? (sourceOf(targetAid) == SourceId.wenku8
                  ? wenku8ReadErrorMessage(e)
                  : e.toString())
              : '账号已变化，请重新打开章节。',
          cause: sessionMatches ? e : null,
        ),
      );
    }
  }

  /// Online counts are chapter-local. Local EPUBs use the owning chapter's
  /// complete pagination, never the changing 64-page preloading window.
  String get footerPageLabel {
    final currentState = state;
    if (currentState is! ReaderLoaded || currentState.pages.isEmpty) return '';
    final layout = currentState.layout;
    final first = layout.firstPage(
      layout.viewIndex(currentState.currentPageIndex),
    );
    final last = (first + (layout.isSpread ? 1 : 0)).clamp(
      0,
      currentState.pages.length - 1,
    );
    String range(int from, int to, int count) =>
        from == to ? '${from + 1}/$count' : '${from + 1}–${to + 1}/$count';
    final window = _bookWindow;
    if (window == null) {
      return '本章 ${range(first, last, currentState.pages.length)}';
    }
    final left = window.refs[first], right = window.refs[last];
    if (identical(left.owner, right.owner)) {
      return '本章 ${range(left.localIndex, right.localIndex, left.owner.pages.length)}';
    }
    return '${left.localIndex + 1}/${left.owner.pages.length} · '
        '${right.localIndex + 1}/${right.owner.pages.length}';
  }

  /// The full owning chapter, never the rolling EPUB preload window.
  ({int index, int count, Object revision}) get chapterProgress {
    final loaded = state;
    if (loaded is! ReaderLoaded || loaded.pages.isEmpty) {
      return (index: 0, count: 1, revision: this);
    }
    final ref = _bookWindow?.refs[loaded.currentPageIndex];
    return (
      index: ref?.localIndex ?? loaded.currentPageIndex,
      count: ref?.owner.pages.length ?? loaded.pages.length,
      revision: Object.hash(
        loaded.aid,
        loaded.cid,
        loaded.layout,
        ref?.owner.pages ?? loaded.pages,
      ),
    );
  }

  Future<void> seekChapterPage(int page) async {
    final intent = ++_seekGeneration, request = _request;
    final loaded = state;
    if (loaded is! ReaderLoaded) return;
    final window = _bookWindow, flow = _bookFlow;
    if (window == null || flow == null) {
      if (page < 0 || page >= loaded.pages.length) return;
      onPageChanged(loaded.layout.firstPage(loaded.layout.viewIndex(page)));
      return;
    }
    if (_reflowingBook) return;
    final ref = window.refs[loaded.currentPageIndex];
    if (page < 0 || page >= ref.owner.pages.length) return;
    final next = await flow.open(ref.owner.chapter.cid, initialPage: page);
    // A stale scrub must never put a reader back into the old chapter.
    if (isClosed ||
        !flow.current ||
        !identical(flow, _bookFlow) ||
        intent != _seekGeneration ||
        request != _request ||
        state is! ReaderLoaded) {
      return;
    }
    _publishBook(next, loaded.layout, loaded.fontFamily, state.showControls);
    _warmLocalBook();
  }

  void onPageChanged(int index) {
    _seekGeneration++;
    if (state is ReaderLoaded) {
      final currentState = state as ReaderLoaded;
      if (index < 0 || index >= currentState.pages.length) return;
      final window = _bookWindow;
      if (window != null) {
        _publishBook(
          EpubFlowWindow(window.refs, index, window.token, window.chapterCount),
          currentState.layout,
          currentState.fontFamily,
          currentState.showControls,
        );
        _warmLocalBook();
        return;
      }
      _position = (_offsets ??= ReaderPageOffsets(currentState.pages)).at(
        index,
      );
      emit(currentState.copyWith(currentPageIndex: index));

      _savePageHistory(state as ReaderLoaded);
    }
  }

  ReaderMarkChapterText? markText(
    ReaderMarkChapter chapter,
    ReaderMarkAxis axis,
  ) {
    if (axis == ReaderMarkAxis.page) return null;
    final window = _bookWindow;
    if (window != null) {
      for (final ref in window.refs) {
        final owner = ref.owner;
        if (owner.chapter.aid == chapter.aid &&
            owner.chapter.cid == chapter.cid) {
          final data = owner.data;
          if (axis == ReaderMarkAxis.epubDom) {
            final text = ref.page.cssPage?.markText;
            return text == null ? null : (text: text, encoded: false);
          }
          return (
            text: readerMarkText(data.content, data.document),
            encoded: data.fontFamily != null,
          );
        }
      }
    }
    if (axis != ReaderMarkAxis.text) return null;
    final content = _loadedContent;
    if (chapter.aid != _contentAid ||
        chapter.cid != _contentCid ||
        content == null) {
      return null;
    }
    return (
      text: readerMarkText(content, _loadedDocument),
      encoded: _sourceFont != null,
    );
  }

  ReaderMarkLocation markLocation(ReaderLoaded loaded) {
    final index = loaded.currentPageIndex;
    final ref = _bookWindow?.refs[index];
    final page = loaded.pages[index];
    final chapter = (aid: loaded.aid, cid: page.chapterId ?? loaded.cid);
    final title = page.chapterTitle ?? loaded.title;
    if (page.cssPage case final css?) {
      return ReaderMarkLocation(
        chapter,
        title,
        ReaderMarkAxis.epubDom,
        css.domStart,
      );
    }
    if (page.markStart case final start?) {
      return ReaderMarkLocation(
        chapter,
        title,
        ReaderMarkAxis.text,
        start,
        imageIndex: page.isImage ? ref?.position.precedingImages ?? 0 : null,
      );
    }
    return ReaderMarkLocation(
      chapter,
      title,
      ReaderMarkAxis.page,
      ref?.localIndex ?? index,
    );
  }

  bool markOnPage(ReaderLoaded loaded, ReaderMarkLocation location) {
    final current = markLocation(loaded);
    if (current.chapter != location.chapter || current.axis != location.axis) {
      return false;
    }
    if (current.samePosition(location)) return true;
    final page = loaded.pages[loaded.currentPageIndex];
    final end = page.cssPage?.domEnd ?? page.markEnd;
    return end != null &&
        location.imageIndex == null &&
        current.imageIndex == null &&
        location.offset >= current.offset &&
        location.offset < end;
  }

  int? _markPageIndex(ReaderMark mark, List<ReaderPage> pages, String text) {
    final location = mark.location;
    if (location.axis == ReaderMarkAxis.page) {
      return location.offset < pages.length ? location.offset : null;
    }
    final offset = mark.offsetIn(text);
    if (offset == null) return null;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (location.axis == ReaderMarkAxis.epubDom) {
        final css = page.cssPage;
        if (css != null &&
            (css.domStart == offset ||
                css.domStart < offset && offset < css.domEnd)) {
          return i;
        }
      } else if (location.imageIndex != null) {
        if (page.isImage && page.markStart == offset) return i;
      } else if (!page.isImage &&
          page.markStart != null &&
          page.markEnd != null &&
          offset >= page.markStart! &&
          offset < page.markEnd!) {
        return i;
      }
    }
    return null;
  }

  Future<bool> openMark(ReaderMark mark) async {
    final chapter = mark.location.chapter;
    final before = state;
    final local = sourceOf(chapter.aid) == SourceId.localEpub;
    if (!local &&
        before is ReaderLoaded &&
        before.aid == chapter.aid &&
        before.cid == chapter.cid) {
      final text = markText(chapter, ReaderMarkAxis.text)?.text ?? '';
      final page = _markPageIndex(mark, before.pages, text);
      if (page == null) return false;
      onPageChanged(page);
      return true;
    }
    await loadChapter(aid: chapter.aid, cid: chapter.cid, readerMark: mark);
    final after = state;
    if (after is! ReaderLoaded ||
        after.aid != chapter.aid ||
        after.cid != chapter.cid) {
      return false;
    }
    if (local) return markLocation(after).axis == mark.location.axis;
    return _markPageIndex(
          mark,
          after.pages,
          markText(chapter, ReaderMarkAxis.text)?.text ?? '',
        ) !=
        null;
  }

  void _savePageHistory(ReaderLoaded currentState) {
    final ref = _bookWindow?.refs[currentState.currentPageIndex];
    final index = ref?.localIndex ?? currentState.currentPageIndex;
    final chapterPages = ref?.owner.pages ?? currentState.pages;
    final richPosition =
        _loadedDocument == null
            ? null
            : _position ??
                (_offsets ??= ReaderPageOffsets(chapterPages)).at(index);
    final characterCount =
        richPosition?.textOffset ??
        (_offsets ??= ReaderPageOffsets(chapterPages)).charactersThrough(index);
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
        position: richPosition,
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
    double lineHeight, {
    SourceChapter? chapter,
  }) {
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
      chapter == null ? _sourceFont : chapter.fontFamily,
    );
    final pages = ReaderPaginationCache.instance.paginate(
      sourceId: sourceOf(aid).name,
      bookId: aid,
      chapterId: cid,
      sessionGeneration: _contentSession ?? _session(aid),
      content: content,
      document: chapter == null ? _loadedDocument : chapter.document,
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

  Future<void> _loadLocalBook(
    String aid,
    String cid,
    int request, {
    int? initialPage,
    int? initialTextOffset,
    ReaderPosition? position,
    bool? preserveControls,
    bool showLoading = true,
  }) async {
    final controls = preserveControls ?? state.showControls;
    final session = _session(aid);
    bool current() =>
        !_closing &&
        !isClosed &&
        request == _request &&
        _session(aid) == session;
    final previousWindow = _bookWindow;
    final previousData = <String, SourceChapter>{
      if (!showLoading && previousWindow != null)
        for (final ref in previousWindow.refs)
          ref.owner.chapter.cid: ref.owner.data,
    };
    _bookFlow?.close();
    final oldCssReader = _cssReader;
    final useCss =
        Platform.isAndroid &&
        LocalEpubLibrary.instance.book(aid)?.hasPublication == true;
    final cssReader = useCss ? EpubCssReader() : null;
    _cssReader = cssReader;
    if (showLoading) _bookWindow = null;
    _reflowingBook = !showLoading;
    _warmingBook = false;
    _prefetch?.cancel();
    initialAid = aid;
    initialCid = cid;
    if (showLoading) emit(ReaderLoading(controls));
    ({List<ReaderPage> pages, ReaderViewportLayout layout, String fontFamily})?
    firstPagination;
    Future<Uint8List?>? cssFont;
    final flow = EpubBookFlow(
      maxPages: useCss ? 32 : 64,
      maxNeighbourChapters: useCss ? 1 : 2,
      deferAhead: useCss,
      pageStride: useCss && _localCssLayout().isSpread ? 2 : 1,
      chapters: [
        for (final v in initialVolumes)
          ...v.chapters.where((c) => c.aid == aid),
      ],
      isCurrent: current,
      read:
          (c) async =>
              previousData[c.cid] ??
              await _read(aid: aid, cid: c.cid, isCurrent: current),
      paginate: (c, data) async {
        if (cssReader != null) {
          final metrics = MediaQueryData.fromView(
            WidgetsBinding.instance.platformDispatcher.views.first,
          );
          final layout = _localCssLayout(metrics);
          final theme = readerTheme?.call() ?? ReaderTheme.defaultTheme();
          final dark =
              theme.themeMode == ReaderThemeMode.dark ||
              theme.themeMode == ReaderThemeMode.auto &&
                  metrics.platformBrightness == Brightness.dark;
          String color(Color c) =>
              '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
          final font = await (cssFont ??= fontSettingsCubit.readerBytes());
          if (!current()) throw StateError('阅读器已更新');
          final pages = await cssReader.paginate(
            book: aid,
            chapter: c.cid,
            content: data.content,
            userFont: font,
            options: {
              'width': layout.leafWidth,
              'height': layout.viewportSize.height,
              'pixelRatio': metrics.devicePixelRatio,
              'boldText': metrics.boldText,
              'left': layout.insets.left,
              'top': layout.insets.top + layout.headerHeight,
              'contentWidth': layout.contentWidth,
              'contentHeight': layout.contentHeight,
              'fontSize': layout.textScaler.scale(fontSizeCubit.state),
              'lineHeight': lineHeightCubit.state,
              'paragraphGap': paragraphSpacingCubit.state,
              'paper': color(
                dark ? theme.darkBackgroundColor : theme.lightBackgroundColor,
              ),
              'ink': color(dark ? theme.darkTextColor : theme.lightTextColor),
              'userFont': font != null,
              'fontKey': fontSettingsCubit.state.readerFamily,
            },
          );
          firstPagination ??= (
            pages: pages,
            layout: layout,
            fontFamily: fontSettingsCubit.state.readerFamily,
          );
          return pages;
        }
        final p = _paginateContent(
          aid,
          c.cid,
          c.title,
          data.content,
          fontSizeCubit.state,
          paragraphSpacingCubit.state,
          lineHeightCubit.state,
          chapter: data,
        );
        firstPagination ??= p;
        return p.pages;
      },
    );
    _bookFlow = flow;
    try {
      if (useCss && layoutReady != null) {
        await layoutReady;
        if (!current()) return;
      }
      if (position == null && initialTextOffset != null) {
        position =
            await _loadPosition?.call(aid, cid) ??
            ReaderPosition(initialTextOffset, 0, false);
      }
      if (!current()) return;
      var window = await flow.open(
        cid,
        position: position,
        initialPage: initialPage ?? 0,
      );
      if (!current() || !identical(_bookFlow, flow)) return;
      // The old paper remains interactive during font/viewport reflow. Resolve
      // the latest chapter-local anchor after asynchronous neighbour reads.
      // Reuse an already shaped page whenever it is inside this new window.
      while (!showLoading && current()) {
        final latest = state;
        if (latest is! ReaderLoaded || latest.aid != aid) return;
        final anchor = _position;
        final candidate =
            window.refs
                .where((r) => r.owner.chapter.cid == latest.cid)
                .firstOrNull;
        final localIndex =
            candidate == null ? null : anchor?.pageIn(candidate.owner.pages);
        final index =
            candidate == null || localIndex == null
                ? -1
                : window.refs.indexWhere(
                  (r) =>
                      r.owner.chapter.cid == latest.cid &&
                      r.localIndex == localIndex,
                );
        if (index >= 0) {
          window = EpubFlowWindow(
            window.refs,
            index,
            window.token,
            window.chapterCount,
          );
          position = anchor;
          break;
        }
        window = await flow.open(latest.cid, position: anchor);
        if (!current() || !identical(_bookFlow, flow)) return;
      }
      _contentSession = session;
      if (cssReader != null) {
        await EpubCssReader.warm(
          window.pages,
          firstPagination!.layout.firstPage(
            firstPagination!.layout.viewIndex(window.index),
          ),
          count: firstPagination!.layout.isSpread ? 2 : 1,
          strict: true,
        );
        if (!current()) return;
      }
      _reflowingBook = false;
      _publishBook(
        window,
        firstPagination!.layout,
        firstPagination!.fontFamily,
        !showLoading ? state.showControls : controls,
        position: position,
      );
      _warmLocalBook();
    } catch (error) {
      if (!current()) return;
      _reflowingBook = false;
      emit(ReaderError(error.toString(), cause: error));
    } finally {
      oldCssReader?.close();
      if (!identical(_cssReader, cssReader)) cssReader?.close();
    }
  }

  ReaderViewportLayout _localCssLayout([MediaQueryData? metrics]) {
    final view =
        metrics ??
        MediaQueryData.fromView(
          WidgetsBinding.instance.platformDispatcher.views.first,
        );
    return ReaderViewportLayout(
      size: view.size,
      systemPadding: view.padding,
      leftPadding: leftPaddingCubit.state,
      rightPadding: rightPaddingCubit.state,
      topBarHeight: topBarHeightCubit.state,
      bottomBarHeight: bottomBarHeightCubit.state,
      textScaler: view.textScaler,
      boldText: view.boldText,
    );
  }

  void _publishBook(
    EpubFlowWindow window,
    ReaderViewportLayout layout,
    String fontFamily,
    bool controls, {
    ReaderPosition? position,
  }) {
    _bookWindow = window;
    final ref = window.refs[window.index];
    final data = ref.owner.data;
    initialCid = ref.owner.chapter.cid;
    _contentCid = initialCid;
    _contentAid = initialAid;
    _loadedContent = data.content;
    _loadedDocument = data.document;
    _sourceFont = data.fontFamily;
    _offsets = ReaderPageOffsets(ref.owner.pages);
    _position = position ?? ref.position;
    emit(
      ReaderLoaded(
        aid: initialAid,
        cid: initialCid,
        title: ref.owner.chapter.title,
        volumes: initialVolumes,
        pages: window.pages,
        layout: layout,
        fontFamily: fontFamily,
        currentPageIndex: window.index,
        showControls: controls,
        presentationKey: window.token,
      ),
    );
    _savePageHistory(state as ReaderLoaded);
    if (_cssReader != null) {
      unawaited(EpubCssReader.warm(window.pages, window.index));
    }
  }

  void _warmLocalBook() {
    final flow = _bookFlow, window = _bookWindow;
    if (flow == null ||
        window == null ||
        _reflowingBook ||
        _warmingBook ||
        state is! ReaderLoaded) {
      return;
    }
    _warmingBook = true;
    () async {
      try {
        final extended = await flow.warm(window, window.index);
        if (extended == null || !flow.current || !identical(_bookFlow, flow)) {
          return;
        }
        final latestWindow = _bookWindow;
        final latest = state;
        if (latestWindow == null ||
            latest is! ReaderLoaded ||
            !identical(latestWindow.refs, window.refs)) {
          return;
        }
        final currentRef = latestWindow.refs[latest.currentPageIndex];
        final index = extended.refs.indexWhere(
          (r) =>
              r.owner.chapter.cid == currentRef.owner.chapter.cid &&
              r.localIndex == currentRef.localIndex,
        );
        if (index < 0) return;
        _publishBook(
          EpubFlowWindow(
            extended.refs,
            index,
            extended.token,
            extended.chapterCount,
          ),
          latest.layout,
          latest.fontFamily,
          latest.showControls,
          position: _position,
        );
      } catch (_) {
        // A damaged neighbour must not replace a readable local page. A user
        // boundary action can retry it; no automatic retry loop is started.
      } finally {
        if (identical(_bookFlow, flow)) _warmingBook = false;
      }
    }();
  }

  Future<void> turnBookBoundary(int direction) async {
    final flow = _bookFlow, window = _bookWindow;
    final loaded = state;
    if (flow == null ||
        window == null ||
        _reflowingBook ||
        loaded is! ReaderLoaded) {
      return;
    }
    try {
      final next = await flow.across(window, direction);
      if (next == null ||
          !flow.current ||
          !identical(_bookFlow, flow) ||
          !identical(_bookWindow?.refs, window.refs)) {
        return;
      }
      _publishBook(next, loaded.layout, loaded.fontFamily, loaded.showControls);
      _warmLocalBook();
    } catch (_) {
      // Retain the current page. The same gesture retries a failed local read.
    }
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
    _readRequest?.cancel();
    _bookFlow?.close();
    _cssReader?.close();
    _prefetch?.cancel();
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
  final Object? presentationKey;
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
    this.presentationKey,
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
      presentationKey: presentationKey,
    );
  }
}
