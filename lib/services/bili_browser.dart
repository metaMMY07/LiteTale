import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/utils/bili_site_dom.dart';

abstract interface class BiliBrowserPort {
  Future<void> loadUrl(String url);
  Future<dynamic> executeScript(String script);
  Future<void> setDesktopSite(bool enabled);
}

class BiliBrowserException implements Exception {
  const BiliBrowserException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum BiliProbeKind { document, searchForm, searchResults, chapter }

class BiliSiteAccessDenied extends BiliBrowserException {
  const BiliSiteAccessDenied(this.target)
    : super('原站已拒绝访问此页面，当前没有可完成的验证。请稍后重试或更换书源。');
  final Uri target;
}

class BiliSiteVerificationRequired extends BiliBrowserException {
  const BiliSiteVerificationRequired({
    required this.target,
    required this.kind,
    required this.revision,
    this.desktopSite = false,
    this.contentRequired = false,
  }) : super(
         contentRequired
             ? '原站正文尚未完整加载，请打开原站完成阅读要求后继续。'
             : '哔哩轻小说要求浏览器验证，请打开原站完成验证后继续。',
       );

  final Uri target;
  final BiliProbeKind kind;
  final int revision;
  final bool desktopSite;
  final bool contentRequired;
}

class _VerifiedBiliPage {
  const _VerifiedBiliPage(this.data, this.revision, this.expires, this.bytes);
  final Map<String, dynamic> data;
  final int revision, bytes;
  final DateTime expires;
}

/// Ordinary site rendering. Website sessions stay in the platform browser;
/// this service receives only bounded public book data and visible chapter text.
class BiliBrowserSession extends ChangeNotifier {
  // Long chapters can legitimately exceed eight mobile website pages.
  // Keep a finite ceiling, same-chapter validation and the shared deadline.
  static const maxChapterPages = 64;

  BiliBrowserSession({
    this.operationTimeout = const Duration(seconds: 30),
    this.startupGrace = const Duration(seconds: 4),
    this.pollInterval = const Duration(milliseconds: 150),
    this.verificationGrace = const Duration(seconds: 6),
    this.verifiedPageTtl = const Duration(minutes: 2),
  });
  static final instance = BiliBrowserSession();
  final Duration operationTimeout, startupGrace, pollInterval;
  final Duration verificationGrace, verifiedPageTtl;
  bool requested = false, _disposed = false;
  int rendererGeneration = 0;
  BiliBrowserPort? _port;
  Completer<BiliBrowserPort>? _attachment;
  Future<void> _queue = Future.value();
  final _searchPages = <String, Map<int, Uri>>{};
  final _verifiedPages = <String, _VerifiedBiliPage>{};

  static String verificationScript(BiliSiteVerificationRequired request) =>
      switch (request.kind) {
        BiliProbeKind.document => biliDocumentProbeScript,
        BiliProbeKind.searchForm => biliHomeReadyScript,
        BiliProbeKind.searchResults => biliSearchProbeScript,
        BiliProbeKind.chapter => biliChapterProbeScript,
      };

  static BiliProbeKind _kind(String script) {
    if (script == biliDocumentProbeScript) return BiliProbeKind.document;
    if (script == biliHomeReadyScript) return BiliProbeKind.searchForm;
    if (script == biliSearchProbeScript) return BiliProbeKind.searchResults;
    return BiliProbeKind.chapter;
  }

  /// Visible verification stays on the requested site's HTTPS origin. Its
  /// normal challenge navigation may use paths outside the reading allowlist.
  static bool allowsVerificationNavigation(
    String raw,
    BiliSiteVerificationRequired request,
  ) {
    if (raw == 'about:blank') return true;
    if (!allowsNavigation('${request.target}')) return false;
    final uri = Uri.tryParse(raw);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.host == request.target.host &&
        uri.port == request.target.port;
  }

  static Map<String, dynamic> _decodeProbe(dynamic raw) {
    for (var i = 0; i < 2 && raw is String; i++) {
      raw = jsonDecode(raw);
    }
    if (raw is! Map || utf8.encode(jsonEncode(raw)).length > 2 * 1024 * 1024) {
      throw const BiliBrowserException('哔哩页面返回数据无效或过大');
    }
    return Map<String, dynamic>.from(raw);
  }

  static bool isAccessDeniedProbe(dynamic raw) =>
      _decodeProbe(raw)['accessDenied'] == true;

  static bool _samePage(Uri actual, Uri expected) =>
      actual.scheme == 'https' &&
      actual.origin == expected.origin &&
      actual.path == expected.path &&
      actual.queryParametersAll.length == expected.queryParametersAll.length &&
      expected.queryParametersAll.entries.every(
        (entry) =>
            listEquals(actual.queryParametersAll[entry.key], entry.value),
      );

  static String _probeKey(Uri uri, BiliProbeKind kind) {
    // The verified desktop catalogue is the same public document as the
    // mobile entry. Never generalize this alias to other sources or hosts.
    final catalogAlias =
        kind == BiliProbeKind.document &&
        RegExp(r'^/novel/[1-9]\d*/catalog$').hasMatch(uri.path) &&
        const {'www.linovelib.com', 'www.bilinovel.net'}.contains(uri.host);
    final host = catalogAlias ? 'bili-public-catalog' : uri.host;
    return '${kind.name}:$host:${uri.path}?${uri.query}';
  }

  Map<String, dynamic>? _verifiedProbe(Uri uri, BiliProbeKind kind) {
    if (!allowsNavigation('$uri')) return null;
    _verifiedPages.removeWhere(
      (_, value) =>
          value.revision != sourceRevision.value ||
          !DateTime.now().isBefore(value.expires),
    );
    return _verifiedPages[_probeKey(uri, kind)]?.data;
  }

  /// Adopt only the requested, actually loaded public page. Cookies remain in
  /// the platform store; the short-lived snapshot prevents a second request
  /// immediately discarding a chapter the user has just verified.
  Future<bool> adoptVisiblePage(
    BiliSiteVerificationRequired request,
    dynamic raw, {
    required Future<void> Function() persistSession,
    required bool Function() isCurrent,
  }) async {
    bool current() =>
        !_disposed &&
        isCurrent() &&
        activeSource.value == SourceId.bili &&
        sourceRevision.value == request.revision;
    if (!current()) return false;
    final value = _decodeProbe(raw);
    if (value['accessDenied'] == true) {
      throw BiliSiteAccessDenied(request.target);
    }
    final uri = Uri.tryParse('${value['url']}');
    if (!allowsNavigation('${request.target}') ||
        uri == null ||
        !allowsVerificationNavigation('$uri', request) ||
        uri.path != request.target.path ||
        uri.queryParametersAll.length !=
            request.target.queryParametersAll.length ||
        !request.target.queryParametersAll.entries.every(
          (entry) => listEquals(uri.queryParametersAll[entry.key], entry.value),
        ) ||
        value['verificationRequired'] == true ||
        value['contentIncomplete'] == true ||
        value['error'] != null ||
        value['ready'] != true) {
      throw BiliBrowserException(
        request.contentRequired
            ? '原站正文仍未完整加载，请按网页提示完成后再试。'
            : '请先在原站完成验证并打开所需页面，再继续。',
      );
    }
    if (request.kind == BiliProbeKind.chapter) {
      final match = RegExp(
        r'^/novel/([1-9]\d*)/([1-9]\d*)(?:_\d+)?\.html$',
      ).firstMatch(request.target.path);
      final content = value['content'];
      if (match == null || content is! String || content.trim().isEmpty) {
        throw const BiliBrowserException('原站章节尚未加载完成，请稍后再试。');
      }
      if (value['next'] case final String rawNext) {
        final next = Uri.tryParse(rawNext);
        if (next == null ||
            !allowsNavigation('$next') ||
            next.origin != request.target.origin ||
            next.hasQuery ||
            !RegExp(
              '^/novel/${match[1]}/${match[2]}_[1-9][0-9]*\\.html\$',
            ).hasMatch(next.path)) {
          throw const BiliBrowserException('章节分页不属于当前章节');
        }
      }
    } else if (request.kind == BiliProbeKind.document &&
        (value['html'] is! String ||
            (value['html'] as String).trim().isEmpty)) {
      throw const BiliBrowserException('原站页面尚未加载完成，请稍后再试。');
    }
    await persistSession().timeout(const Duration(seconds: 5));
    if (!current()) return false;
    if (request.kind == BiliProbeKind.document ||
        request.kind == BiliProbeKind.chapter) {
      final data = Map<String, dynamic>.from(value)
        ..['url'] = '${request.target}';
      final bytes = utf8.encode(jsonEncode(data)).length;
      _verifiedPages[_probeKey(
        request.target,
        request.kind,
      )] = _VerifiedBiliPage(
        Map.unmodifiable(data),
        request.revision,
        DateTime.now().add(verifiedPageTtl),
        bytes,
      );
      while (_verifiedPages.length > 8 ||
          _verifiedPages.values.fold<int>(0, (n, p) => n + p.bytes) >
              2 * 1024 * 1024) {
        _verifiedPages.remove(_verifiedPages.keys.first);
      }
    }
    return true;
  }

  static bool allowsNavigation(String raw) {
    if (raw == 'about:blank') return true;
    final uri = Uri.tryParse(raw);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        const {
          'www.linovelib.com',
          'linovelib.com',
          'www.bilinovel.net',
          'bilinovel.net',
        }.contains(uri.host) &&
        (uri.path == '/' ||
            uri.path == '/S6/' ||
            uri.path == '/search.html' ||
            RegExp(r'^/novel/[1-9]\d*/catalog$').hasMatch(uri.path) ||
            RegExp(r'^/top/[a-z]+/[1-9]\d*\.html$').hasMatch(uri.path) ||
            RegExp(r'^/wenku/(?:[a-z]+/[1-9]\d*\.html)?$').hasMatch(uri.path) ||
            RegExp(
              r'^/wenku/lastupdate_(?:\d+_){7}[1-9]\d*_0\.html$',
            ).hasMatch(uri.path) ||
            RegExp(
              r'^/novel/[1-9]\d*(?:\.html|/[1-9]\d*(?:_\d+)?\.html)$',
            ).hasMatch(uri.path));
  }

  void attach(BiliBrowserPort port, int generation) {
    if (_disposed || generation != rendererGeneration) return;
    _port = port;
    if (_attachment case final pending? when !pending.isCompleted) {
      pending.complete(port);
    }
  }

  void detach(BiliBrowserPort port) {
    if (identical(_port, port)) _port = null;
  }

  void attachmentFailed() => _invalidate();
  void _invalidate() {
    _port = null;
    if (_attachment case final pending? when !pending.isCompleted) {
      pending.completeError(const BiliBrowserException('哔哩网页组件未就绪，请重试'));
    }
    _attachment = null;
    rendererGeneration++;
    if (!_disposed) notifyListeners();
  }

  Future<BiliBrowserPort> _renderer() async {
    if (_port != null) return _port!;
    _attachment ??= Completer<BiliBrowserPort>();
    if (!requested) {
      requested = true;
      notifyListeners();
    }
    return _attachment!.future;
  }

  Future<T> _operation<T>(
    Future<T> Function(
      BiliBrowserPort,
      Future<dynamic> Function(String),
      Future<void> Function(String),
      Future<void> Function(bool),
      Stopwatch,
    )
    run, {
    Duration? timeout,
    String timeoutMessage = '哔哩网页操作超时，请重试',
  }) {
    final totalLimit = timeout ?? operationTimeout;
    final clock = Stopwatch()..start();
    int? activeGeneration;
    void invalidateActive() {
      if (activeGeneration == rendererGeneration) _invalidate();
    }

    final work = _queue.then<T>((_) async {
      final generation = rendererGeneration;
      activeGeneration = generation;
      void check() {
        if (_disposed ||
            generation != rendererGeneration ||
            clock.elapsed >= totalLimit) {
          throw const BiliBrowserException('哔哩网页操作已超时，请重试');
        }
      }

      Future<R> command<R>(Future<R> Function() call) async {
        check();
        final left = totalLimit - clock.elapsed;
        final limit =
            left < const Duration(seconds: 5)
                ? left
                : const Duration(seconds: 5);
        final value = await call().timeout(
          limit,
          onTimeout: () {
            invalidateActive();
            throw const BiliBrowserException('哔哩网页组件响应超时，请重试');
          },
        );
        check();
        return value;
      }

      // Mounting a cold platform view is not an already-attached command.
      // Give attachment the remaining operation budget; real platform calls
      // below still have their separate five-second limit.
      check();
      final port = await _renderer().timeout(
        totalLimit - clock.elapsed,
        onTimeout: () {
          invalidateActive();
          throw const BiliBrowserException('哔哩网页组件启动超时，请重试');
        },
      );
      check();
      try {
        await command(() => port.setDesktopSite(false));
        return await run(
          port,
          (script) => command(() => port.executeScript(script)),
          (url) async {
            if (!allowsNavigation(url)) {
              throw const BiliBrowserException('哔哩页面跳转地址无效');
            }
            await command(() => port.loadUrl(url));
          },
          (enabled) => command(() => port.setDesktopSite(enabled)),
          clock,
        );
      } finally {
        if (generation == rendererGeneration) {
          try {
            await port
                .loadUrl('about:blank')
                .timeout(const Duration(seconds: 2));
          } catch (_) {
            invalidateActive();
          }
        }
      }
    });
    _queue = work.then<void>((_) {}, onError: (Object _) {});
    return work.timeout(
      totalLimit,
      onTimeout: () {
        invalidateActive();
        throw BiliBrowserException(timeoutMessage);
      },
    );
  }

  Future<Map<String, dynamic>> _poll(
    Future<dynamic> Function(String) js,
    String script,
    Stopwatch clock, {
    bool Function(Map<String, dynamic>)? accepts,
    Uri? verificationTarget,
    bool desktopSite = false,
  }) async {
    Duration? verificationStarted;
    while (clock.elapsed < operationTimeout) {
      dynamic raw;
      try {
        raw = await js(script);
      } catch (error) {
        if (RegExp(
          r'execution context.*destroy|navigation.*cancel|ERR_ABORTED',
          caseSensitive: false,
        ).hasMatch('$error')) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        rethrow;
      }
      final value = _decodeProbe(raw);
      if (!allowsNavigation('${value['url']}')) {
        throw const BiliBrowserException('哔哩页面跳转地址无效');
      }
      if (accepts != null && !accepts(value)) {
        await Future<void>.delayed(pollInterval);
        continue;
      }
      if (value['accessDenied'] == true) {
        throw BiliSiteAccessDenied(
          verificationTarget ?? Uri.parse('${value['url']}'),
        );
      }
      if (value['contentIncomplete'] == true) {
        verificationStarted ??= clock.elapsed;
        if (clock.elapsed - verificationStarted < verificationGrace) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        throw BiliSiteVerificationRequired(
          target: verificationTarget ?? Uri.parse('${value['url']}'),
          kind: _kind(script),
          desktopSite: desktopSite,
          contentRequired: true,
          revision: sourceRevision.value,
        );
      }
      if (value['error'] != null) {
        if (value['verificationRequired'] == true ||
            '${value['error']}'.contains('浏览器验证')) {
          if (value['verificationPending'] == true) {
            verificationStarted ??= clock.elapsed;
            if (clock.elapsed - verificationStarted < verificationGrace) {
              await Future<void>.delayed(pollInterval);
              continue;
            }
          }
          throw BiliSiteVerificationRequired(
            target:
                verificationTarget ??
                Uri.parse('${value['url']}').replace(query: '', fragment: ''),
            kind: _kind(script),
            desktopSite: desktopSite,
            revision: sourceRevision.value,
          );
        }
        throw BiliBrowserException('${value['error']}');
      }
      if (value['ready'] == true) {
        return value;
      }
      await Future<void>.delayed(pollInterval);
    }
    throw const BiliBrowserException('原站未返回内容，请稍后重试');
  }

  Future<String> document(Uri uri) => _operation(
    (port, js, load, mode, clock) async {
      final cached = _verifiedProbe(uri, BiliProbeKind.document);
      if (cached != null) return '${cached['html']}';
      await load('$uri');
      var desktopFallback = false;
      Future<Map<String, dynamic>> read() => _poll(
        js,
        biliDocumentProbeScript,
        clock,
        verificationTarget:
            desktopFallback ? uri.replace(host: 'www.linovelib.com') : uri,
        desktopSite: desktopFallback,
        accepts: (value) {
          final page = Uri.parse('${value['url']}');
          return page.path == uri.path &&
              (!desktopFallback ||
                  const {
                    'www.linovelib.com',
                    'linovelib.com',
                  }.contains(page.host));
        },
      );
      Map<String, dynamic> value;
      try {
        value = await read();
      } on BiliSiteVerificationRequired {
        // Both hosts are the site's own observed mobile/desktop entry points.
        // Only a blocked full catalogue gets one desktop-site fallback.
        if (!uri.host.endsWith('bilinovel.net') ||
            !uri.path.endsWith('/catalog')) {
          rethrow;
        }
        await mode(true);
        desktopFallback = true;
        await load('${uri.replace(host: 'www.linovelib.com')}');
        value = await read();
      }
      if (Uri.parse('${value['url']}').path != uri.path) {
        throw const BiliBrowserException('原站返回的页面不匹配');
      }
      return '${value['html']}';
    },
    timeout: const Duration(seconds: 15),
    timeoutMessage: '哔哩页面读取超时，请重试',
  );

  Future<PageStatsNovelCover> search(String keyword, int page) => _operation((
    port,
    js,
    load,
    mode,
    clock,
  ) async {
    final query = keyword.trim();
    if (query.isEmpty || query.length > 200 || page < 1 || page > 100) {
      throw const FormatException('搜索关键词或页码无效');
    }
    Uri? requestedPage;
    if (page == 1) {
      _searchPages.remove(query);
      final desktop = defaultTargetPlatform == TargetPlatform.windows;
      final entry =
          desktop
              ? 'https://www.linovelib.com/'
              : 'https://www.bilinovel.net/search.html';
      await load(entry);
      await _poll(
        js,
        biliHomeReadyScript,
        clock,
        verificationTarget: Uri.parse(entry),
        accepts:
            (value) =>
                Uri.parse('${value['url']}').path == Uri.parse(entry).path,
      );
      // The ordinary site's asynchronous resource initialization must finish
      // before submitting its own form. No guard tokens are forged or read.
      await Future<void>.delayed(startupGrace);
      if (await js(biliSubmitSearchScript(query)) != true) {
        throw const BiliBrowserException('原站搜索表单已变化');
      }
    } else {
      final next = _searchPages[query]?[page];
      if (next == null) throw const BiliBrowserException('搜索分页已失效，请重新搜索');
      requestedPage = next;
      await load('$next');
    }
    final value = await _poll(
      js,
      biliSearchProbeScript,
      clock,
      verificationTarget: requestedPage,
      accepts: (value) {
        final expected = requestedPage;
        if (expected == null) return true;
        // loadRequest may return before the previous document is replaced.
        // Match the real next link, regardless of query parameter order.
        final actual = Uri.parse('${value['url']}');
        final query = actual.queryParametersAll;
        final expectedQuery = expected.queryParametersAll;
        return actual.path == expected.path &&
            query.length == expectedQuery.length &&
            expectedQuery.entries.every(
              (entry) => listEquals(query[entry.key], entry.value),
            );
      },
    );
    final books = <NovelCover>[];
    final seen = <String>{};
    for (final raw in value['books'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final nid = '${item['nid']}';
      final title = '${item['title'] ?? ''}'.trim();
      if (!RegExp(r'^[1-9]\d*$').hasMatch(nid) ||
          title.isEmpty ||
          !seen.add(nid)) {
        continue;
      }
      final image = Uri.tryParse('${item['image'] ?? ''}');
      final safeImage =
          image != null &&
                  const ['https', 'http'].contains(image.scheme) &&
                  image.userInfo.isEmpty
              ? '$image'
              : '';
      books.add(
        NovelCover(
          aid: 'bili:$nid',
          title: title,
          img: safeImage,
          detailUrl: 'bili:$nid',
        ),
      );
      if (books.length > 100) throw const BiliBrowserException('搜索结果过多');
    }
    var maxPage = page;
    if (value['next'] case final String raw) {
      final next = Uri.tryParse(raw);
      if (next == null ||
          !allowsNavigation(raw) ||
          !const ['/S6/', '/search.html'].contains(next.path) ||
          (next.queryParameters.containsKey('searchkey') &&
              next.queryParameters['searchkey'] != query) ||
          raw == value['url']) {
        throw const BiliBrowserException('原站搜索分页地址无效');
      }
      if (_searchPages.length >= 16 && !_searchPages.containsKey(query)) {
        _searchPages.remove(_searchPages.keys.first);
      }
      (_searchPages[query] ??= {})[page + 1] = next;
      maxPage = page + 1;
    }
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: maxPage,
      records: books,
    );
  });

  Future<SourceChapter> chapter(String bookId, String chapterId) => _operation((
    port,
    js,
    load,
    mode,
    clock,
  ) async {
    final bid = RegExp(r'^bili:([1-9]\d*)$').firstMatch(bookId);
    final cid = RegExp(r'^bili:([1-9]\d*):([1-9]\d*)$').firstMatch(chapterId);
    if (bid == null || cid == null || bid[1] != cid[1]) {
      throw const FormatException('章节不属于当前作品');
    }
    var uri = Uri.parse(
      'https://www.bilinovel.net/novel/${bid[1]}/${cid[2]}.html',
    );
    final seen = <String>{};
    final chunks = <String>[];
    var contentLength = 0;
    for (var page = 0; page < maxChapterPages; page++) {
      if (!seen.add('$uri')) throw const BiliBrowserException('章节分页发生循环');
      var value = _verifiedProbe(uri, BiliProbeKind.chapter);
      if (value == null) {
        await load('$uri');
        value = await _poll(
          js,
          biliChapterProbeScript,
          clock,
          verificationTarget: uri,
          accepts: (value) => _samePage(Uri.parse('${value['url']}'), uri),
        );
      }
      final finalUri = Uri.parse('${value['url']}');
      if (!_samePage(finalUri, uri)) {
        throw const BiliBrowserException('原站返回了其他章节');
      }
      final content = '${value['content'] ?? ''}'.trim();
      if (content.isEmpty) throw const BiliBrowserException('原站正文为空');
      chunks.add(content);
      contentLength += content.length;
      if (contentLength > 2 * 1024 * 1024) {
        throw const BiliBrowserException('章节正文过大');
      }
      if (value['next'] == null) return SourceChapter(chunks.join('\n'));
      final next = Uri.parse('${value['next']}');
      if (!allowsNavigation('$next') ||
          next.origin != uri.origin ||
          next.hasQuery ||
          !RegExp(
            '^/novel/${bid[1]}/${cid[2]}_[1-9][0-9]*\\.html\$',
          ).hasMatch(next.path)) {
        throw const BiliBrowserException('章节分页不属于当前章节');
      }
      uri = next;
    }
    throw const BiliBrowserException('章节分页超过64页安全上限');
  });

  @override
  void dispose() {
    _disposed = true;
    _verifiedPages.clear();
    _invalidate();
    super.dispose();
  }
}
