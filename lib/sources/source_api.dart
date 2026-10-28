import 'dart:convert';
import 'dart:typed_data';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/utils/wenku8_query.dart';
import 'package:wild/src/rust/api/wenku8.dart' as w8;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/src/rust/api/database.dart' as db;
import 'book_source.dart';
import 'light_novel_shelf_source.dart';
import 'shelf_session.dart';
import 'lnovel_source.dart';
import 'bili_site_source.dart';
import 'package:wild/services/bili_browser.dart';
import 'rule_source_registry.dart';
import 'rule_book_source.dart';
import 'local_epub_source.dart';
import 'huanmeng_source.dart';
import 'esj_source.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:wild/services/huanmeng_http_transport.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/services/wenku8_read_repository.dart';
import 'package:wild/services/reader_pagination_cache.dart';
import 'package:wild/services/epub_reader_position.dart';
import 'package:wild/services/bounded_detail_cache.dart';
import 'package:wild/services/read_diagnostics.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/read_result_cache.dart';

export 'package:wild/src/rust/api/wenku8.dart'
    hide
        index,
        search,
        searchHistories,
        novelInfo,
        novelReader,
        chapterContent,
        cleanAllWebCache,
        bookcaseList,
        bookInCase,
        addBookshelf,
        deleteBookcase,
        moveBookcase,
        listReadingHistory,
        novelHistoryById,
        deleteAllHistory,
        allDownloads,
        tags,
        tagPage,
        toplist,
        articlelist,
        downloadCheckcode,
        wenku8Login,
        preLoginState,
        logout;

final _wenkuBrowser = Wenku8BrowserSession.instance;
int _wenkuSessionGeneration = 0;

void invalidateWenku8ReadingCache() {
  _wenkuSessionGeneration++;
  _wenkuBrowser.invalidateBookshelfSnapshot();
  final source = bookSources[SourceId.wenku8];
  if (source is Wenku8Source) source._reads.clear();
  _detailCache.removeWhere((key, _) => sourceOf(key.$1) == SourceId.wenku8);
}

Future<void> cleanAllWebCache() async {
  invalidateWenku8ReadingCache();
  await w8.cleanAllWebCache();
}

/// Account identity for an opened book; changing discovery alone is unrelated.
int readerSessionGeneration(String aid) =>
    sourceOf(aid) == SourceId.localEpub
        ? LocalEpubLibrary.instance.revisionFor(aid)
        : sourceOf(aid) == SourceId.lightNovelShelf
        ? ShelfSession.instance.generation
        : sourceOf(aid) == SourceId.wenku8
        ? _wenkuSessionGeneration + _wenkuBrowser.readingSessionRevision
        : sourceOf(aid) == SourceId.bili
        ? sourceRevision.value
        : sourceOf(aid).isRule
        ? RuleSourceRegistry.instance.revision(sourceOf(aid).ruleId)
        : 0;

Future<Uint8List> downloadCheckcode() =>
    _wenkuBrowser.downloadCheckcode(w8.downloadCheckcode);

Future<void> wenku8Login({
  required String username,
  required String password,
  required String checkcode,
}) async {
  invalidateWenku8ReadingCache();
  await _wenkuBrowser.submitLogin(
    username: username,
    password: password,
    checkcode: checkcode,
    nativeRequest:
        () => w8.wenku8Login(
          username: username,
          password: password,
          checkcode: checkcode,
        ),
  );
}

Future<bool> preLoginState() async =>
    await _wenkuBrowser.enabled()
        ? _wenkuBrowser.hasSavedLogin()
        : w8.preLoginState();

Future<void> logout() async {
  invalidateWenku8ReadingCache();
  await _wenkuBrowser.signOut();
  await w8.logout();
}

Future<T> _wenkuRead<T>(
  String kind,
  String path, {
  Map<String, String> query = const {},
  String? aid,
}) async {
  final host = await _wenkuBrowser.apiHost();
  return _wenkuBrowser.read<T>(
    kind,
    Uri.parse(
      '$host$path',
    ).replace(queryParameters: query.isEmpty ? null : query),
    aid: aid,
  );
}

void _wenkuId(String id) {
  if (!RegExp(r'^[1-9][0-9]{0,11}$').hasMatch(id)) {
    throw const FormatException('文库8书籍或章节编号无效。');
  }
}

Future<List<TagGroup>> tags() => _wenkuBrowser.nativeOrBrowser(
  w8.tags,
  () => _wenkuRead(
    'tags',
    '/modules/article/tags.php',
    query: {'charset': 'gbk'},
  ),
);

Future<w8.PageStatsNovelCover> _wenkuEncodedList(
  String path,
  String encodedQuery, {
  String? searchKey,
}) async {
  final host = await _wenkuBrowser.apiHost();
  return _wenkuBrowser.read(
    'list',
    Uri.parse('$host$path?$encodedQuery'),
    searchKey: searchKey,
  );
}

Future<w8.PageStatsNovelCover> tagPage({
  required String tag,
  required String v,
  required int pageNumber,
}) => _wenkuBrowser.nativeOrBrowser(
  () => w8.tagPage(tag: tag, v: v, pageNumber: pageNumber),
  () async => _wenkuEncodedList(
    '/modules/article/tags.php',
    't=${await wenku8EncodeQuery(tag)}&v=${Uri.encodeComponent(v)}&page=$pageNumber&charset=gbk',
  ),
);

Future<w8.PageStatsNovelCover> toplist({
  required String sort,
  required int page,
}) => _wenkuBrowser.nativeOrBrowser(
  () => w8.toplist(sort: sort, page: page),
  () => _wenkuRead(
    'list',
    '/modules/article/toplist.php',
    query: {'sort': sort, 'page': '$page', 'charset': 'gbk'},
  ),
);

Future<w8.PageStatsNovelCover> articlelist({
  required int fullflag,
  required int page,
}) => _wenkuBrowser.nativeOrBrowser(
  () => w8.articlelist(fullflag: fullflag, page: page),
  () => _wenkuRead(
    'list',
    '/modules/article/articlelist.php',
    query: {'fullflag': '$fullflag', 'page': '$page', 'charset': 'gbk'},
  ),
);

class Wenku8Source implements BookSource {
  late final _reads = Wenku8ReadRepository(
    host: _wenkuBrowser.apiHost,
    session: () => readerSessionGeneration('1'),
    detail: _loadDetail,
    chapter: _loadChapter,
    prefetch: (book, chapter, isCurrent) async {
      // Native reads already have durable chapter storage. Speculation here is
      // limited to the cancellable browser transport, never a second native GET
      // that could hold the Rust per-chapter lock behind a long timeout.
      if (!isCurrent() || !await _wenkuBrowser.enabled()) return null;
      final host = await _wenkuBrowser.apiHost();
      final content = await _wenkuBrowser.prefetchChapter(
        Uri.parse('$host/novel/${int.parse(book) ~/ 1000}/$book/$chapter.htm'),
        aid: book,
        isCurrent: isCurrent,
      );
      return content == null ? null : SourceChapter(content);
    },
  );

  @override
  SourceId get id => SourceId.wenku8;
  @override
  Future<List<HomeBlock>> discover() =>
      _wenkuBrowser.nativeOrBrowser(w8.index, _wenkuBrowser.home);
  @override
  Future<w8.PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) => _wenkuBrowser.nativeOrBrowser(
    () => w8.search(searchType: type, searchKey: keyword, page: page),
    () async => _wenkuEncodedList(
      '/modules/article/search.php',
      'searchtype=${Uri.encodeComponent(type)}&searchkey=${await wenku8EncodeQuery(keyword)}&page=$page&charset=gbk',
      searchKey: keyword,
    ),
  );
  @override
  Future<SourceBookDetail> detail(String bookId) async {
    _wenkuId(bookId);
    return _reads.detail(bookId);
  }

  Future<SourceBookDetail> _loadDetail(String bookId) async {
    final info = await _wenkuBrowser.nativeOrBrowser(
      () => w8.novelInfo(aid: bookId),
      () => _wenkuRead<NovelInfo>('detail', '/book/$bookId.htm', aid: bookId),
    );
    final volumes = await _wenkuBrowser.nativeOrBrowser(
      () => w8.novelReader(aid: bookId),
      () => _wenkuRead<List<Volume>>(
        'reader',
        '/novel/${int.parse(bookId) ~/ 1000}/$bookId/index.htm',
        aid: bookId,
      ),
    );
    return SourceBookDetail(info, volumes);
  }

  @override
  Future<SourceChapter> chapter(
    String bookId,
    String chapterId, {
    bool Function()? isCurrent,
  }) async {
    _wenkuId(bookId);
    _wenkuId(chapterId);
    return _reads.chapter(bookId, chapterId, isCurrent: isCurrent);
  }

  Future<SourceChapter> _loadChapter(String bookId, String chapterId) async {
    return SourceChapter(
      await _wenkuBrowser.nativeOrBrowser(
        () => w8.chapterContent(aid: bookId, cid: chapterId),
        () => _wenkuRead<String>(
          'chapter',
          '/novel/${int.parse(bookId) ~/ 1000}/$bookId/$chapterId.htm',
          aid: bookId,
        ),
      ),
    );
  }
}

final shelfSource = LightNovelShelfSource();
final lnovelSource = LNovelSource();
final biliSource = BiliSiteSource(
  searcher: BiliBrowserSession.instance.search,
  chapterLoader: BiliBrowserSession.instance.chapter,
  documentLoader: BiliBrowserSession.instance.document,
  documentsLoader: BiliBrowserSession.instance.documents,
);
final huanmengSource = HuanmengSource(
  // The published 9.0 API is anonymous on both mobile platforms. The iOS
  // reader should not wait for an offstage WebKit renderer before every read.
  transport: HuanmengHttpTransport(
    userAgent:
        defaultTargetPlatform == TargetPlatform.iOS
            ? HuanmengHttpTransport.iosUserAgent
            : null,
  ),
);
final esjSource = EsjSource();
final Map<SourceId, BookSource> bookSources = {
  SourceId.wenku8: Wenku8Source(),
  SourceId.lightNovelShelf: shelfSource,
  SourceId.lnovel: lnovelSource,
  SourceId.bili: biliSource,
  SourceId.esj: esjSource,
  SourceId.localEpub: LocalEpubSource(),
  SourceId.huanmeng: huanmengSource,
};

BookSource sourceAdapter(SourceId source) =>
    bookSources[source] ?? (throw StateError('此书源已停用或移除。请在“书源与账号”中恢复或重新导入。'));
bool sourceUsesCatalogSearch(SourceId source) =>
    source == SourceId.lnovel ||
    (bookSources[source] is RuleBookSource &&
        !(bookSources[source] as RuleBookSource).hasSearch);
bool sourceSupportsAuthorSearch(SourceId source) =>
    source == SourceId.wenku8 ||
    source == SourceId.lightNovelShelf ||
    source == SourceId.esj;
List<SourceId> get availableSources =>
    SourceId.values
        // ESJ is retired from discovery choices. Keep its adapter and stable IDs
        // so this never deletes or rewrites an existing book or reading record.
        .where(
          (s) =>
              s != SourceId.localEpub &&
              s != SourceId.esj &&
              bookSources.containsKey(s),
        )
        .toList();
bool _ruleListenerAttached = false;
bool _wenkuInvalidationAttached = false;
Map<String, String> ruleImageHeaders(SourceId source) {
  if (source == SourceId.esj) {
    return const {'Referer': 'https://www.esjzone.cc/'};
  }
  if (source == SourceId.huanmeng) {
    return const {'Referer': 'https://www.huanmengacg.com/'};
  }
  final entry = RuleSourceRegistry.instance[source.ruleId];
  return entry == null
      ? const {}
      : {'Referer': '${entry.definition.baseUrl.origin}/'};
}

void _refreshRuleSources() {
  final registry = RuleSourceRegistry.instance;
  SourceId.registerRules(
    registry.entries.map(
      (entry) =>
          SourceId.rule(entry.definition.id, label: entry.definition.name),
    ),
  );
  bookSources.removeWhere((id, _) => id.isRule);
  for (final entry in registry.entries.where((e) => e.enabled)) {
    final adapter = RuleBookSource(entry.definition);
    bookSources[adapter.id] = adapter;
  }
  _detailCache.removeWhere((id, _) => sourceOf(id.$1).isRule);
  if (!bookSources.containsKey(activeSource.value)) {
    activeSource.value = SourceId.wenku8;
  }
  sourceRevision.value++;
}

final _detailCache = BoundedDetailCache<(String, int)>();
final _detailLoads = SharedReadPool<(String, int), SourceBookDetail>();
final _chapterLoads = SharedReadPool<(String, String, int), SourceChapter>();
final _chapterCache = ReadResultCache<(String, String, int), SourceChapter>(
  maxEntries: 4,
  maxWeight: 4 * 1024 * 1024,
  ttl: const Duration(minutes: 5),
  weightOf: (chapter) => chapter.content.length * 2 + 128,
  cacheable: (chapter) => chapter.content.trim().isNotEmpty,
);
final _chapterFonts = <String, String?>{};
final _shelfCovers = <String, String>{};
String coverForBook(String aid) =>
    _detailCache.peek((aid, readerSessionGeneration(aid)))?.info.imgUrl ??
    _shelfCovers[aid] ??
    '';
String? chapterFont(String aid, String cid) => _chapterFonts['$aid/$cid'];
Future<void> _writes = Future.value();

Future<void> loadSourceSelection() async {
  if (!_wenkuInvalidationAttached) {
    _wenkuInvalidationAttached = true;
    _wenkuBrowser.sessionInvalidations.listen(
      (_) => invalidateWenku8ReadingCache(),
    );
  }
  await RuleSourceRegistry.instance.load();
  if (!_ruleListenerAttached) {
    RuleSourceRegistry.instance.addListener(_refreshRuleSources);
    _ruleListenerAttached = true;
  }
  _refreshRuleSources();
  final saved = await db.loadProperty(key: 'litetale.active_source');
  activeSource.value = SourceId.values.firstWhere(
    (s) => s.name == saved && availableSources.contains(s),
    orElse: () => SourceId.wenku8,
  );
  try {
    await ShelfSession.instance.load();
  } catch (_) {
    /* Guest mode still works. */
  }
}

Future<void> selectSource(SourceId source) async {
  await _serial(() async {
    if (!availableSources.contains(source)) throw StateError('请选择在线书源');
    sourceAdapter(source);
    await db.saveProperty(key: 'litetale.active_source', value: source.name);
    activeSource.value = source;
  });
}

void clearShelfSessionCache() {
  _detailCache.removeWhere(
    (k, _) => sourceOf(k.$1) == SourceId.lightNovelShelf,
  );
  shelfSource.clearSessionCache();
}

Future<List<HomeBlock>> index() => sourceAdapter(activeSource.value).discover();

/// The caller owns this complete result, even if its directory exceeds cache
/// limits. Opening a detail still refreshes through the source's own policy.
Future<SourceBookDetail> loadBookDetail({
  required String aid,
  bool reuse = false,
}) {
  final generation = readerSessionGeneration(aid);
  final key = (aid, generation);
  ReadRequest.current?.check();
  final cached = reuse ? _detailCache[key] : null;
  if (cached != null) {
    ReadDiagnostics.record(
      sourceOf(aid).name,
      'detail_cache_hit',
      Duration.zero,
    );
    return Future.value(cached);
  }
  if (_detailLoads.contains(key)) {
    ReadDiagnostics.record(
      sourceOf(aid).name,
      'detail_shared_join',
      Duration.zero,
    );
  }
  return _detailLoads.run(key, () async {
    final detail = await ReadDiagnostics.measure(
      sourceOf(aid).name,
      'detail',
      () => sourceAdapter(sourceOf(aid)).detail(aid),
    );
    ReadRequest.current?.check();
    if (generation != readerSessionGeneration(aid)) {
      throw StateError('书源或账号已变化，请重试。');
    }
    _detailCache[key] = detail;
    return detail;
  });
}

Future<NovelInfo> novelInfo({required String aid}) async =>
    (await loadBookDetail(aid: aid)).info;

Future<List<Volume>> novelReader({required String aid}) async {
  final generation = readerSessionGeneration(aid);
  final detail =
      sourceOf(aid) == SourceId.wenku8
          ? await sourceAdapter(SourceId.wenku8).detail(aid)
          : await loadBookDetail(aid: aid, reuse: true);
  if (generation != readerSessionGeneration(aid)) {
    throw StateError('书源或账号已变化，请重试。');
  }
  return detail.volumes;
}

Future<String> chapterContent({
  required String aid,
  required String cid,
}) async {
  final chapter = await readerChapter(aid: aid, cid: cid);
  _chapterFonts['$aid/$cid'] = chapter.fontFamily;
  return chapter.content;
}

Future<SourceChapter> readerChapter({
  required String aid,
  required String cid,
  bool Function()? isCurrent,
}) async {
  final generation = readerSessionGeneration(aid);
  if (isCurrent?.call() == false) throw const Wenku8PrefetchDeferred();
  final adapter = sourceAdapter(sourceOf(aid));
  ReadRequest.current?.check();
  if (ReadDiagnostics.enabled &&
      sourceOf(aid) != SourceId.wenku8 &&
      sourceOf(aid) != SourceId.localEpub &&
      _chapterCache.peek((aid, cid, generation)) != null) {
    ReadDiagnostics.record(
      sourceOf(aid).name,
      'chapter_cache_hit',
      Duration.zero,
    );
  }
  final chapter =
      adapter is Wenku8Source
          ? await adapter.chapter(aid, cid, isCurrent: isCurrent)
          : sourceOf(aid) == SourceId.localEpub
          ? await adapter.chapter(aid, cid)
          : await _chapterLoads.run(
            (aid, cid, generation),
            () => _chapterCache.getOrLoad((aid, cid, generation), () async {
              final request = ReadRequest.current;
              final remove = request?.onCancel(
                (_) => _chapterCache.invalidate((aid, cid, generation)),
              );
              try {
                final value = await ReadDiagnostics.measure(
                  sourceOf(aid).name,
                  'chapter',
                  () => adapter.chapter(aid, cid),
                ).timeout(
                  const Duration(seconds: 45),
                  onTimeout: () {
                    final error = StateError('章节请求超时，请稍后重试');
                    request?.cancel(error);
                    throw error;
                  },
                );
                request?.check();
                if (generation != readerSessionGeneration(aid)) {
                  throw StateError('书源或账号已变化，请重试。');
                }
                return value;
              } finally {
                remove?.call();
              }
            }),
          );
  if (generation != readerSessionGeneration(aid)) {
    throw StateError('书源或账号已变化，请重试。');
  }
  return chapter;
}

Future<void> prefetchReaderChapter({
  required String aid,
  required String cid,
  required bool Function() isCurrent,
}) async {
  if (isCurrent() && sourceOf(aid) == SourceId.localEpub) {
    await LocalEpubLibrary.instance.chapter(aid, cid);
    return;
  }
  if (!isCurrent() ||
      sourceOf(aid) != SourceId.wenku8 ||
      activeSource.value != SourceId.wenku8) {
    return;
  }
  _wenkuId(aid);
  _wenkuId(cid);
  final source = sourceAdapter(SourceId.wenku8);
  if (source is Wenku8Source) {
    await source._reads.prefetch(aid, cid, isCurrent: isCurrent);
  }
}

Future<w8.PageStatsNovelCover> search({
  required String searchType,
  required String searchKey,
  required int page,
}) async {
  final source = activeSource.value;
  if (page == 1) {
    await ReadDiagnostics.measure(
      source.name,
      'search_history',
      () => _serial(() async {
        final history = await _jsonList(_searchKey(source));
        history.removeWhere(
          (h) => h['key'] == searchKey && h['type'] == searchType,
        );
        history.insert(0, {
          'key': searchKey,
          'type': searchType,
          'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        });
        await db.saveProperty(
          key: _searchKey(source),
          value: jsonEncode(history.take(100).toList()),
        );
      }),
    );
  }
  ReadRequest.current?.check();
  return ReadDiagnostics.measure(
    source.name,
    'search',
    () => sourceAdapter(source).search(
      searchKey,
      source == SourceId.huanmeng && searchType == 'articlename'
          ? 'title'
          : searchType,
      page,
    ),
  );
}

String _searchKey(SourceId source) =>
    'litetale.${source == SourceId.lightNovelShelf ? 'lns' : source.name}.search_history';
String _shelfKeyFor(SourceId source) =>
    'litetale.${source == SourceId.lightNovelShelf ? 'lns' : source.name}.local_shelf';
String _caseId(SourceId source) =>
    source == SourceId.lightNovelShelf ? 'lns:local' : '${source.name}:local';

Future<List<w8.SearchHistory>> searchHistories() async {
  final source = activeSource.value;
  final history =
      (await _jsonList(_searchKey(source)))
          .map(
            (h) => w8.SearchHistory(
              searchType: h['type'] as String,
              searchKey: h['key'] as String,
              searchTime: h['time'] as int,
            ),
          )
          .toList();
  if (source == SourceId.wenku8) {
    history.addAll(await w8.searchHistories());
    history.sort((a, b) => b.searchTime.compareTo(a.searchTime));
    final seen = <(String, String)>{};
    return history
        .where((h) => seen.add((h.searchType, h.searchKey)))
        .take(100)
        .toList();
  }
  return history;
}

Future<List<w8.ReadingHistory>> listReadingHistory({
  required int offset,
  required int limit,
  SourceId? source,
}) async {
  await ReadingProgressQueue.instance.flushBounded();
  final selectedSource = source ?? activeSource.value;
  final selected = <w8.ReadingHistory>[];
  for (var start = 0; selected.length < offset + limit; start += 100) {
    final chunk = await w8.listReadingHistory(offset: start, limit: 100);
    selected.addAll(
      chunk.where(
        (h) =>
            sourceOf(h.novelId) == selectedSource &&
            (selectedSource != SourceId.localEpub ||
                LocalEpubLibrary.instance.contains(h.novelId)),
      ),
    );
    if (chunk.length < 100) break;
  }
  return selected.skip(offset).take(limit).toList();
}

Future<w8.ReadingHistory?> novelHistoryById({required String novelId}) async {
  await ReadingProgressQueue.instance.flushBounded();
  return w8.novelHistoryById(novelId: novelId);
}

Future<void> deleteAllHistory({SourceId? source}) async {
  final entries = await listReadingHistory(
    offset: 0,
    limit: 1000000,
    source: source,
  );
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

Future<List<Bookcase>> bookcaseList() async =>
    activeSource.value == SourceId.wenku8
        ? _wenkuBrowser.nativeOrBrowser(
          w8.bookcaseList,
          _wenkuBrowser.bookcaseList,
        )
        : [
          Bookcase(
            id: _caseId(activeSource.value),
            title: '${activeSource.value.label}收藏',
          ),
        ];
Future<BookcaseDto> bookInCase({required String caseId}) async {
  final source =
      SourceId.values
          .where((s) => s != SourceId.wenku8 && _caseId(s) == caseId)
          .firstOrNull;
  if (source == null && caseId.startsWith('rule:')) {
    throw StateError('此书源已移除，请重新导入相同书源。');
  }
  if (source == null) {
    return _wenkuBrowser.nativeOrBrowser(
      () => w8.bookInCase(caseId: caseId),
      () => _wenkuBrowser.bookInCase(caseId),
    );
  }
  final entries = await _jsonList(_shelfKeyFor(source));
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
  if (sourceOf(aid) == SourceId.localEpub) return;
  if (sourceOf(aid) == SourceId.wenku8) return w8.addBookshelf(aid: aid);
  final source = sourceOf(aid);
  final shelfKey = _shelfKeyFor(source);
  final detail = await loadBookDetail(aid: aid, reuse: true);
  await _serial(() async {
    final items = await _jsonList(shelfKey);
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
    await db.saveProperty(key: shelfKey, value: jsonEncode(items));
  });
}

Future<void> deleteBookcase({required String bid}) async {
  if (sourceOf(bid) == SourceId.localEpub) return removeLocalEpub(bid);
  if (sourceOf(bid) == SourceId.wenku8) return w8.deleteBookcase(bid: bid);
  final shelfKey = _shelfKeyFor(sourceOf(bid));
  await _serial(() async {
    final items = await _jsonList(shelfKey);
    items.removeWhere((b) => b['id'] == bid);
    await db.saveProperty(key: shelfKey, value: jsonEncode(items));
  });
}

Future<void> moveBookcase({
  required List<String> bidList,
  required String fromBookcaseId,
  required String toBookcaseId,
}) async {
  if (fromBookcaseId.startsWith('rule:') ||
      toBookcaseId.startsWith('rule:') ||
      SourceId.values
          .where((s) => s != SourceId.wenku8)
          .any(
            (s) => _caseId(s) == fromBookcaseId || _caseId(s) == toBookcaseId,
          )) {
    if (fromBookcaseId == toBookcaseId) return;
    throw StateError('不同书源的收藏不能相互移动');
  }
  await w8.moveBookcase(
    bidList: bidList,
    fromBookcaseId: fromBookcaseId,
    toBookcaseId: toBookcaseId,
  );
}

Future<void> removeLocalEpub(String bookId) async {
  if (sourceOf(bookId) != SourceId.localEpub) throw ArgumentError('不是本地 EPUB');
  await LocalEpubLibrary.instance.remove(bookId);
  // Revision invalidation makes late reader positions obsolete. An already
  // active write must finish before history is removed, or it could reappear.
  await ReadingProgressQueue.instance.discard(bookId);
  try {
    await w8.deleteHistoryByNovelId(novelId: bookId);
    await EpubReaderPositionStore.instance.clear(bookId);
  } finally {
    _detailCache.removeWhere((key, _) => key.$1 == bookId);
    _chapterFonts.removeWhere((key, _) => key.startsWith('$bookId/'));
    _shelfCovers.remove(bookId);
    ReaderPaginationCache.instance.evictBook(bookId);
  }
}

void invalidateLocalEpubPresentation(String bookId) {
  if (sourceOf(bookId) != SourceId.localEpub) return;
  _detailCache.removeWhere((key, _) => key.$1 == bookId);
  _chapterFonts.removeWhere((key, _) => key.startsWith('$bookId/'));
  _shelfCovers.remove(bookId);
  ReaderPaginationCache.instance.evictBook(bookId);
}
