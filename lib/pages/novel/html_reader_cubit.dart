import 'dart:async';
import 'package:wild/services/read_request.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/services/reader_mark_text.dart';
import 'package:wild/services/reader_chapter_prefetch.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../src/rust/wenku8/models.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/sources/book_source.dart';
import 'package:wild/services/reading_progress.dart';

// 状态基类
abstract class HtmlReaderState extends Equatable {
  const HtmlReaderState();

  @override
  List<Object?> get props => [];
}

// 加载中状态
class HtmlReaderLoading extends HtmlReaderState {
  const HtmlReaderLoading();
}

// 错误状态
class HtmlReaderError extends HtmlReaderState {
  final String error;
  final Object? cause;

  const HtmlReaderError(this.error, {this.cause});

  @override
  List<Object?> get props => [error, cause];
}

// 解析后的内容类型
abstract class ParsedContent extends Equatable {
  const ParsedContent({this.offset = 0});
  final int offset;
}

class ParsedText extends ParsedContent {
  final String text;

  const ParsedText(this.text, {super.offset});

  @override
  List<Object?> get props => [text, offset];
}

class ParsedImage extends ParsedContent {
  final String imageUrl;

  const ParsedImage(this.imageUrl, {super.offset});

  @override
  List<Object?> get props => [imageUrl, offset];
}

class ParsedStyledText extends ParsedContent {
  const ParsedStyledText(
    this.block, {
    this.previousStyle,
    this.endOfTextRun = false,
    super.offset,
  });
  final ReaderBlock block;
  final ReaderBlockStyle? previousStyle;
  final bool endOfTextRun;
  @override
  List<Object?> get props => [block, previousStyle, endOfTextRun, offset];
}

// 加载完成状态
class HtmlReaderLoaded extends HtmlReaderState {
  final String aid;
  final String cid;
  final String title;
  final String rawContent;
  final List<ParsedContent> parsedContent;
  final List<Volume> volumes;
  final String? sourceFont;
  final String? markContent;
  final int initialOffset;

  const HtmlReaderLoaded({
    required this.aid,
    required this.cid,
    required this.title,
    required this.rawContent,
    required this.parsedContent,
    required this.volumes,
    this.sourceFont,
    this.markContent,
    this.initialOffset = 0,
  });

  HtmlReaderLoaded copyWith({
    String? aid,
    String? cid,
    String? title,
    String? rawContent,
    List<ParsedContent>? parsedContent,
    List<Volume>? volumes,
  }) {
    return HtmlReaderLoaded(
      aid: aid ?? this.aid,
      cid: cid ?? this.cid,
      title: title ?? this.title,
      rawContent: rawContent ?? this.rawContent,
      parsedContent: parsedContent ?? this.parsedContent,
      volumes: volumes ?? this.volumes,
      sourceFont: sourceFont,
      markContent: markContent,
      initialOffset: initialOffset,
    );
  }

  @override
  List<Object?> get props => [
    aid,
    cid,
    title,
    rawContent,
    parsedContent,
    volumes,
    sourceFont,
    markContent,
    initialOffset,
  ];
}

class HtmlReaderCubit extends Cubit<HtmlReaderState> {
  int _request = 0;
  ReadRequest? _readRequest;
  bool _closing = false;
  Future<bool>? _initialRouteArrival;
  final Future<SourceChapter> Function({
    required String aid,
    required String cid,
    required bool Function() isCurrent,
  })
  _read;
  final int Function(String aid) _session;
  final ReadingProgressQueue _progress;
  final ReaderChapterPrefetch? _prefetch;
  final NovelInfo novelInfo;
  final String initialAid;
  final String initialCid;
  final List<Volume> initialVolumes;
  int? _initialTextOffset;
  int? _contentSession;
  int? _contentSourceRevision;
  int _lastSavedOffset = 0;
  (String, String)? _requestedChapter;

  HtmlReaderCubit({
    required this.novelInfo,
    required this.initialAid,
    required this.initialCid,
    required this.initialVolumes,
    int? initialTextOffset,
    Future<bool>? initialRouteArrival,
    Future<SourceChapter> Function({required String aid, required String cid})?
    read,
    int Function(String aid)? sessionGeneration,
    ReadingProgressQueue? progress,
    ReaderPrefetchLoad? prefetch,
  }) : _initialRouteArrival = initialRouteArrival,
       _initialTextOffset = initialTextOffset,
       _read =
           read == null
               ? w8.readerChapter
               : (({
                 required String aid,
                 required String cid,
                 required bool Function() isCurrent,
               }) => read(aid: aid, cid: cid)),
       _session = sessionGeneration ?? w8.readerSessionGeneration,
       _progress = progress ?? ReadingProgressQueue.instance,
       _prefetch =
           read != null && prefetch == null
               ? null
               : ReaderChapterPrefetch(prefetch ?? w8.prefetchReaderChapter),
       super(const HtmlReaderLoading());

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

  void _updateHistory(
    String aid,
    String cid,
    String title,
    int session,
    int offset,
  ) {
    final volume = _findVolume(aid, cid);
    final sessionFor = _session;
    final source = sourceOf(aid);
    final revision = sourceRevision.value;
    _progress.enqueue(
      ReadingProgress(
        bookId: aid,
        title: novelInfo.title,
        volumeId: volume.id,
        volumeTitle: volume.title,
        chapterId: cid,
        chapterTitle: title,
        characters: offset,
        page: scrollReaderProgressPage,
        cover: novelInfo.imgUrl,
        author: novelInfo.author,
      ),
      isValid:
          () =>
              sessionFor(aid) == session &&
              (source != SourceId.bili ||
                  (activeSource.value == source &&
                      sourceRevision.value == revision)),
    );
  }

  void recordVisibleOffset(String aid, String cid, int offset) {
    final current = state;
    final session = _contentSession;
    if (_closing ||
        current is! HtmlReaderLoaded ||
        current.aid != aid ||
        current.cid != cid ||
        session == null ||
        _session(aid) != session ||
        (sourceOf(aid) == SourceId.bili &&
            (activeSource.value != SourceId.bili ||
                sourceRevision.value != _contentSourceRevision)) ||
        offset < 0 ||
        offset == _lastSavedOffset) {
      return;
    }
    _lastSavedOffset = offset;
    _updateHistory(aid, cid, current.title, session, offset);
  }

  Future<void> retryChapter() =>
      loadChapter(aid: _requestedChapter?.$1, cid: _requestedChapter?.$2);

  List<ParsedContent> _parseContent(
    String content, {
    ReaderDocument? document,
  }) {
    if (document != null) {
      final result = <ParsedContent>[];
      ReaderBlockStyle? previous;
      final visible = <(ReaderBlock, int)>[];
      var offset = 0;
      for (final block in document.blocks) {
        if (block.imageUrl != null || block.text.isNotEmpty) {
          visible.add((block, offset));
        }
        if (block.imageUrl != null || block.artworkUrl != null) {
          offset += block.plainText.length + 1;
        } else if (block.text.isNotEmpty) {
          offset += block.text.length + 1;
        }
      }
      for (var index = 0; index < visible.length; index++) {
        final (block, offset) = visible[index];
        if (block.imageUrl != null || block.artworkUrl != null) {
          result.add(
            ParsedImage(block.artworkUrl ?? block.imageUrl!, offset: offset),
          );
          previous = null;
        } else if (block.text.isNotEmpty) {
          result.add(
            ParsedStyledText(
              block,
              previousStyle: previous,
              endOfTextRun:
                  index == visible.length - 1 ||
                  visible[index + 1].$1.imageUrl != null,
              offset: offset,
            ),
          );
          previous = block.style;
        }
      }
      return result;
    }
    final parsedContent = <ParsedContent>[];
    for (final part in readerPlainParts(content)) {
      if (part.image) {
        parsedContent.add(ParsedImage(part.text, offset: part.offset));
      } else if (part.text.trim().isNotEmpty) {
        final text = part.mixed ? part.text.trim() : part.text;
        parsedContent.add(
          ParsedText(
            text,
            offset: part.offset + (part.mixed ? part.text.indexOf(text) : 0),
          ),
        );
      }
    }

    return parsedContent;
  }

  Future<void> loadChapter({String? aid, String? cid}) async {
    if (_closing || isClosed) return;
    final request = ++_request;
    _readRequest?.cancel();
    final readRequest = _readRequest = ReadRequest();
    final targetAid = aid ?? initialAid;
    final targetCid = cid ?? initialCid;
    _requestedChapter = (targetAid, targetCid);
    _prefetch?.foreground(targetAid, targetCid);
    final session = _session(targetAid);
    final revision = sourceRevision.value;
    bool current() {
      if (_closing || isClosed || request != _request) return false;
      if (sourceOf(targetAid) == SourceId.bili &&
          (activeSource.value != SourceId.bili ||
              sourceRevision.value != revision)) {
        return false;
      }
      if (_session(targetAid) != session) {
        emit(const HtmlReaderError('账号已变化，请重新打开章节。'));
        return false;
      }
      return true;
    }

    try {
      unawaited(_progress.flushBounded());
      emit(const HtmlReaderLoading());

      // 查找章节信息
      String? chapterTitle;
      for (var volume in initialVolumes) {
        for (var chapter in volume.chapters) {
          if (chapter.aid == targetAid && chapter.cid == targetCid) {
            chapterTitle = chapter.title;
            break;
          }
        }
        if (chapterTitle != null) break;
      }

      if (chapterTitle == null) {
        emit(const HtmlReaderError('章节不存在'));
        return;
      }

      // 加载章节内容
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
                    _session(targetAid) == session &&
                    (sourceOf(targetAid) != SourceId.bili ||
                        (activeSource.value == SourceId.bili &&
                            sourceRevision.value == revision)),
          ),
        ),
      );
      if (!current()) return;
      if (_initialRouteArrival case final arrival?) {
        if (!await readRequest.wait(arrival)) return;
        _initialRouteArrival = null;
        if (!current()) return;
      }
      final rawContent = chapter.content;
      final parsedContent = _parseContent(
        rawContent,
        document: chapter.document,
      );
      final markContent =
          chapter.document == null
              ? null
              : readerMarkText(rawContent, chapter.document);
      final saved =
          targetAid == initialAid && targetCid == initialCid
              ? _initialTextOffset ?? 0
              : 0;
      final offset = saved.clamp(0, (markContent ?? rawContent).length);

      // 更新阅读历史
      if (!current()) return;
      _initialTextOffset = null;
      _contentSession = session;
      _contentSourceRevision = revision;
      _lastSavedOffset = offset;
      _updateHistory(targetAid, targetCid, chapterTitle, session, offset);

      emit(
        HtmlReaderLoaded(
          aid: targetAid,
          cid: targetCid,
          title: chapterTitle,
          rawContent: rawContent,
          parsedContent: parsedContent,
          volumes: initialVolumes,
          sourceFont: chapter.fontFamily,
          markContent: markContent,
          initialOffset: offset,
        ),
      );
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
      if (!current()) return;
      emit(
        HtmlReaderError(
          sourceOf(targetAid) == SourceId.wenku8
              ? wenku8ReadErrorMessage(e)
              : e.toString(),
          cause: e,
        ),
      );
    }
  }

  Future<void> goToNextChapter() async {
    if (state is! HtmlReaderLoaded) return;
    final currentState = state as HtmlReaderLoaded;

    // 查找当前章节索引
    int currentVolumeIndex = -1;
    int currentChapterIndex = -1;
    for (var i = 0; i < currentState.volumes.length; i++) {
      final volume = currentState.volumes[i];
      for (var j = 0; j < volume.chapters.length; j++) {
        final chapter = volume.chapters[j];
        if (chapter.aid == currentState.aid &&
            chapter.cid == currentState.cid) {
          currentVolumeIndex = i;
          currentChapterIndex = j;
          break;
        }
      }
      if (currentVolumeIndex != -1) break;
    }

    if (currentVolumeIndex == -1 || currentChapterIndex == -1) return;

    // 尝试获取下一章
    String? nextAid;
    String? nextCid;
    if (currentChapterIndex <
        currentState.volumes[currentVolumeIndex].chapters.length - 1) {
      // 当前卷的下一章
      final nextChapter =
          currentState
              .volumes[currentVolumeIndex]
              .chapters[currentChapterIndex + 1];
      nextAid = nextChapter.aid;
      nextCid = nextChapter.cid;
    } else if (currentVolumeIndex < currentState.volumes.length - 1) {
      // 下一卷的第一章
      final nextChapter =
          currentState.volumes[currentVolumeIndex + 1].chapters[0];
      nextAid = nextChapter.aid;
      nextCid = nextChapter.cid;
    }

    if (nextAid != null && nextCid != null) {
      await loadChapter(aid: nextAid, cid: nextCid);
    }
  }

  Future<void> goToPreviousChapter() async {
    if (state is! HtmlReaderLoaded) return;
    final currentState = state as HtmlReaderLoaded;

    // 查找当前章节索引
    int currentVolumeIndex = -1;
    int currentChapterIndex = -1;
    for (var i = 0; i < currentState.volumes.length; i++) {
      final volume = currentState.volumes[i];
      for (var j = 0; j < volume.chapters.length; j++) {
        final chapter = volume.chapters[j];
        if (chapter.aid == currentState.aid &&
            chapter.cid == currentState.cid) {
          currentVolumeIndex = i;
          currentChapterIndex = j;
          break;
        }
      }
      if (currentVolumeIndex != -1) break;
    }

    if (currentVolumeIndex == -1 || currentChapterIndex == -1) return;

    // 尝试获取上一章
    String? prevAid;
    String? prevCid;
    if (currentChapterIndex > 0) {
      // 当前卷的上一章
      final prevChapter =
          currentState
              .volumes[currentVolumeIndex]
              .chapters[currentChapterIndex - 1];
      prevAid = prevChapter.aid;
      prevCid = prevChapter.cid;
    } else if (currentVolumeIndex > 0) {
      // 上一卷的最后一章
      final prevVolume = currentState.volumes[currentVolumeIndex - 1];
      final prevChapter = prevVolume.chapters[prevVolume.chapters.length - 1];
      prevAid = prevChapter.aid;
      prevCid = prevChapter.cid;
    }

    if (prevAid != null && prevCid != null) {
      await loadChapter(aid: prevAid, cid: prevCid);
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    _readRequest?.cancel();
    _prefetch?.cancel();
    _request++;
    await super.close();
    await _progress.flushBounded();
  }
}
