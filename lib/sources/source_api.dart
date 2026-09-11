import 'dart:convert';
import 'package:wild/src/rust/api/wenku8.dart' as w8;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/src/rust/api/database.dart' as db;
import 'book_source.dart';
import 'light_novel_shelf_source.dart';
import 'shelf_session.dart';

export 'package:wild/src/rust/api/wenku8.dart'
    hide
        index,
        search,
        searchHistories,
        novelInfo,
        novelReader,
        chapterContent,
        bookcaseList,
        bookInCase,
        addBookshelf,
        deleteBookcase,
        moveBookcase,
        listReadingHistory,
        deleteAllHistory,
        allDownloads;

class Wenku8Source implements BookSource {
  @override
  SourceId get id => SourceId.wenku8;
  @override
  Future<List<HomeBlock>> discover() => w8.index();
  @override
  Future<w8.PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) => w8.search(searchType: type, searchKey: keyword, page: page);
  @override
  Future<SourceBookDetail> detail(String bookId) async => SourceBookDetail(
    await w8.novelInfo(aid: bookId),
    await w8.novelReader(aid: bookId),
  );
  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async =>
      SourceChapter(await w8.chapterContent(aid: bookId, cid: chapterId));
}

final shelfSource = LightNovelShelfSource();
final Map<SourceId, BookSource> bookSources = {
  SourceId.wenku8: Wenku8Source(),
  SourceId.lightNovelShelf: shelfSource,
};
final _detailCache = <String, SourceBookDetail>{};
final _chapterFonts = <String, String?>{};
final _shelfCovers = <String, String>{};
String coverForBook(String aid) =>
    _detailCache[aid]?.info.imgUrl ?? _shelfCovers[aid] ?? '';
String? chapterFont(String aid, String cid) => _chapterFonts['$aid/$cid'];
Future<void> _writes = Future.value();

Future<void> loadSourceSelection() async {
  final saved = await db.loadProperty(key: 'litetale.active_source');
  activeSource.value =
      saved == 'lightNovelShelf' ? SourceId.lightNovelShelf : SourceId.wenku8;
  try {
    await ShelfSession.instance.load();
  } catch (_) {
    /* Guest mode still works. */
  }
}

Future<void> selectSource(SourceId source) async {
  activeSource.value = source;
  await _serial(
    () => db.saveProperty(key: 'litetale.active_source', value: source.name),
  );
}

void clearShelfSessionCache() {
  _detailCache.removeWhere((k, _) => sourceOf(k) == SourceId.lightNovelShelf);
  shelfSource.clearSessionCache();
}

Future<List<HomeBlock>> index() => bookSources[activeSource.value]!.discover();
Future<NovelInfo> novelInfo({required String aid}) async {
  final detail = await bookSources[sourceOf(aid)]!.detail(aid);
  _detailCache[aid] = detail;
  return detail.info;
}

Future<List<Volume>> novelReader({required String aid}) async =>
    (_detailCache[aid] ?? await bookSources[sourceOf(aid)]!.detail(aid))
        .volumes;
Future<String> chapterContent({
  required String aid,
  required String cid,
}) async {
  final chapter = await bookSources[sourceOf(aid)]!.chapter(aid, cid);
  _chapterFonts['$aid/$cid'] = chapter.fontFamily;
  return chapter.content;
}

Future<w8.PageStatsNovelCover> search({
  required String searchType,
  required String searchKey,
  required int page,
}) async {
  final source = activeSource.value;
  if (source == SourceId.lightNovelShelf && page == 1) {
    await _serial(() async {
      final history = await _jsonList('litetale.lns.search_history');
      history.removeWhere(
        (h) => h['key'] == searchKey && h['type'] == searchType,
      );
      history.insert(0, {
        'key': searchKey,
        'type': searchType,
        'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      await db.saveProperty(
        key: 'litetale.lns.search_history',
        value: jsonEncode(history.take(100).toList()),
      );
    });
  }
  return bookSources[source]!.search(searchKey, searchType, page);
}

Future<List<w8.SearchHistory>> searchHistories() async {
  if (activeSource.value == SourceId.wenku8) return w8.searchHistories();
  return (await _jsonList('litetale.lns.search_history'))
      .map(
        (h) => w8.SearchHistory(
          searchType: h['type'] as String,
          searchKey: h['key'] as String,
          searchTime: h['time'] as int,
        ),
      )
      .toList();
}

Future<List<w8.ReadingHistory>> listReadingHistory({
  required int offset,
  required int limit,
}) async {
  final source = activeSource.value;
  final selected = <w8.ReadingHistory>[];
  for (var start = 0; selected.length < offset + limit; start += 100) {
    final chunk = await w8.listReadingHistory(offset: start, limit: 100);
    selected.addAll(chunk.where((h) => sourceOf(h.novelId) == source));
    if (chunk.length < 100) break;
  }
  return selected.skip(offset).take(limit).toList();
}

Future<void> deleteAllHistory() async {
  final entries = await listReadingHistory(offset: 0, limit: 1000000);
  // Only the selected source's records are affected.
  for (final entry in entries) {
    await w8.deleteHistoryByNovelId(novelId: entry.novelId);
  }
}

Future<List<w8.NovelDownload>> allDownloads() async =>
    (await w8.allDownloads())
        .where((b) => sourceOf(b.novelId) == activeSource.value)
        .toList();

Future<List<Map<String, dynamic>>> _jsonList(String key) async {
  final raw = await db.loadProperty(key: key);
  if (raw.isEmpty) return [];
  return (jsonDecode(raw) as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}

Future<void> _serial(Future<void> Function() work) {
  final next = _writes.then((_) => work());
  _writes = next.catchError((Object _) {});
  return next;
}

const _shelfKey = 'litetale.lns.local_shelf';
Future<List<Bookcase>> bookcaseList() async =>
    activeSource.value == SourceId.wenku8
        ? w8.bookcaseList()
        : [const Bookcase(id: 'lns:local', title: '轻书架收藏')];
Future<BookcaseDto> bookInCase({required String caseId}) async {
  if (caseId != 'lns:local') return w8.bookInCase(caseId: caseId);
  final entries = await _jsonList(_shelfKey);
  for (final book in entries) {
    _shelfCovers[book['id'] as String] = book['cover'] as String? ?? '';
  }
  return BookcaseDto(
    tip: '收藏保存在本机，阅读记录独立保存',
    items:
        entries
            .map(
              (b) => BookcaseItem(
                aid: b['id'],
                bid: b['id'],
                title: b['title'],
                author: b['author'],
                cid: b['cid'],
                chapterName: b['chapter'],
              ),
            )
            .toList(),
  );
}

Future<void> addBookshelf({required String aid}) async {
  if (sourceOf(aid) == SourceId.wenku8) return w8.addBookshelf(aid: aid);
  final detail = _detailCache[aid] ?? await shelfSource.detail(aid);
  await _serial(() async {
    final items = await _jsonList(_shelfKey);
    if (items.any((b) => b['id'] == aid)) return;
    final chapters = detail.volumes.expand((v) => v.chapters);
    items.add({
      'id': aid,
      'cover': detail.info.imgUrl,
      'title': detail.info.title,
      'author': detail.info.author,
      'cid': chapters.isEmpty ? '' : chapters.first.cid,
      'chapter': chapters.isEmpty ? '' : chapters.first.title,
    });
    await db.saveProperty(key: _shelfKey, value: jsonEncode(items));
  });
}

Future<void> deleteBookcase({required String bid}) async {
  if (sourceOf(bid) == SourceId.wenku8) return w8.deleteBookcase(bid: bid);
  await _serial(() async {
    final items = await _jsonList(_shelfKey);
    items.removeWhere((b) => b['id'] == bid);
    await db.saveProperty(key: _shelfKey, value: jsonEncode(items));
  });
}

Future<void> moveBookcase({
  required List<String> bidList,
  required String fromBookcaseId,
  required String toBookcaseId,
}) async {
  if (fromBookcaseId.startsWith('lns:') || toBookcaseId.startsWith('lns:')) {
    if (fromBookcaseId == toBookcaseId) return;
    throw StateError('不同书源的收藏不能相互移动');
  }
  await w8.moveBookcase(
    bidList: bidList,
    fromBookcaseId: fromBookcaseId,
    toBookcaseId: toBookcaseId,
  );
}
