import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/services/wenku8_rate_limit.dart';
import 'package:wild/src/rust/api/database.dart' as db;
import 'package:wild/src/rust/api/wenku8.dart' as native;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/utils/wenku8_home_dom.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'package:wild/utils/wenku8_read_dom.dart';
import 'package:wild/utils/wenku8_search_navigation.dart';
import 'package:wild/utils/wenku8_document_read.dart';
import 'package:wild/utils/wenku8_bookshelf_dom.dart';

/// The browser owns its cookies. Only bounded, typed page data leaves it.
abstract interface class Wenku8BrowserPort {
  Future<void> loadUrl(String url);
  Future<String> currentUrl();
  Future<dynamic> executeScript(String script);
  Future<void> persistSession();
}

/// Optional platform capability. Only app-owned empty HTML may be loaded with
/// the configured HTTPS origin; website responses still need strict validation.
abstract interface class Wenku8DocumentContextPort {
  Future<bool> prepareDocumentContext(String host, String html);
}

// A platform-channel future can stall independently of page navigation. Bound
// every command so one broken WebView request cannot own the read queue forever.
class _BoundedBrowserPort
    implements Wenku8BrowserPort, Wenku8DocumentContextPort {
  _BoundedBrowserPort(this.inner, this.timeout, this.onTimeout, this.check);
  final Wenku8BrowserPort inner;
  final Duration timeout;
  final VoidCallback onTimeout;
  final VoidCallback check;
  bool expired = false;

  Future<T> _run<T>(Future<T> Function() operation) async {
    const error = Wenku8BrowserException('文库8网页组件响应超时，请重试。');
    check();
    if (expired) throw error;
    final result = await operation().timeout(
      timeout,
      onTimeout: () {
        expired = true;
        onTimeout();
        throw error;
      },
    );
    check();
    if (expired) throw error;
    return result;
  }

  @override
  Future<void> loadUrl(String url) => _run(() => inner.loadUrl(url));
  @override
  Future<String> currentUrl() => _run(inner.currentUrl);
  @override
  Future<dynamic> executeScript(String script) =>
      _run(() => inner.executeScript(script));
  @override
  Future<void> persistSession() => _run(inner.persistSession);

  @override
  Future<bool> prepareDocumentContext(String host, String html) {
    final port = inner;
    return port is Wenku8DocumentContextPort
        ? _run(
          () => (port as Wenku8DocumentContextPort).prepareDocumentContext(
            host,
            html,
          ),
        )
        : Future.value(false);
  }
}

class Wenku8BrowserException implements Exception {
  const Wenku8BrowserException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Wenku8SiteVerificationRequired extends Wenku8BrowserException {
  const Wenku8SiteVerificationRequired({this.target})
    : super('文库8要求站点验证。请打开站点完成验证或登录，再返回重试。');
  final Uri? target;
}

class _BrowserOperation {
  _BrowserOperation(this.timeout);
  final Duration timeout;
  final clock = Stopwatch()..start();
  final ports = <_BoundedBrowserPort>[];
  int? generation;
  bool expired = false;
  Duration get remaining => timeout - clock.elapsed;
  void check() {
    if (expired || remaining <= Duration.zero) {
      throw const Wenku8BrowserException('文库8请求等待超时，请重试。');
    }
  }
}

class Wenku8BrowserSession extends ChangeNotifier {
  Wenku8BrowserSession({
    Future<String> Function()? readHost,
    Future<String> Function(String)? readProperty,
    Future<void> Function(String, String)? writeProperty,
    this.pageTimeout = const Duration(seconds: 18),
    this.operationTimeout = const Duration(seconds: 30),
    this.requestInterval = const Duration(milliseconds: 350),
    this.pollInterval = const Duration(milliseconds: 150),
  }) : _readHost = readHost ?? native.getApiHost,
       _readProperty = readProperty ?? ((key) => db.loadProperty(key: key)),
       _writeProperty =
           writeProperty ??
           ((key, value) => db.saveProperty(key: key, value: value));

  static final instance = Wenku8BrowserSession();
  static const _modeKey = 'litetale.wenku8.browser_host';
  static const _loginKey = 'litetale.wenku8.browser_login_host';
  final Future<String> Function() _readHost;
  final Future<String> Function(String) _readProperty;
  final Future<void> Function(String, String) _writeProperty;
  final Duration pageTimeout;
  final Duration operationTimeout;
  final Duration requestInterval;
  final Duration pollInterval;
  final rateLimits = Wenku8RateLimits();
  static final _operationKey = Object();
  _BrowserOperation? get _operation =>
      Zone.current[_operationKey] as _BrowserOperation?;
  DateTime? _lastRequestAt;
  int _shelfCacheRevision = 0;
  ({String host, int session, DateTime until, Wenku8BookshelfSnapshot value})?
  _shelfSeed;
  Wenku8BrowserPort? _port;
  Completer<Wenku8BrowserPort>? _attachment;
  Future<void> _queue = Future.value();
  int _queuedOperations = 0;
  bool _disposed = false;
  VoidCallback? _cancelBackgroundRead;
  bool _requested = false;
  int _finished = 0;
  int _epoch = 0;
  int? _captchaEpoch;
  String? _captchaHost;
  Object? _navigationError;
  String? _navigationHost;
  String? _readContextHost;
  ({String host, bool browser})? _loginTransport;
  int _captchaRequest = 0;
  ({String query, int page, Uri url})? _nextSearchPage;
  final _sessionInvalidations = StreamController<void>.broadcast();

  /// Only a confirmed login redirect invalidates authentication. Ordinary
  /// transport or challenge failures do not sign the user out.
  Stream<void> get sessionInvalidations => _sessionInvalidations.stream;

  bool get requested => _requested;
  int rendererGeneration = 0;
  // Includes sessions adopted from a visible verification/login page. Kept
  // synchronous so a caller cannot hit an old cache before a stream delivers.
  int _readingSessionRevision = 0;
  int get readingSessionRevision => _readingSessionRevision;

  void invalidateBookshelfSnapshot() {
    _shelfCacheRevision++;
    _shelfSeed = null;
  }

  Future<Wenku8BrowserPort> _commands() async {
    final operation = _operation;
    operation?.check();
    final port = await _renderer();
    operation?.check();
    final commands = _BoundedBrowserPort(
      port,
      pageTimeout < const Duration(seconds: 5)
          ? pageTimeout
          : const Duration(seconds: 5),
      () {
        if (!identical(_port, port)) return;
        _port = null;
        _readContextHost = null;
        _attachment = null;
        _captchaEpoch = null;
        _epoch++;
        rendererGeneration++;
        // Replace the native view: a late command on the abandoned controller
        // must never navigate the controller used by the next queued request.
        notifyListeners();
      },
      () => operation?.check(),
    );
    operation?.ports.add(commands);
    return commands;
  }

  bool allowsNavigation(String url) =>
      url == 'about:blank' ||
      (_navigationHost != null && sameOrigin(url, _navigationHost!));

  Future<String> apiHost() async {
    final value = normalizeWenku8Host(await _readHost());
    return value.isEmpty ? defaultWenku8Host : value;
  }

  Future<bool> enabled() async =>
      await _readProperty(_modeKey) == await apiHost();

  Future<bool> hasSavedLogin() async =>
      await _readProperty(_loginKey) == await apiHost();

  Future<void> enable(String host) async {
    _operation?.check();
    final normalized = normalizeWenku8Host(host);
    if (normalized.isEmpty || normalized != await apiHost()) {
      throw const Wenku8BrowserException('文库8地址已更改，请在当前站点重新验证。');
    }
    await _writeProperty(_modeKey, normalized);
    _operation?.check();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sessionInvalidations.close());
    super.dispose();
  }

  void attach(Wenku8BrowserPort port) {
    _port = port;
    _readContextHost = null;
    final waiting = _attachment;
    if (waiting != null && !waiting.isCompleted) waiting.complete(port);
  }

  void detach(Wenku8BrowserPort port) {
    if (identical(port, _port)) {
      _port = null;
      _readContextHost = null;
      _attachment = null;
      _captchaEpoch = null;
      _epoch++;
    }
  }

  void pageFinished() => _finished++;

  void pageError() {
    _navigationError = const Wenku8BrowserException('文库8网页连接中断，请重试。');
  }

  void attachmentFailed() {
    final waiting = _attachment;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(
        const Wenku8BrowserException('文库8网页组件未能启动，请返回后重试。'),
      );
    }
  }

  Future<Wenku8BrowserPort> _renderer() async {
    if (_port case final ready?) return ready;
    _attachment ??= Completer<Wenku8BrowserPort>();
    if (!_requested) {
      _requested = true;
      notifyListeners();
    }
    final attachment = _attachment!;
    try {
      return await attachment.future.timeout(
        pageTimeout,
        onTimeout: () => throw const Wenku8BrowserException('文库8网页组件启动超时。'),
      );
    } catch (_) {
      if (identical(attachment, _attachment)) {
        _attachment = null;
        _requested = false;
        if (!_disposed) notifyListeners();
      }
      rethrow;
    }
  }

  Future<T> _serial<T>(
    Future<T> Function() operation, {
    bool background = false,
  }) {
    if (!background) _cancelBackgroundRead?.call();
    _queuedOperations++;
    final ticket = _BrowserOperation(operationTimeout);
    final work = _queue.then((_) {
      ticket.check(); // An expired queued read must never navigate later.
      ticket.generation = rendererGeneration;
      return runZoned(operation, zoneValues: {_operationKey: ticket});
    });
    final next = work
        .timeout(
          operationTimeout,
          onTimeout: () {
            ticket.expired = true;
            for (final port in ticket.ports) {
              port.expired = true;
            }
            if (ticket.generation == rendererGeneration) {
              _port = null;
              _readContextHost = null;
              _attachment = null;
              _requested = false;
              _captchaEpoch = null;
              _epoch++;
              rendererGeneration++;
              if (!_disposed) notifyListeners();
            }
            throw const Wenku8BrowserException('文库8请求等待超时，请重试。');
          },
        )
        .whenComplete(() {
          _queuedOperations--;
        });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Speculation uses only an established inert document. It never navigates,
  /// starts a renderer, touches a CAPTCHA, retries, or opens a verification UI.
  /// Any foreground browser command cancels it at the next poll, then parking
  /// aborts fetch before the foreground request takes ownership of the view.
  Future<String?> prefetchChapter(
    Uri target, {
    required String aid,
    required bool Function() isCurrent,
  }) {
    final admittedPort = _port;
    if (_queuedOperations != 0 ||
        admittedPort == null ||
        _captchaEpoch != null ||
        _readContextHost == null ||
        !isCurrent()) {
      return Future.value(null);
    }
    var cancelled = false;
    void cancel() => cancelled = true;
    bool interrupted() => cancelled || !isCurrent();
    _cancelBackgroundRead = cancel;
    return _serial(() async {
      String? host;
      Wenku8BrowserPort? port;
      try {
        host = await apiHost();
        if (interrupted() ||
            !identical(_port, admittedPort) ||
            _readContextHost != host ||
            !sameOrigin(target.toString(), host) ||
            _captchaEpoch != null) {
          return null;
        }
        port = await _commands();
        final snapshot = await _readDocument(
          port,
          host,
          target,
          wenku8ReadDomExtractionScript(host, kind: 'chapter', aid: aid),
          maxDuration: const Duration(seconds: 3),
          isCancelled: interrupted,
        );
        if (snapshot == null || interrupted() || await apiHost() != host) {
          return null;
        }
        return parseWenku8ReadWebViewResult(
              snapshot,
              apiHost: host,
              loadedUrl: target.toString(),
              kind: 'chapter',
              aid: aid,
            )
            as String;
      } catch (_) {
        return null;
      } finally {
        if (port != null && host != null) await _park(port, host);
        if (identical(_cancelBackgroundRead, cancel)) {
          _cancelBackgroundRead = null;
        }
      }
    }, background: true);
  }

  Future<T> nativeOrBrowser<T>(
    Future<T> Function() nativeRequest,
    Future<T> Function() browserRequest,
  ) async {
    final host = await apiHost().timeout(pageTimeout);
    rateLimits.check(host);
    if (await enabled().timeout(pageTimeout)) return browserRequest();
    try {
      return await nativeRequest().timeout(pageTimeout);
    } catch (error) {
      if (isWenku8RateLimited(error)) throw rateLimits.recordError(host, error);
      if (error is! TimeoutException &&
          !shouldUseWenku8WebViewFallback(error)) {
        rethrow;
      }
      return browserRequest();
    }
  }

  /// Keep the login POST on the transport that produced the displayed image,
  /// even if another request enables browser reading in the meantime.
  Future<Uint8List> downloadCheckcode(
    Future<Uint8List> Function() nativeRequest,
  ) async {
    final request = ++_captchaRequest;
    _loginTransport = null;
    final host = await apiHost();
    var browser = await enabled();
    late final Uint8List image;
    if (browser) {
      image = await captcha();
    } else {
      try {
        image = await nativeRequest();
      } catch (error) {
        if (!shouldUseWenku8WebViewFallback(error)) rethrow;
        browser = true;
        image = await captcha();
      }
    }
    if (host != await apiHost()) {
      throw const Wenku8BrowserException('文库8地址已更改，请刷新验证码。');
    }
    if (request == _captchaRequest) {
      _loginTransport = (host: host, browser: browser);
    }
    return image;
  }

  Future<void> submitLogin({
    required String username,
    required String password,
    required String checkcode,
    required Future<void> Function() nativeRequest,
  }) async {
    final transport = _loginTransport;
    _loginTransport = null;
    ++_captchaRequest;
    if (transport == null || transport.host != await apiHost()) {
      throw const Wenku8BrowserException('验证码已过期，请刷新验证码后登录。');
    }
    if (transport.browser) {
      await login(username, password, checkcode);
    } else {
      await nativeRequest();
    }
  }

  Future<Map<String, dynamic>> _pageState(Wenku8BrowserPort port) async {
    final raw = await port.executeScript(_pageStateScript);
    final value = raw is String ? jsonDecode(raw) : raw;
    if (value is! Map) {
      throw const Wenku8BrowserException('文库8网页状态无法读取，请重试。');
    }
    return Map<String, dynamic>.from(value);
  }

  static bool sameOrigin(String loadedUrl, String apiHost) {
    final loaded = Uri.tryParse(loadedUrl);
    String normalized;
    try {
      normalized = normalizeWenku8Host(apiHost);
    } on FormatException {
      return false;
    }
    if (normalized.isEmpty) return false;
    final host = Uri.parse(normalized);
    return loaded != null &&
        loaded.scheme == 'https' &&
        loaded.host == host.host &&
        loaded.port == 443 &&
        loaded.userInfo.isEmpty;
  }

  Future<void> _navigate(
    Wenku8BrowserPort port,
    String host,
    Uri target,
  ) async {
    if (!sameOrigin(target.toString(), host)) {
      throw const Wenku8BrowserException('文库8请求地址不属于当前站点。');
    }
    await _admitRequest(host);
    // Drain the old document before a new request. A late blank-page callback
    // or a previously loaded login page cannot complete this request.
    await _idle(port);
    _navigationHost = host;
    _epoch++;
    _captchaEpoch = null;
    _navigationError = null;
    await port.loadUrl(target.toString());
    await _waitForPage(port, host, target);
  }

  Future<void> _waitForPage(
    Wenku8BrowserPort port,
    String host,
    Uri target, {
    bool searchResult = false,
  }) async {
    final deadline = DateTime.now().add(pageTimeout);
    var verification = false;
    while (DateTime.now().isBefore(deadline)) {
      if (_navigationError case final error?) throw error;
      {
        final state = await _pageState(port);
        final url = state['url'] as String? ?? '';
        if (url == 'about:blank' ||
            url.isEmpty ||
            state['navigating'] == true) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        if (!sameOrigin(url, host)) {
          throw const Wenku8BrowserException('文库8网页离开了当前站点，已停止读取。');
        }
        if (state['rateLimited'] == true) throw rateLimits.record(host);
        final path = Uri.parse(url).path;
        if (searchResult &&
            path != '/login.php' &&
            path != '/modules/article/search.php' &&
            !RegExp(r'^/book/[1-9][0-9]{0,11}\.htm$').hasMatch(path) &&
            state['challenge'] != true) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        if (state['challenge'] == true) {
          verification = true;
        } else if (state['domReady'] == true ||
            state['ready'] == true ||
            (searchResult && state['searchReady'] == true)) {
          final loaded = Uri.parse(url);
          if (loaded.path == '/login.php' && target.path != '/login.php') {
            if (host == await apiHost()) {
              // A legacy native cookie can still report "signed in" even when
              // the browser has no session. Pin this verified login redirect
              // to browser mode before AuthCubit rechecks the current marker.
              await enable(host);
              await _writeProperty(_loginKey, '');
              _readingSessionRevision++;
              _sessionInvalidations.add(null);
            }
            throw const Wenku8BrowserException('文库8登录已失效，请重新登录。');
          }
          return;
        }
      }
      await Future<void>.delayed(pollInterval);
    }
    if (verification) throw Wenku8SiteVerificationRequired(target: target);
    throw const Wenku8BrowserException('文库8网页加载超时，请重试。');
  }

  Future<List<HomeBlock>> home() => _serial(() async {
    final host = await apiHost();
    final port = await _commands();
    var succeeded = false;
    try {
      final snapshot = await _readDocument(
        port,
        host,
        Uri.parse('$host/'),
        wenku8HomeDomExtractionScript(host),
      );
      if (snapshot != null) {
        try {
          final blocks = parseWenku8HomeWebViewResult(
            snapshot,
            apiHost: host,
            loadedUrl: '$host/',
          );
          await enable(host);
          succeeded = true;
          return blocks;
        } on FormatException {
          // Some site versions need normal navigation to initialize a page.
        }
      }
      await _navigate(port, host, Uri.parse('$host/'));
      final loaded = await port.currentUrl();
      final raw = await port.executeScript(wenku8HomeDomExtractionScript(host));
      final blocks = parseWenku8HomeWebViewResult(
        raw,
        apiHost: host,
        loadedUrl: loaded,
      );
      await enable(host);
      succeeded = true;
      return blocks;
    } finally {
      if (succeeded) {
        await _park(port, host);
      } else {
        await _idle(port);
      }
    }
  });

  Future<List<Bookcase>> bookcaseList() async {
    final host = await apiHost();
    final session = readingSessionRevision + _shelfCacheRevision;
    final snapshot = await _bookshelf('0');
    if (host == await apiHost() &&
        session == readingSessionRevision + _shelfCacheRevision) {
      _shelfSeed = (
        host: host,
        session: session,
        until: DateTime.now().add(const Duration(seconds: 10)),
        value: snapshot,
      );
    }
    return snapshot.bookcases;
  }

  Future<BookcaseDto> bookInCase(String caseId) async {
    final seed = _shelfSeed;
    _shelfSeed = null; // Reuse exactly the first page, never hide a refresh.
    if (seed != null &&
        seed.host == await apiHost() &&
        seed.session == readingSessionRevision + _shelfCacheRevision &&
        seed.until.isAfter(DateTime.now()) &&
        seed.value.caseId == caseId) {
      return seed.value.content;
    }
    return (await _bookshelf(caseId)).content;
  }

  Future<Wenku8BookshelfSnapshot> _bookshelf(String caseId) =>
      _serial(() async {
        if (!RegExp(r'^\d{1,12}$').hasMatch(caseId)) {
          throw const FormatException('文库8书架分组无效。');
        }
        final host = await apiHost();
        rateLimits.check(host);
        final port = await _commands();
        final target = Uri.parse(
          '$host/modules/article/bookcase.php?classid=$caseId',
        );
        final script = wenku8BookshelfScript(host, caseId);
        try {
          final raw = await _readDocument(port, host, target, script);
          if (raw != null) {
            try {
              final value = parseWenku8Bookshelf(raw, host, caseId);
              await enable(host);
              return value;
            } on FormatException {
              /* Try the ordinary same-origin page once. */
            }
          }
          await _navigate(port, host, target);
          if (await port.currentUrl() != target.toString()) {
            throw const Wenku8BrowserException('文库8书架地址不匹配，请重新登录后重试。');
          }
          final value = parseWenku8Bookshelf(
            await port.executeScript(script),
            host,
            caseId,
          );
          await enable(host);
          return value;
        } finally {
          await _park(port, host);
        }
      });

  Future<void> _waitForSearchPage(
    Wenku8BrowserPort port,
    String host,
    Uri target,
  ) async {
    await _waitForPage(port, host, target, searchResult: true);
    final interval = await port.executeScript(wenku8SearchIntervalScript(host));
    if (interval is! int || interval <= 0) return;
    // The site currently asks for five seconds between searches. Respect its
    // declared interval, but never wait indefinitely or replay a form POST.
    final loaded = Uri.tryParse(await port.currentUrl());
    if (interval > 10 ||
        loaded == null ||
        !isWenku8SearchRequest(loaded, host)) {
      throw const Wenku8BrowserException('文库8限制了搜索频率，请稍后重试。');
    }
    await Future<void>.delayed(Duration(seconds: interval, milliseconds: 150));
    await port.executeScript(
      'window.__liteTaleNavigating = true; location.reload(); true;',
    );
    await _waitForPage(port, host, target, searchResult: true);
    final repeated = await port.executeScript(wenku8SearchIntervalScript(host));
    if (repeated is int && repeated > 0) {
      throw const Wenku8BrowserException('文库8仍限制搜索频率，请稍后重试。');
    }
  }

  Future<T> read<T>(
    String kind,
    Uri target, {
    String? aid,
    String? searchKey,
  }) => _serial(() async {
    final host = await apiHost();
    final port = await _commands();
    String? searchIdentity;
    var succeeded = false;
    try {
      if (searchKey == null) {
        final snapshot = await _readDocument(
          port,
          host,
          target,
          wenku8ReadDomExtractionScript(host, kind: kind, aid: aid),
        );
        if (snapshot != null) {
          try {
            final value = parseWenku8ReadWebViewResult(
              snapshot,
              apiHost: host,
              loadedUrl: target.toString(),
              kind: kind,
              aid: aid,
            );
            await enable(host);
            succeeded = true;
            return value as T;
          } on FormatException {
            // Preserve the existing renderer path for changed/dynamic pages.
          }
        }
      }
      if (kind == 'list' &&
          searchKey != null &&
          isWenku8SearchRequest(target, host)) {
        final query = Uri.splitQueryString(target.query, encoding: latin1);
        final page = int.parse(query['page'] ?? '1');
        searchIdentity = jsonEncode([host, query['searchtype'], searchKey]);
        final cached = _nextSearchPage;
        if (page == 1 || cached?.query != searchIdentity) {
          _nextSearchPage = null;
        }
        if (_readContextHost != host) {
          await _navigate(port, host, Uri.parse('$host/'));
        }
        if (page > 1 &&
            cached?.query == searchIdentity &&
            cached?.page == page) {
          await port.executeScript(
            'window.__liteTaleNavigating = true; location.assign(${jsonEncode(cached!.url.toString())}); true;',
          );
          await _waitForSearchPage(port, host, target);
        } else {
          var submitted = await port.executeScript(
            wenku8SearchSubmitScript(host, searchKey, query['searchtype']!),
          );
          if (submitted != true && _readContextHost == host) {
            await _navigate(port, host, Uri.parse('$host/'));
            submitted = await port.executeScript(
              wenku8SearchSubmitScript(host, searchKey, query['searchtype']!),
            );
          }
          if (submitted != true) {
            throw const Wenku8BrowserException('文库8搜索表单已变化，请打开站点检查后重试。');
          }
          await _waitForSearchPage(port, host, target);
          if (page > 1) {
            if (await port.executeScript(wenku8SearchPageScript(host, page)) !=
                true) {
              throw const Wenku8BrowserException('文库8没有返回对应的搜索分页，请重新搜索。');
            }
            await _waitForSearchPage(port, host, target);
          }
        }
      } else if (target.path == '/modules/article/tags.php') {
        // Categories also expect ordinary same-origin navigation from home.
        await _navigate(port, host, Uri.parse('$host/'));
        if (!sameOrigin(target.toString(), host)) {
          throw const Wenku8BrowserException('文库8请求地址不属于当前站点。');
        }
        await port.executeScript(
          'window.__liteTaleNavigating = true; location.assign(${jsonEncode(target.toString())}); true;',
        );
        await _waitForPage(port, host, target);
      } else {
        await _navigate(port, host, target);
      }
      final loaded = await port.currentUrl();
      // Wenku8 redirects an exact, single search hit to its detail page.
      // Accept this only for a search GET and parse the strict detail model.
      final redirect = Uri.parse(loaded);
      final matchedBook = RegExp(
        r'^/book/([1-9][0-9]{0,11})\.htm$',
      ).firstMatch(redirect.path);
      if (kind == 'list' &&
          isWenku8SearchRequest(target, host) &&
          matchedBook != null &&
          sameOrigin(loaded, host) &&
          !redirect.hasQuery &&
          !redirect.hasFragment) {
        final bookId = matchedBook[1]!;
        final raw = await port.executeScript(
          wenku8ReadDomExtractionScript(host, kind: 'detail', aid: bookId),
        );
        final info =
            parseWenku8ReadWebViewResult(
                  raw,
                  apiHost: host,
                  loadedUrl: loaded,
                  kind: 'detail',
                  aid: bookId,
                )
                as NovelInfo;
        await enable(host);
        succeeded = true;
        return PageStatsNovelCover(
              currentPage: 1,
              maxPage: 1,
              records: [
                NovelCover(
                  title: info.title,
                  img: info.imgUrl,
                  detailUrl: loaded,
                  aid: bookId,
                ),
              ],
            )
            as T;
      }
      final raw = await port.executeScript(
        wenku8ReadDomExtractionScript(host, kind: kind, aid: aid),
      );
      final value = parseWenku8ReadWebViewResult(
        raw,
        apiHost: host,
        loadedUrl: loaded,
        kind: kind,
        aid: aid,
      );
      await enable(host);
      if (searchIdentity != null) _nextSearchPage = null;
      if (searchIdentity != null &&
          value is PageStatsNovelCover &&
          value.currentPage < value.maxPage) {
        final page = value.currentPage + 1;
        final rawUrl = await port.executeScript(
          wenku8SearchNextPageUrlScript(host, page),
        );
        final next = rawUrl is String ? Uri.tryParse(rawUrl) : null;
        if (next != null && isWenku8SearchRequest(next, host)) {
          _nextSearchPage = (query: searchIdentity, page: page, url: next);
        }
      }
      succeeded = true;
      return value as T;
    } finally {
      if (succeeded) {
        await _park(port, host);
      } else {
        await _idle(port);
      }
    }
  });

  Future<Uint8List> captcha() => _serial(() async {
    final host = await apiHost();
    final port = await _commands();
    try {
      await _navigate(port, host, Uri.parse('$host/login.php'));
      await port.executeScript(_refreshCaptchaScript);
      final deadline = DateTime.now().add(pageTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final raw = await port.executeScript(_captchaScript);
        final parsed = raw is String ? jsonDecode(raw) : raw;
        if (parsed is Map && parsed['ready'] == true) {
          if (!sameOrigin(parsed['url'] as String? ?? '', host)) {
            throw const Wenku8BrowserException('验证码不属于当前文库8站点。');
          }
          final data = parsed['data'] as String? ?? '';
          if (!data.startsWith('data:image/png;base64,') ||
              data.length > 512 * 1024) {
            throw const Wenku8BrowserException('文库8验证码图片无效，请重试。');
          }
          final bytes = base64Decode(
            data.substring('data:image/png;base64,'.length),
          );
          if (bytes.length < 8 || bytes[0] != 0x89 || bytes[1] != 0x50) {
            throw const Wenku8BrowserException('文库8验证码图片无效，请重试。');
          }
          _captchaHost = host;
          _captchaEpoch = _epoch;
          await enable(host);
          return bytes;
        }
        if (parsed is Map && parsed['failed'] == true) {
          throw const Wenku8BrowserException('文库8没有返回可用验证码，请刷新或打开站点登录。');
        }
        await Future<void>.delayed(pollInterval);
      }
      throw const Wenku8BrowserException('文库8验证码加载超时，请刷新或打开站点登录。');
    } catch (_) {
      await _idle(port);
      rethrow;
    }
  });

  Future<void> login(String username, String password, String checkcode) =>
      _serial(() async {
        final host = await apiHost();
        final port = await _commands();
        if (_captchaHost != host || _captchaEpoch != _epoch) {
          throw const Wenku8BrowserException('验证码已过期，请刷新验证码后登录。');
        }
        if (!sameOrigin(await port.currentUrl(), host)) {
          throw const Wenku8BrowserException('文库8登录地址已改变，请刷新验证码。');
        }
        final before = _finished;
        _navigationError = null;
        final submitted = await port.executeScript(
          _loginScript(host, username, password, checkcode),
        );
        if (submitted != true) {
          throw const Wenku8BrowserException('文库8登录表单已改变，请刷新验证码。');
        }
        _captchaEpoch = null;
        final deadline = DateTime.now().add(pageTimeout);
        while (DateTime.now().isBefore(deadline)) {
          if (_navigationError != null) {
            throw const Wenku8BrowserException('文库8登录结果未能确认，请打开站点查看。');
          }
          if (_finished > before) {
            final state = await _pageState(port);
            if (!sameOrigin(state['url'] as String? ?? '', host)) {
              throw const Wenku8BrowserException('文库8登录离开了当前站点。');
            }
            if (state['challenge'] == true) {
              throw const Wenku8SiteVerificationRequired();
            }
            if (state['ready'] == true && state['authenticated'] == true) {
              _readingSessionRevision++;
              await port.persistSession();
              await _writeProperty(_loginKey, host);
              await enable(host);
              await _idle(port);
              return;
            }
            if (state['loginError'] case final String message) {
              throw Wenku8BrowserException(message);
            }
          }
          await Future<void>.delayed(pollInterval);
        }
        throw const Wenku8BrowserException('文库8登录结果未能确认，请打开站点查看。');
      });

  Future<bool> adoptVisiblePage(
    String host,
    Object? snapshot, {
    Future<void> Function()? persistSession,
  }) async {
    final data = snapshot is String ? jsonDecode(snapshot) : snapshot;
    if (data is! Map || !sameOrigin(data['url'] as String? ?? '', host)) {
      throw const Wenku8BrowserException('当前网页不是配置的文库8站点。');
    }
    if (data['challenge'] == true || data['ready'] != true) {
      throw const Wenku8SiteVerificationRequired();
    }
    if (data['loginForm'] != true &&
        data['authenticated'] != true &&
        data['home'] != true) {
      throw const Wenku8BrowserException('请在文库8登录页或首页完成验证后返回。');
    }
    _readingSessionRevision++;
    _cancelBackgroundRead?.call();
    await persistSession?.call();
    await enable(host);
    _loginTransport = null;
    _captchaEpoch = null;
    ++_captchaRequest;
    final authenticated = data['authenticated'] == true;
    await _writeProperty(_loginKey, authenticated ? host : '');
    return authenticated;
  }

  static String get pageStateScript => _pageStateScript;

  Future<void> signOut() => _serial(() async {
    _readingSessionRevision++;
    await _writeProperty(_loginKey, '');
    _loginTransport = null;
    ++_captchaRequest;
    _captchaEpoch = null;
    if (!await enabled()) return;
    final host = await apiHost();
    final port = await _commands();
    try {
      await _navigate(port, host, Uri.parse('$host/logout.php'));
      await port.persistSession();
    } finally {
      await _idle(port);
    }
  });

  Future<Object?> _readDocument(
    Wenku8BrowserPort port,
    String host,
    Uri target,
    String extraction, {
    Duration maxDuration = const Duration(seconds: 8),
    bool Function()? isCancelled,
  }) async {
    rateLimits.check(host);
    if (isCancelled?.call() == true) return null;
    if (!sameOrigin(target.toString(), host)) return null;
    if (_readContextHost != host && !await _prepareReadContext(port, host)) {
      return null;
    }
    if (isCancelled?.call() == true) return null;
    final budget = pageTimeout < maxDuration ? pageTimeout : maxDuration;
    await _admitRequest(host);
    final started = await port.executeScript(
      wenku8DocumentReadScript(
        host: host,
        target: target,
        extraction: extraction,
        timeoutMs: budget.inMilliseconds,
      ),
    );
    if (started != true) {
      _readContextHost = null;
      return null;
    }
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() == true) return null;
      final raw = await port.executeScript(wenku8DocumentReadStateScript);
      if (isCancelled?.call() == true) return null;
      final value = raw is String ? jsonDecode(raw) : raw;
      if (value is! Map) return null;
      if (value['pending'] == true) {
        await Future<void>.delayed(pollInterval);
        continue;
      }
      if (value['error'] == 'timeout') break;
      if (value['error'] == 'size') {
        throw const Wenku8BrowserException('文库8网页数据过大，请重试。');
      }
      final status = value['status'];
      if (status == 429) {
        throw rateLimits.record(
          host,
          retryAfterSeconds: (value['retryAfterSeconds'] as num?)?.toInt(),
        );
      }
      if (status is int && status != 403) {
        throw Wenku8BrowserException('文库8请求失败（HTTP $status），请稍后重试。');
      }
      if (value['url'] != target.toString()) return null;
      return value['payload'];
    }
    throw const Wenku8BrowserException('文库8网页加载超时，请重试。');
  }

  Future<void> _admitRequest(String host) async {
    _operation?.check();
    rateLimits.check(host);
    final previous = _lastRequestAt;
    if (previous != null) {
      final wait = requestInterval - DateTime.now().difference(previous);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _operation?.check();
    rateLimits.check(host);
    _lastRequestAt = DateTime.now();
  }

  Future<bool> _prepareReadContext(Wenku8BrowserPort port, String host) async {
    if (port is! Wenku8DocumentContextPort) return false;
    _readContextHost = null;
    _captchaEpoch = null;
    _epoch++;
    _navigationHost = host;
    _navigationError = null;
    try {
      if (!await (port as Wenku8DocumentContextPort).prepareDocumentContext(
        host,
        wenku8EmptyReadContextHtml,
      )) {
        return false;
      }
    } catch (_) {
      if (port is _BoundedBrowserPort && port.expired) rethrow;
      return false;
    }
    final budget =
        pageTimeout < const Duration(seconds: 1)
            ? pageTimeout
            : const Duration(seconds: 1);
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (await port.executeScript(wenku8DocumentContextReadyScript(host)) ==
          true) {
        _readContextHost = host;
        return true;
      }
      await Future<void>.delayed(pollInterval);
    }
    await _idle(port);
    return false;
  }

  Future<void> _park(Wenku8BrowserPort port, String host) async {
    _operation?.check();
    _captchaEpoch = null;
    _epoch++;
    try {
      if (await port.executeScript(wenku8ParkDocumentScript(host)) == true) {
        _readContextHost = host;
        return;
      }
    } catch (_) {
      // Older browser engines can still use the normal navigation path.
    }
    await _idle(port);
  }

  Future<void> _idle(Wenku8BrowserPort port) async {
    _operation?.check();
    _readContextHost = null;
    _captchaEpoch = null;
    _epoch++;
    try {
      // Stop page scripts and image decoding while the reader is active.
      await port.loadUrl('about:blank');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (await port.currentUrl() == 'about:blank') return;
        await Future<void>.delayed(pollInterval);
      }
    } catch (_) {}
  }

  static const _pageStateScript = r'''
(function() {
  var title = (document.title || '').toLowerCase();
  // Login errors need no style/layout calculation for an entire book page.
  var text = location.pathname === '/login.php' && document.body ?
    document.body.textContent.slice(0,32000) : '';
  var challenge = !!document.querySelector('#challenge-form,#cf-challenge-running,.cf-browser-verification,#cf-wrapper') ||
    /just a moment|attention required|sorry, you have been blocked/.test(title);
  var rateLimited = /^(?:error\s*[:#]?\s*)?429(?:\s|$)|\bhttp\s*429\b|too many requests/.test(title) ||
    /^(?:error\s*[:#]?\s*)?429(?:\s|$)|\bhttp\s*429\b|too many requests/i.test(
      Array.from(document.querySelectorAll('h1,h2')).slice(0,4).map(function(n){return n.textContent;}).join(' '));
  var error = null;
  if (/用户不存在|用戶不存在/.test(text)) error = '用户不存在';
  else if (/密码错误|密碼錯誤/.test(text)) error = '密码错误';
  else if (/校验码错误|校驗碼錯誤|验证码错误|驗證碼錯誤/.test(text)) error = '验证码错误';
  else if (/验证码过期|驗證碼過期/.test(text)) error = '验证码过期';
  var loginForm = !!document.querySelector('form input[name="username"]') &&
    !!document.querySelector('form input[name="password"]');
  var signedIn = !!document.querySelector('a[href*="logout.php"]') && !loginForm;
  var stats=document.querySelector('#pagestats');
  var pages=stats && /([0-9]+)\s*\/\s*([0-9]+)/.exec(stats.textContent || '');
  // The result table and final paginator arrive before trailing site scripts.
  // Do not cut off a still-streaming table or lose its real next-page link.
  var searchReady=location.pathname==='/modules/article/search.php' &&
    !!document.querySelector('table.grid') && !!pages &&
    (Number(pages[2])===1 || !!document.querySelector('#pagelink a.last'));
  return JSON.stringify({url:location.href,ready:document.readyState === 'complete',
    navigating:window.__liteTaleNavigating === true,
    domReady:!!document.body && (document.readyState === 'interactive' || document.readyState === 'complete'),
    challenge:challenge,rateLimited:rateLimited,searchReady:searchReady,loginForm:loginForm,authenticated:!challenge && signedIn,
    home:!!document.querySelector('#centers,div.main'),loginError:error});
})()
''';

  static const _captchaScript = r'''
(function() {
  var result={url:location.href,ready:false};
  var form=document.querySelector('input[name="username"]');
  if(!form) {result.failed=true;return JSON.stringify(result);}
  var image=Array.from(document.images).find(function(i){
    try {var u=new URL(i.getAttribute('src')||'',location.href);
      return u.origin===location.origin && u.pathname==='/checkcode.php';}
    catch(_){return false;}
  });
  if(!image) {result.failed=true;return JSON.stringify(result);}
  if(!image.complete) return JSON.stringify(result);
  if(image.naturalWidth<1 || image.naturalHeight<1 || image.naturalWidth>1024 || image.naturalHeight>512) {
    result.failed=true;return JSON.stringify(result);
  }
  try {
    var canvas=document.createElement('canvas');
    canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
    canvas.getContext('2d').drawImage(image,0,0);
    result.data=canvas.toDataURL('image/png');result.ready=true;
  }catch(_){result.failed=true;}
  return JSON.stringify(result);
})()
''';

  static const _refreshCaptchaScript = r'''
(function() {
  if(location.pathname!=='/login.php') return false;
  var user=document.querySelector('input[name="username"]');
  var pass=document.querySelector('input[name="password"]');
  var form=user && user.form;
  if(!form || !pass || pass.form!==form || form.method.toLowerCase()!=='post') return false;
  var action=new URL(form.getAttribute('action')||location.href,location.href);
  if(action.origin!==location.origin || action.pathname!=='/login.php') return false;
  var image=Array.from(document.images).find(function(i){
    try {var u=new URL(i.getAttribute('src')||'',location.href);
      return u.origin===location.origin && u.pathname==='/checkcode.php';}
    catch(_){return false;}
  });
  // Some normal login forms omit the CAPTCHA controls. Request the official
  // image within this document so its session still owns the eventual POST.
  if(!image) {
    image=document.createElement('img');
    image.style.display='none';
    form.appendChild(image);
  }
  var url=new URL('/checkcode.php',location.href);
  url.searchParams.set('random',String(Date.now()));
  image.src=url.href;
  return true;
})()
''';

  static String _loginScript(
    String host,
    String username,
    String password,
    String code,
  ) => '''
(function(host,username,password,code) {
  if(location.origin!==host || location.pathname!=='/login.php') return false;
  var user=document.querySelector('input[name="username"]');
  var pass=document.querySelector('input[name="password"]');
  var captcha=document.querySelector('input[name="checkcode"]');
  var form=user && user.form;
  if(!form || !pass || pass.form!==form || (captcha && captcha.form!==form)) return false;
  var action=new URL(form.getAttribute('action')||location.href,location.href);
  if(action.origin!==host || action.pathname!=='/login.php' || form.method.toLowerCase()!=='post') return false;
  if(!captcha) {
    captcha=document.createElement('input');
    captcha.type='hidden';captcha.name='checkcode';
    form.appendChild(captcha);
  }
  user.value=username;pass.value=password;captcha.value=code;
  var actionInput=form.querySelector('input[name="action"]');
  if(actionInput) actionInput.value='login';
  var persistent=form.querySelector('[name="usecookie"]');
  if(persistent && persistent.tagName==='SELECT') {
    // Assigning a value absent from a select clears it and silently creates a
    // process-only session. Use the longest persistence option the site offers.
    var longest=0, selected=null;
    Array.from(persistent.options).forEach(function(option) {
      var seconds=Number(option.value);
      if(!option.disabled && Number.isFinite(seconds) && seconds>longest && seconds<=315360000) {
        longest=seconds;selected=option.value;
      }
    });
    if(selected!==null) persistent.value=selected;
  } else if(persistent && persistent.tagName==='INPUT') {
    persistent.value='315360000';
  }
  HTMLFormElement.prototype.submit.call(form);
  return true;
})(${jsonEncode(host)},${jsonEncode(username)},${jsonEncode(password)},${jsonEncode(code)})
''';
}
