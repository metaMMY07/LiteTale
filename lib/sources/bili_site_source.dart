import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

import 'book_source.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/read_diagnostics.dart';

const _siteOrigin = 'https://www.bilinovel.net';
const _pageSize = 30;
const _libraryPagePattern =
    r'^/wenku/lastupdate_0_0_0_0_0_0_0_([1-9]\d*)_0\.html$';

typedef BiliSiteSearcher =
    Future<PageStatsNovelCover> Function(String keyword, int page);
typedef BiliSiteChapterLoader =
    Future<SourceChapter> Function(String bookId, String chapterId);

class BiliSiteBudget {
  const BiliSiteBudget({
    this.requestTimeout = const Duration(seconds: 15),
    this.detailTimeout = const Duration(seconds: 20),
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.maxRedirects = 2,
    this.maxBooks = 100,
    this.maxVolumes = 80,
    this.maxChapters = 10000,
    this.maxPage = 100,
  });

  final Duration requestTimeout;
  final Duration detailTimeout;
  final int maxResponseBytes;
  final int maxRedirects;
  final int maxBooks;
  final int maxVolumes;
  final int maxChapters;
  final int maxPage;
}

class BiliSiteException implements Exception {
  const BiliSiteException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BiliSiteCategory {
  const BiliSiteCategory({
    required this.id,
    required this.name,
    required this.slug,
  });

  final int id;
  final String name;
  final String slug;
}

/// HTML adapter for the public bilibili light-novel site.
///
/// Search and chapter rendering are delegated to the caller's ordinary
/// browser session. This class never submits the site's form or reads browser
/// cookies. An injected HTTP client remains caller-owned; otherwise a fresh
/// client is closed after each public operation.
class BiliSiteSource implements BookSource {
  BiliSiteSource({
    required BiliSiteSearcher searcher,
    required BiliSiteChapterLoader chapterLoader,
    Future<String> Function(Uri uri)? documentLoader,
    Future<List<String>> Function(List<Uri> uris)? documentsLoader,
    http.Client? client,
    this.budget = const BiliSiteBudget(),
  }) : _searcher = searcher,
       _chapterLoader = chapterLoader,
       _documentLoader = documentLoader,
       _documentsLoader = documentsLoader,
       _injectedClient = client;

  final BiliSiteSearcher _searcher;
  final BiliSiteChapterLoader _chapterLoader;
  final Future<String> Function(Uri uri)? _documentLoader;
  final Future<List<String>> Function(List<Uri> uris)? _documentsLoader;
  final http.Client? _injectedClient;
  final BiliSiteBudget budget;

  static const List<BiliSiteCategory> _categories = [
    BiliSiteCategory(id: 1, name: '电击文库', slug: 'dengekibunko'),
    BiliSiteCategory(id: 2, name: '富士见文库', slug: 'fujimibunko'),
    BiliSiteCategory(id: 3, name: '角川文库', slug: 'kadokawabunko'),
    BiliSiteCategory(id: 4, name: 'MF文库J', slug: 'emuefubunkojei'),
    BiliSiteCategory(id: 5, name: 'Fami通文库', slug: 'famitsubunko'),
    BiliSiteCategory(id: 6, name: 'GA文库', slug: 'gagraphicbunko'),
    BiliSiteCategory(id: 7, name: 'HJ文库', slug: 'hobbyjapanbunko'),
    BiliSiteCategory(id: 8, name: '一迅社', slug: 'ichijinsha'),
    BiliSiteCategory(id: 9, name: '集英社', slug: 'shueisha'),
    BiliSiteCategory(id: 10, name: '小学馆', slug: 'shogakukan'),
    BiliSiteCategory(id: 11, name: '讲谈社', slug: 'kodansha'),
    BiliSiteCategory(id: 12, name: '少女文库', slug: 'teenagebunko'),
    BiliSiteCategory(id: 13, name: '其他文库', slug: 'other'),
    BiliSiteCategory(id: 14, name: '华文轻小说', slug: 'chineselightnovel'),
  ];

  static const List<String> _rankSlugs = [
    'monthvisit',
    'weekvisit',
    'monthvote',
    'weekvote',
    'monthflower',
    'weekflower',
    'monthegg',
    'weekegg',
    'lastupdate',
    'postdate',
    'goodnum',
    'newhot',
  ];

  @override
  SourceId get id => SourceId.bili;

  List<BiliSiteCategory> categories() => _categories;

  @override
  Future<List<HomeBlock>> discover() => _withSession((session) async {
    final document = await _getDocument(session, Uri.parse('$_siteOrigin/'));
    final records = _parseCards(
      document,
      bookCards: '.index_tpic_info, li.module-slide-li',
      titleSelector: 'a[href*="/novel/"]',
    );
    if (records.isEmpty) throw const FormatException('哔哩轻小说首页书目格式已变化');
    return [HomeBlock(title: '哔哩轻小说 · 首页', list: records)];
  });

  /// Fetches a real site ranking or publisher-library page.
  ///
  /// `mode=rank` accepts the ranking slugs observed in site navigation.
  /// `mode=category` accepts an id returned by [categories]. Other modes fail
  /// explicitly rather than silently substituting a ranking.
  Future<PageStatsNovelCover> listPage(
    int page, {
    String mode = 'rank',
    int? category,
    String rank = 'monthvisit',
  }) async {
    if (page < 1 || page > budget.maxPage) {
      throw BiliSiteException('列表页码超出范围（1–${budget.maxPage}）');
    }
    late final Uri uri;
    if (mode == 'rank') {
      if (!_rankSlugs.contains(rank)) {
        throw UnsupportedError('不支持此哔哩轻小说榜单：$rank');
      }
      uri = Uri.parse('$_siteOrigin/top/$rank/$page.html');
    } else if (mode == 'category') {
      final selected = _categories.where((item) => item.id == category);
      if (selected.isEmpty) throw UnsupportedError('不支持此哔哩轻小说文库分类');
      final item = selected.first;
      uri = Uri.parse('$_siteOrigin/wenku/${item.slug}/$page.html');
    } else if (mode == 'all') {
      // The mobile all-library page uses a distinct, observed page-number
      // route. Page 1 is the shorter /wenku/ entry point.
      uri = Uri.parse(
        page == 1
            ? '$_siteOrigin/wenku/'
            : '$_siteOrigin/wenku/lastupdate_0_0_0_0_0_0_0_${page}_0.html',
      );
    } else {
      throw UnsupportedError('不支持此哔哩轻小说列表模式：$mode');
    }

    return _withSession((session) async {
      final document = await _getDocument(session, uri);
      final cards = _parseCards(
        document,
        bookCards:
            '.rank_d_list, #list_content.jsBooks > li.book-li, '
            'ol.book-ol > li.book-li, li.book-li',
        titleSelector:
            '.rank_d_b_name > a[href*="/novel/"], '
            'a.book-layout[href*="/novel/"]',
      );
      if (cards.isEmpty) {
        throw const FormatException('哔哩轻小说列表结构未识别或当前页面无数据');
      }
      return PageStatsNovelCover(
        currentPage: page,
        maxPage: _maxPage(document, page, cards.length, mode: mode),
        records: cards,
      );
    });
  }

  @override
  Future<PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) async {
    if (type == 'author') throw UnsupportedError('此书源暂不支持作者搜索');
    if (type.isNotEmpty && type != 'title' && type != 'articlename') {
      throw UnsupportedError('此书源仅支持书名搜索');
    }
    if (page < 1 || page > budget.maxPage) {
      throw BiliSiteException('搜索页码超出范围（1–${budget.maxPage}）');
    }
    final query = keyword.trim();
    if (query.isEmpty) {
      return PageStatsNovelCover(
        currentPage: page,
        maxPage: page,
        records: const [],
      );
    }
    final result = await _searcher(query, page);
    if (result.currentPage != page ||
        result.maxPage < page ||
        result.maxPage > budget.maxPage ||
        result.records.length > budget.maxBooks) {
      throw const FormatException('站端搜索结果分页信息无效');
    }
    for (final item in result.records) {
      _parseBookId(item.aid);
    }
    return result;
  }

  @override
  Future<SourceBookDetail> detail(String bookId) => _withSession(
    (session) async {
      final nid = _parseBookId(bookId);
      final detailUri = Uri.parse('$_siteOrigin/novel/$nid.html');
      final catalogUri = Uri.parse('$_siteOrigin/novel/$nid/catalog');
      // Both public pages are independent. Fetch the entire chapter tree once,
      // rather than issuing one request per volume.
      final List<dom.Document> pages;
      if (_documentsLoader case final load?) {
        final markup = await load([detailUri, catalogUri]);
        ReadRequest.current?.check();
        if (markup.length != 2 ||
            markup.any(
              (text) => utf8.encode(text).length > budget.maxResponseBytes,
            )) {
          throw const BiliSiteException('哔哩详情与目录数据无效或过大');
        }
        pages = ReadDiagnostics.measureSync(
          'bili',
          'html_parse',
          () => markup.map(html_parser.parse).toList(),
        );
      } else {
        pages = await Future.wait([
          _getDocument(session, detailUri),
          _getDocument(session, catalogUri),
        ]);
      }
      final detailDocument = pages[0];
      final catalogDocument = pages[1];
      final titleNode =
          detailDocument.querySelector('h1.book-name') ??
          detailDocument.querySelector('h1.book-title');
      final title = _requiredText(titleNode, '作品名');
      final mobileInfo =
          titleNode?.localName == 'h1' &&
                  titleNode!.classes.contains('book-title')
              ? _closestByClass(titleNode, 'book-layout')
              : null;
      if (detailDocument.querySelector('.book-html-box') == null &&
          mobileInfo == null) {
        throw const FormatException('哔哩轻小说详情结构未识别');
      }
      final catalogTitleNode =
          catalogDocument.querySelector('h1.book-title') ??
          catalogDocument.querySelector('h1');
      final catalogTitle = catalogTitleNode?.text.trim();
      if (catalogTitle == null || catalogTitle.isEmpty) {
        throw const FormatException('哔哩轻小说整本目录结构未识别');
      }
      if (catalogTitle != title) {
        throw const FormatException('作品详情与整本目录标题不匹配');
      }
      final volumes = _parseCatalog(catalogDocument, nid, bookId);
      final chapterCount = volumes.fold<int>(
        0,
        (sum, volume) => sum + volume.chapters.length,
      );
      if (chapterCount == 0) {
        throw const FormatException('哔哩轻小说目录尚无可读章节');
      }
      final infoNode = detailDocument.querySelector('.book-info');
      final labels =
          mobileInfo != null
              ? mobileInfo.querySelectorAll('p.book-meta .tag-small a')
              : infoNode?.querySelectorAll('.book-label a[href^="/wenku/"]') ??
                  const <dom.Element>[];
      final status =
          mobileInfo != null
              ? _mobileBookStatus(mobileInfo)
              : infoNode
                      ?.querySelector('.book-label a[href^="javascript:"]')
                      ?.text
                      .trim() ??
                  '';
      final authorNodes =
          mobileInfo != null
              ? mobileInfo.querySelectorAll('.book-rand-a .authorname a')
              : detailDocument.querySelectorAll(
                '.book-side .book-author a[href*="/authorarticle/"]',
              );
      final author = authorNodes
          .map((node) => node.text.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .join('、');
      final coverNode =
          mobileInfo?.querySelector('img.book-cover') ??
          detailDocument.querySelector('.book-img img');
      final cover = _safeImageUrl(
        coverNode?.attributes['data-src'] ??
            coverNode?.attributes['data-original'] ??
            coverNode?.attributes['src'],
      );
      final updateText =
          mobileInfo?.parent
              ?.querySelector('a.book-status .book-meta-l')
              ?.text ??
          detailDocument.querySelector('a.book-status .book-meta-l')?.text ??
          infoNode?.text ??
          '';
      final update = _updatedDate(updateText);
      final description =
          detailDocument.querySelector('#bookSummary content')?.text.trim() ??
          detailDocument.querySelector('.book-dec')?.text.trim() ??
          '';
      return SourceBookDetail(
        NovelInfo(
          title: title,
          author: author,
          status: status,
          finUpdate: update,
          imgUrl: cover ?? '',
          introduce: description,
          tags:
              labels
                  .map((node) => node.text.trim())
                  .where((value) => value.isNotEmpty)
                  .toList(),
          heat: '',
          trending: '',
          isAnimated: false,
        ),
        volumes,
      );
    },
    operationTimeout: budget.detailTimeout,
    timeoutMessage: '作品详情与目录请求超时',
  );

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    final nid = _parseBookId(bookId);
    final match = RegExp(r'^bili:([1-9]\d*):([1-9]\d*)$').firstMatch(chapterId);
    if (match == null) throw const FormatException('章节编号无效');
    if (int.parse(match.group(1)!) != nid) {
      throw const FormatException('章节不属于当前作品');
    }
    return _chapterLoader(bookId, chapterId);
  }

  Future<T> _withSession<T>(
    Future<T> Function(_SiteSession session) run, {
    Duration? operationTimeout,
    String timeoutMessage = '哔哩轻小说请求超时',
  }) async {
    final ownsClient = _injectedClient == null;
    final request = ReadRequest.current;
    request?.check();
    final session = _SiteSession(
      ownsClient ? http.Client() : _injectedClient,
      budget,
    );
    final removeCancel = request?.onCancel((error) {
      session.cancel(error);
      if (ownsClient) session.client.close();
    });
    final operationLimit =
        operationTimeout ??
        Duration(
          microseconds:
              budget.requestTimeout.inMicroseconds * (budget.maxRedirects + 1),
        );
    final timedOut = Completer<T>();
    final timer = Timer(operationLimit, () {
      final error = BiliSiteException(timeoutMessage);
      session.cancel(error);
      request?.cancel(error);
      timedOut.completeError(error, StackTrace.current);
    });
    final operation = Future<T>.sync(() => run(session));
    try {
      return await Future.any<T>([operation, timedOut.future]);
    } catch (error) {
      session.cancel(error);
      rethrow;
    } finally {
      removeCancel?.call();
      timer.cancel();
      session.close(ownsClient);
    }
  }

  Future<dom.Document> _getDocument(
    _SiteSession session,
    Uri initialUri,
  ) async {
    if (_documentLoader != null) {
      if (!_isSiteUri(initialUri)) throw const FormatException('哔哩轻小说请求地址无效');
      final markup = await _documentLoader(
        initialUri,
      ).timeout(budget.requestTimeout);
      ReadRequest.current?.check();
      if (utf8.encode(markup).length > budget.maxResponseBytes) {
        throw const BiliSiteException('哔哩页面数据过大');
      }
      return ReadDiagnostics.measureSync(
        'bili',
        'html_parse',
        () => html_parser.parse(markup),
      );
    }
    var uri = initialUri;
    for (var redirectCount = 0; ; redirectCount++) {
      session.throwIfCancelled();
      if (!_isSiteUri(uri)) throw const FormatException('哔哩轻小说请求地址无效');
      final clock = Stopwatch()..start();
      final request =
          http.Request('GET', uri)
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['accept'] = 'text/html,application/xhtml+xml'
            ..headers['user-agent'] = 'Mozilla/5.0'
            ..headers['referer'] = '$_siteOrigin/';
      late final http.StreamedResponse response;
      try {
        response = await session.wait(
          session.client.send(request),
          budget.requestTimeout,
          '哔哩轻小说单次页面请求超时',
        );
      } on BiliSiteException {
        rethrow;
      } catch (_) {
        throw const BiliSiteException('哔哩轻小说网络请求失败');
      }
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        await _cancelResponse(response);
        if (location == null || location.trim().isEmpty) {
          throw const BiliSiteException('哔哩轻小说重定向地址无效');
        }
        if (redirectCount >= budget.maxRedirects) {
          throw const BiliSiteException('哔哩轻小说重定向次数超限');
        }
        final target = uri.resolve(location);
        if (!_isSiteUri(target) || !_sameOrigin(uri, target)) {
          throw const BiliSiteException('哔哩轻小说重定向超出本站');
        }
        uri = target;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _cancelResponse(response);
        throw BiliSiteException('哔哩轻小说页面请求失败（HTTP ${response.statusCode}）');
      }
      if (response.contentLength != null &&
          response.contentLength! > budget.maxResponseBytes) {
        await _cancelResponse(response);
        throw BiliSiteException('哔哩轻小说页面超过 ${budget.maxResponseBytes} 字节上限');
      }
      final remaining = budget.requestTimeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        final error = const BiliSiteException('哔哩轻小说单次页面请求超时');
        session.cancel(error);
        throw error;
      }
      final bytes = await session.readBounded(response.stream, remaining);
      final charset = _charset(response.headers['content-type']);
      final source = _decode(bytes, charset);
      return html_parser.parse(source);
    }
  }

  List<NovelCover> _parseCards(
    dom.Document document, {
    required String bookCards,
    required String titleSelector,
  }) {
    final records = <NovelCover>[];
    final seen = <String>{};
    for (final card in document.querySelectorAll(bookCards)) {
      dom.Element? anchor;
      Uri? target;
      RegExpMatch? match;
      for (final candidate in card.querySelectorAll('a[href*="/novel/"]')) {
        final rawHref = candidate.attributes['href'];
        if (rawHref == null) continue;
        final resolved = _resolveSiteHref(rawHref);
        if (!_isSiteUri(resolved)) continue;
        final detailMatch = RegExp(
          r'^/novel/([1-9]\d*)\.html$',
        ).firstMatch(resolved.path);
        if (detailMatch == null) continue;
        anchor = candidate;
        target = resolved;
        match = detailMatch;
        break;
      }
      if (anchor == null || target == null || match == null) continue;
      if (!seen.add(match.group(1)!)) continue;
      final titleNode =
          card.querySelector('h4.book-title, .module-slide-caption') ??
          card.querySelector(titleSelector);
      final title = (titleNode?.text ?? anchor.text).trim();
      if (title.isEmpty) continue;
      final nid = int.parse(match.group(1)!);
      dom.Element? image =
          card.querySelector('img.book-cover') ?? card.querySelector('img');
      if (image == null) {
        for (final link in document.querySelectorAll('a[href]')) {
          final linked = _resolveSiteHref(link.attributes['href']!);
          if (_isSiteUri(linked) &&
              linked.path == target.path &&
              link.querySelector('img') != null) {
            image = link.querySelector('img');
            break;
          }
        }
      }
      records.add(
        NovelCover(
          aid: _bookId(nid),
          title: title,
          img:
              _safeImageUrl(
                image?.attributes['data-src'] ??
                    image?.attributes['data-original'] ??
                    image?.attributes['src'],
              ) ??
              '',
          detailUrl: _bookId(nid),
        ),
      );
      if (records.length >= budget.maxBooks) break;
    }
    return records;
  }

  int _maxPage(
    dom.Document document,
    int currentPage,
    int bookCount, {
    required String mode,
  }) {
    var max = currentPage;
    final links =
        mode == 'all'
            ? document.querySelectorAll('#pagelink a[href]')
            : document.querySelectorAll(
              '.pagebar .pages a[href], #pagelink a[href]',
            );
    for (final anchor in links) {
      final href = anchor.attributes['href'];
      if (href == null) continue;
      final uri = Uri.tryParse(href);
      if (uri == null || !_isSiteUri(_resolveSiteHref(href))) continue;
      final pageFromHref =
          mode == 'all'
              ? RegExp(_libraryPagePattern).firstMatch(uri.path)
              : RegExp(r'/(\d+)\.html(?:$|[?#])').firstMatch(uri.path);
      final candidate =
          int.tryParse(anchor.text.trim()) ??
          (pageFromHref == null ? null : int.tryParse(pageFromHref.group(1)!));
      if (candidate != null && candidate >= currentPage) {
        max = max > candidate ? max : candidate;
      }
    }
    // A full observed 30-book page proves that requesting the next page is
    // meaningful; this is a lower bound if the site omits numbered links.
    if (mode != 'all' &&
        max == currentPage &&
        bookCount >= _pageSize &&
        currentPage < budget.maxPage) {
      max = currentPage + 1;
    }
    return max.clamp(currentPage, budget.maxPage);
  }

  List<Volume> _parseCatalog(dom.Document document, int nid, String bookId) {
    final mobileRoot = document.querySelector('#volumes');
    final desktopRoot = document.querySelector('#volume-list');
    if (mobileRoot == null && desktopRoot == null) {
      throw const FormatException('哔哩轻小说目录缺少卷列表');
    }
    final mobileContainers =
        mobileRoot?.children
            .where(
              (node) =>
                  node.localName == 'div' &&
                  node.classes.contains('catalog-volume'),
            )
            .toList();
    final containers =
        mobileContainers != null && mobileContainers.isNotEmpty
            ? mobileContainers
            : desktopRoot?.querySelectorAll('div.volume') ??
                document.querySelectorAll('div.catalog-volume');
    if (containers.isEmpty) throw const FormatException('哔哩轻小说目录没有分卷');
    if (containers.length > budget.maxVolumes) {
      throw BiliSiteException('作品分卷超过 ${budget.maxVolumes} 卷上限');
    }
    final volumes = <Volume>[];
    var chapterCount = 0;
    for (final container in containers) {
      final heading = _requiredText(
        container.querySelector('h3') ?? container.querySelector('h2.v-line'),
        '分卷名',
      );
      final volumeId = _volumeId(container, nid);
      final chapters = <Chapter>[];
      final seenChapterIds = <String>{};
      for (final anchor in container.querySelectorAll(
        'ul.volume-chapters a.chapter-li-a[href], ul.chapter-list a[href]',
      )) {
        final href = anchor.attributes['href'];
        if (href == null) continue;
        final uri = Uri.parse(_siteOrigin).resolve(href);
        if (!_isSiteUri(uri)) continue;
        final foreign = RegExp(
          r'^/novel/([1-9]\d*)/(\d+)\.html$',
        ).firstMatch(uri.path);
        if (foreign == null) continue;
        if (int.parse(foreign.group(1)!) != nid) {
          throw const FormatException('目录章节不属于当前作品');
        }
        final cid = int.parse(foreign.group(2)!);
        if (!seenChapterIds.add('$cid')) continue;
        final title = anchor.text.trim();
        if (title.isEmpty) throw const FormatException('目录章节名为空');
        final stableId = _chapterId(nid, cid);
        chapters.add(
          Chapter(title: title, url: stableId, cid: stableId, aid: bookId),
        );
        chapterCount++;
        if (chapterCount > budget.maxChapters) {
          throw BiliSiteException('作品章节超过 ${budget.maxChapters} 章上限');
        }
      }
      volumes.add(
        Volume(
          id: 'bili:$nid:vol:$volumeId',
          title: heading,
          chapters: chapters,
        ),
      );
    }
    return volumes;
  }

  String _volumeId(dom.Element container, int nid) {
    final pattern = RegExp(r'^/novel/([1-9]\d*)/vol_([1-9]\d*)\.html$');
    for (final anchor in container.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'];
      if (href == null) continue;
      final uri = Uri.parse(_siteOrigin).resolve(href);
      if (!_isSiteUri(uri)) continue;
      final match = pattern.firstMatch(uri.path);
      if (match == null) continue;
      if (int.parse(match.group(1)!) != nid) {
        throw const FormatException('分卷不属于当前作品');
      }
      return match.group(2)!;
    }
    throw const FormatException('目录分卷编号缺失');
  }

  static int _parseBookId(String bookId) {
    final match = RegExp(r'^bili:([1-9]\d*)$').firstMatch(bookId);
    if (match == null) throw const FormatException('书籍编号无效');
    return int.parse(match.group(1)!);
  }

  static String _bookId(int nid) => 'bili:$nid';
  static String _chapterId(int nid, int cid) => 'bili:$nid:$cid';

  static bool _isSiteUri(Uri uri) =>
      uri.scheme == 'https' &&
      const {
        'www.bilinovel.net',
        'bilinovel.net',
        'www.linovelib.com',
        'linovelib.com',
      }.contains(uri.host.toLowerCase()) &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme == right.scheme &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static String? _safeImageUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final uri = Uri.parse(_siteOrigin).resolve(raw.trim());
    return _isSiteUri(uri) ? uri.toString() : null;
  }

  static Uri _resolveSiteHref(String raw) =>
      Uri.parse(_siteOrigin).resolve(raw);

  static String _mobileBookStatus(dom.Element layout) {
    for (final node in layout.querySelectorAll('p.book-meta')) {
      final text = node.text.trim();
      final match = RegExp(r'(完结|连载)').firstMatch(text);
      if (match != null) return match.group(1)!;
    }
    return '';
  }

  static dom.Element? _closestByClass(dom.Element element, String className) {
    dom.Node? node = element;
    while (node is dom.Element) {
      if (node.classes.contains(className)) return node;
      node = node.parent;
    }
    return null;
  }

  static String _updatedDate(String text) =>
      RegExp(
        r'最后更新\s*[·:：]?\s*(\d{4}-\d{2}-\d{2})',
      ).firstMatch(text)?.group(1) ??
      '';

  static String _requiredText(dom.Element? node, String field) {
    final text = node?.text.trim() ?? '';
    if (text.isEmpty) throw FormatException('$field缺失');
    return text;
  }

  static String? _charset(String? contentType) {
    if (contentType == null) return null;
    for (final parameter in contentType.split(';').skip(1)) {
      final separator = parameter.indexOf('=');
      if (separator < 0 ||
          parameter.substring(0, separator).trim().toLowerCase() != 'charset') {
        continue;
      }
      return parameter
          .substring(separator + 1)
          .trim()
          .replaceAll('"', '')
          .replaceAll("'", '')
          .toLowerCase();
    }
    return null;
  }

  static String _decode(Uint8List bytes, String? charset) {
    if (charset == null || charset == 'utf-8' || charset == 'utf8') {
      return utf8.decode(bytes, allowMalformed: false);
    }
    if (charset == 'iso-8859-1' ||
        charset == 'latin1' ||
        charset == 'windows-1252') {
      return latin1.decode(bytes);
    }
    throw FormatException('哔哩轻小说页面字符集不支持：$charset');
  }

  static Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  }
}

class _SiteSession {
  _SiteSession(this.client, this.budget);

  final http.Client client;
  final BiliSiteBudget budget;
  final Completer<Object> _cancelled = Completer<Object>();
  final Set<void Function(Object)> _cancelHandlers = {};
  Object? _cancelReason;
  bool _closed = false;

  void cancel(Object reason) {
    if (_cancelled.isCompleted) return;
    _cancelReason = reason;
    _cancelled.complete(reason);
    for (final handler in _cancelHandlers.toList()) {
      handler(reason);
    }
    _cancelHandlers.clear();
  }

  void throwIfCancelled() {
    if (_cancelled.isCompleted) throw _cancelReason!;
  }

  Future<T> wait<T>(Future<T> future, Duration timeout, String message) {
    final timer = Timer(timeout, () => cancel(BiliSiteException(message)));
    final canceled = _cancelled.future.then<T>((reason) => throw reason);
    return Future.any<T>([future, canceled]).whenComplete(timer.cancel);
  }

  Future<Uint8List> readBounded(
    Stream<List<int>> stream,
    Duration timeout,
  ) async {
    final output = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    var length = 0;
    late StreamSubscription<List<int>> subscription;
    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
      unawaited(subscription.cancel());
    }

    subscription = stream.listen(
      (chunk) {
        if (_cancelled.isCompleted) {
          fail(_cancelReason!);
          return;
        }
        if (length + chunk.length > budget.maxResponseBytes) {
          final error = BiliSiteException(
            '哔哩轻小说页面超过 ${budget.maxResponseBytes} 字节上限',
          );
          cancel(error);
          fail(error);
          return;
        }
        length += chunk.length;
        output.add(chunk);
      },
      onError:
          (Object error, StackTrace stack) =>
              fail(const BiliSiteException('哔哩轻小说页面读取失败')),
      onDone: () {
        if (!completer.isCompleted) completer.complete(output.takeBytes());
      },
      cancelOnError: true,
    );
    void onCancel(Object reason) => fail(reason);
    _cancelHandlers.add(onCancel);
    try {
      return await wait(completer.future, timeout, '哔哩轻小说页面读取超时');
    } finally {
      _cancelHandlers.remove(onCancel);
      await subscription.cancel();
    }
  }

  void close(bool closeClient) {
    if (_closed) return;
    _closed = true;
    if (!_cancelled.isCompleted) cancel(const BiliSiteException('请求已结束'));
    if (closeClient) client.close();
  }
}
