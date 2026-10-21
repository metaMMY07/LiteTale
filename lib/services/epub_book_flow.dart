import 'dart:async';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

typedef EpubPageBuilder =
    FutureOr<List<ReaderPage>> Function(Chapter chapter, SourceChapter data);

class EpubFlowChapter {
  const EpubFlowChapter(this.ordinal, this.chapter, this.data, this.pages);
  final int ordinal;
  final Chapter chapter;
  final SourceChapter data;
  final List<ReaderPage> pages;
}

class EpubFlowPage {
  EpubFlowPage(this.owner, this.localIndex) {
    final p = owner.pages[localIndex];
    page = ReaderPage(
      content: p.content,
      isImage: p.isImage,
      fragments: p.fragments,
      textStart: p.textStart,
      textEnd: p.textEnd,
      chapterId: owner.chapter.cid,
      chapterTitle: owner.chapter.title,
      artworkText: p.artworkText,
      cssPage: p.cssPage,
    );
  }
  final EpubFlowChapter owner;
  final int localIndex;
  late final ReaderPage page;
  ReaderPosition get position => ReaderPosition.at(owner.pages, localIndex);
}

class EpubFlowWindow {
  EpubFlowWindow(this.refs, this.index, this.token, this.chapterCount)
    : pages = List.unmodifiable(refs.map((r) => r.page));
  final List<EpubFlowPage> refs;
  final List<ReaderPage> pages;
  final int index, chapterCount;
  final Object token;
  bool get hasBefore =>
      refs.first.owner.ordinal > 0 || refs.first.localIndex > 0;
  bool get hasAfter =>
      refs.last.owner.ordinal < chapterCount - 1 ||
      refs.last.localIndex < refs.last.owner.pages.length - 1;
}

/// A rolling book window, not one giant concatenation/pagination of the EPUB.
/// Existing page indices remain stable when a prepared chapter is appended.
/// Recentring drops an even prefix, retaining spread parity and content anchors.
class EpubBookFlow {
  EpubBookFlow({
    required List<Chapter> chapters,
    required Future<SourceChapter> Function(Chapter) read,
    required EpubPageBuilder paginate,
    required bool Function() isCurrent,
    this.maxPages = 64,
    this.maxNeighbourChapters = 2,
    this.deferAhead = false,
    this.pageStride = 1,
  }) : chapters = List.unmodifiable(chapters),
       _read = read,
       _paginate = paginate,
       _isCurrent = isCurrent {
    if (maxPages < 16) {
      throw ArgumentError.value(maxPages, 'maxPages', '至少 16 页');
    }
    if (pageStride < 1 || pageStride > 2) {
      throw ArgumentError.value(pageStride, 'pageStride');
    }
  }

  final List<Chapter> chapters;
  final Future<SourceChapter> Function(Chapter) _read;
  final EpubPageBuilder _paginate;
  final bool Function() _isCurrent;
  final int maxPages;
  final int maxNeighbourChapters;
  final bool deferAhead;
  final int pageStride;
  final Map<int, EpubFlowChapter> _cache = {};
  final _loading = <int, Future<EpubFlowChapter>>{};
  bool _closed = false;
  bool get current => !_closed && _isCurrent();
  void close() {
    _closed = true;
    _cache.clear();
  }

  void _check() {
    if (!current) throw StateError('本地阅读已更新');
  }

  Future<EpubFlowChapter> _chapter(int ordinal) async {
    _check();
    final cached = _cache.remove(ordinal);
    if (cached != null) {
      _cache[ordinal] = cached;
      return cached;
    }
    final pending = _loading[ordinal];
    if (pending != null) return pending;
    late final Future<EpubFlowChapter> request;
    request = () async {
      final chapter = chapters[ordinal];
      final data = await _read(chapter);
      _check();
      final pages = await _paginate(chapter, data);
      _check();
      if (pages.isEmpty) throw StateError('本地章节没有可排版的页面');
      final result = EpubFlowChapter(ordinal, chapter, data, pages);
      _cache[ordinal] = result;
      while (_cache.length > 5 ||
          _cache.length > 1 &&
              _cache.values.fold<int>(0, (n, c) => n + c.data.content.length) >
                  1024 * 1024) {
        _cache.remove(_cache.keys.first);
      }
      return result;
    }().whenComplete(() {
      if (identical(_loading[ordinal], request)) _loading.remove(ordinal);
    });
    _loading[ordinal] = request;
    return request;
  }

  Future<EpubFlowPage?> _next(EpubFlowPage page) async {
    if (page.localIndex + 1 < page.owner.pages.length) {
      return EpubFlowPage(page.owner, page.localIndex + 1);
    }
    if (page.owner.ordinal + 1 >= chapters.length) return null;
    return EpubFlowPage(await _chapter(page.owner.ordinal + 1), 0);
  }

  Future<void> _fill(
    List<EpubFlowPage> refs, {
    int? visibleEnd,
    int? maxOrdinal,
  }) async {
    final firstOrdinal = refs.last.owner.ordinal;
    while (refs.length < maxPages) {
      // Opening a readable spread does not wait for a non-visible chapter.
      // warm() fills the remaining window after the first paper is published.
      if (visibleEnd != null &&
          refs.length >= visibleEnd &&
          refs.last.localIndex == refs.last.owner.pages.length - 1) {
        break;
      }
      // Limit new chapter I/O and shaping per warm operation, even when a book
      // has thousands of tiny XHTML sections. Later turns extend the window.
      if (refs.last.localIndex == refs.last.owner.pages.length - 1 &&
          refs.last.owner.ordinal >=
              (maxOrdinal ?? firstOrdinal + maxNeighbourChapters)) {
        break;
      }
      EpubFlowPage? next;
      try {
        next = await _next(refs.last);
      } catch (_) {
        _check();
        break;
      }
      _check();
      if (next == null) break;
      refs.add(next);
    }
  }

  Future<EpubFlowWindow> open(
    String cid, {
    ReaderPosition? position,
    int initialPage = 0,
  }) async {
    final ordinal = chapters.indexWhere((c) => c.cid == cid);
    if (ordinal < 0) throw StateError('本地章节不存在');
    final chapter = await _chapter(ordinal);
    final selected =
        position?.pageIn(chapter.pages) ??
        (initialPage < 0
            ? chapter.pages.length - 1
            : initialPage.clamp(0, chapter.pages.length - 1));
    var start = (selected - 8).clamp(0, chapter.pages.length - 1);
    start -= start % 2;
    final prefix = <EpubFlowPage>[];
    var prior = ordinal - 1;
    while (start == 0 &&
        prefix.length + selected < 8 &&
        prior >= 0 &&
        prior >= ordinal - maxNeighbourChapters) {
      EpubFlowChapter before;
      try {
        before = await _chapter(prior--);
      } catch (_) {
        _check();
        break;
      }
      final count = (8 - selected - prefix.length).clamp(
        0,
        before.pages.length,
      );
      prefix.insertAll(0, [
        for (var i = before.pages.length - count; i < before.pages.length; i++)
          EpubFlowPage(before, i),
      ]);
    }
    final refs = [...prefix, EpubFlowPage(chapter, start)];
    final index = prefix.length + selected - start;
    await _fill(
      refs,
      visibleEnd: deferAhead ? (index ~/ pageStride + 1) * pageStride : null,
    );
    return EpubFlowWindow(
      List.unmodifiable(refs),
      index,
      Object(),
      chapters.length,
    );
  }

  Future<EpubFlowWindow?> warm(EpubFlowWindow window, int index) async {
    _check();
    if (window.refs.length - index > 16 || !window.hasAfter) return null;
    var start =
        window.refs.length >= maxPages ? (index - 8).clamp(0, index) : 0;
    start -= start % 2;
    final refs = window.refs.skip(start).toList();
    final visibleEnd = ((index ~/ pageStride + 1) * pageStride - 1).clamp(
      0,
      window.refs.length - 1,
    );
    await _fill(
      refs,
      maxOrdinal:
          deferAhead
              ? window.refs[visibleEnd].owner.ordinal +
                  maxNeighbourChapters * pageStride
              : null,
    );
    if (start == 0 && refs.length == window.refs.length) return null;
    return EpubFlowWindow(
      List.unmodifiable(refs),
      index - start,
      start == 0 ? window.token : Object(),
      chapters.length,
    );
  }

  Future<EpubFlowWindow?> across(EpubFlowWindow window, int direction) async {
    _check();
    if (direction > 0) {
      final next = await _next(window.refs.last);
      if (next == null) return null;
      return open(next.owner.chapter.cid, initialPage: next.localIndex);
    }
    final first = window.refs.first;
    if (first.localIndex > 0) {
      return open(first.owner.chapter.cid, initialPage: first.localIndex - 1);
    }
    if (first.owner.ordinal <= 0) return null;
    return open(chapters[first.owner.ordinal - 1].cid, initialPage: -1);
  }
}
