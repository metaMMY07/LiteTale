import 'package:wild/widgets/platform_controls.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' show getSessionCookieString;
import 'package:wild/src/rust/wenku8/models.dart' show HomeBlock;
import 'package:wild/utils/wenku8_home_dom.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/wenku_webview.dart';

/// Visible, ordinary site verification/login. Cookies stay in the WebView.
class Wenku8VerificationPage extends StatefulWidget {
  const Wenku8VerificationPage({
    super.key,
    required this.apiHost,
    this.sessionOnly = false,
    this.startAtLogin = false,
    this.target,
  });

  final String apiHost;
  final bool sessionOnly;
  final bool startAtLogin;
  final Uri? target;

  @override
  State<Wenku8VerificationPage> createState() => _Wenku8VerificationPageState();
}

class _Wenku8VerificationPageState extends State<Wenku8VerificationPage> {
  final WenkuWebView _webView = WenkuWebView();
  late final String _apiHost;
  late final String _entryUrl;
  late final int _sourceRevision;
  bool _initialized = false;
  bool _injectingSession = false;
  bool _sessionSeeded = false;
  bool _extractingHome = false;
  bool _closed = false;
  bool _accessDenied = false;
  int _pageLoad = 0;
  String? _error;

  bool get _current =>
      mounted &&
      !_closed &&
      activeSource.value == SourceId.wenku8 &&
      sourceRevision.value == _sourceRevision;

  @override
  void initState() {
    super.initState();
    final normalized = normalizeWenku8Host(widget.apiHost);
    _apiHost = normalized.isEmpty ? defaultWenku8Host : normalized;
    _sourceRevision = sourceRevision.value;
    final target = widget.target;
    _entryUrl =
        widget.startAtLogin
            ? '$_apiHost/login.php'
            : target != null &&
                Wenku8BrowserSession.sameOrigin('$target', _apiHost)
            ? '$target'
            : '$_apiHost/';
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _webView
          .initialize(
            onLoaded: () => unawaited(_onLoaded()),
            allowMainFrameNavigation:
                (url) =>
                    url == 'about:blank' ||
                    Wenku8BrowserSession.sameOrigin(url, _apiHost),
            onError: (_) {
              if (_current) {
                setState(() {
                  _error = '无法打开文库8站点，请检查网络后重试。';
                });
              }
            },
          )
          .timeout(const Duration(seconds: 15));
      if (!_current) return;
      setState(() => _initialized = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!_current) return;
      await _webView.loadUrl(_entryUrl).timeout(const Duration(seconds: 5));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '文库8网页组件未能启动，请返回后重试。';
      });
    }
  }

  Future<void> _onLoaded() async {
    if (!_current) return;
    final load = ++_pageLoad;
    await _seedSessionCookies();
    if (!_current || load != _pageLoad) return;
    try {
      final raw = await _webView
          .executeScript(Wenku8BrowserSession.pageStateScript)
          .timeout(const Duration(seconds: 5));
      final state = raw is String ? jsonDecode(raw) : raw;
      if (!_current ||
          load != _pageLoad ||
          state is! Map ||
          !Wenku8BrowserSession.sameOrigin('${state['url']}', _apiHost)) {
        return;
      }
      final denied = state['accessDenied'] == true;
      setState(() {
        if (_accessDenied && !denied) _error = null;
        _accessDenied = denied;
        if (denied) _error = const Wenku8SiteAccessDenied().message;
      });
    } catch (_) {
      // The site may be between documents. Confirmation checks it again.
    }
  }

  Future<void> _seedSessionCookies() async {
    if (_sessionSeeded || _injectingSession || !mounted) return;
    _injectingSession = true;
    try {
      if (widget.startAtLogin ||
          await Wenku8BrowserSession.instance.enabled()) {
        _sessionSeeded = true;
        return;
      }
      final current = Uri.tryParse(await _webView.currentUrl());
      final expected = Uri.parse(_apiHost);
      if (current == null ||
          current.scheme != 'https' ||
          current.host != expected.host ||
          current.port != expected.port ||
          current.userInfo.isNotEmpty) {
        return;
      }
      final cookieString = await getSessionCookieString();
      if (!_current) return;
      if (cookieString.isNotEmpty) {
        for (final part in cookieString.split('; ')) {
          final equalsAt = part.indexOf('=');
          if (equalsAt <= 0) continue;
          final cookie =
              '${part.substring(0, equalsAt)}=${part.substring(equalsAt + 1)}; '
              'path=/; secure';
          await _webView
              .executeScript(
                'if (location.origin === ${jsonEncode(_apiHost)}) '
                'document.cookie = ${jsonEncode(cookie)}; true;',
              )
              .timeout(const Duration(seconds: 5));
        }
      }
      _sessionSeeded = true;
      if (cookieString.isNotEmpty && _current) {
        await _webView.loadUrl(_entryUrl).timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      _error = '未能加载应用中保存的文库8会话；可在站点内重新登录。';
    } finally {
      _injectingSession = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openPage(String url) async {
    if (!_initialized || !_current || _extractingHome) return;
    ++_pageLoad;
    setState(() {
      _error = null;
      _accessDenied = false;
    });
    try {
      await _webView.loadUrl(url).timeout(const Duration(seconds: 5));
    } catch (_) {
      if (_current) {
        setState(() => _error = '无法打开文库8页面，请检查网络后重试。');
      }
    }
  }

  Future<void> _useLoadedHome() async {
    if (!_initialized ||
        !_current ||
        _injectingSession ||
        _extractingHome ||
        _accessDenied) {
      return;
    }
    final load = _pageLoad;
    bool current() => _current && load == _pageLoad;
    setState(() {
      _error = null;
      _extractingHome = true;
    });
    try {
      if (widget.sessionOnly) {
        final state = await _webView
            .executeScript(Wenku8BrowserSession.pageStateScript)
            .timeout(const Duration(seconds: 5));
        if (!current()) return;
        final authenticated = await Wenku8BrowserSession.instance
            .adoptVisiblePage(
              _apiHost,
              state,
              target: widget.target,
              persistSession: _webView.persistSession,
              isCurrent: current,
            );
        if (!mounted || !current()) return;
        Navigator.of(context).pop<bool>(authenticated);
        return;
      }
      final loadedUrl = await _webView.currentUrl();
      final result = await _webView.executeScript(
        wenku8HomeDomExtractionScript(_apiHost),
      );
      final blocks = parseWenku8HomeWebViewResult(
        result,
        apiHost: _apiHost,
        loadedUrl: loadedUrl,
      );
      await Wenku8BrowserSession.instance.adoptVisiblePage(
        _apiHost,
        await _webView.executeScript(Wenku8BrowserSession.pageStateScript),
        persistSession: _webView.persistSession,
        isCurrent: current,
      );
      if (!mounted || !current()) return;
      Navigator.of(context).pop<List<HomeBlock>>(blocks);
    } catch (error) {
      if (!current()) return;
      final message =
          error is Wenku8BrowserException
              ? error.message
              : error is FormatException
              ? error.message.toString()
              : '未能读取文库8首页，请返回首页并重试。';
      setState(() {
        _error = message;
        _accessDenied = error is Wenku8SiteAccessDenied;
      });
    } finally {
      if (mounted) setState(() => _extractingHome = false);
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_webView.dispose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('文库8站点验证'),
          actions: [
            AppIconButton(
              onPressed:
                  _initialized && !_extractingHome
                      ? () => _openPage('$_apiHost/login.php')
                      : null,
              tooltip: '登录',
              icon: const Icon(Icons.login_rounded),
            ),
            AppIconButton(
              onPressed:
                  _initialized && !_extractingHome
                      ? () => _openPage(_entryUrl)
                      : null,
              tooltip: '重新打开原站页面',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error case final error?)
              if (usesAppleGlass)
                AppleGlassCard(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(error),
                  ),
                )
              else
                MaterialBanner(
                  content: Text(error),
                  actions: [
                    AppButton.text(
                      onPressed: () => setState(() => _error = null),
                      child: const Text('知道了'),
                    ),
                  ],
                ),
            Expanded(
              child:
                  _initialized
                      ? _webView.build()
                      : _error == null
                      ? const CenteredLoadingIndicator()
                      : const SizedBox.shrink(),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _accessDenied
                          ? '当前页面没有可完成的验证。'
                          : widget.sessionOnly
                          ? '请在原站网页内完成验证或登录，再返回重试。'
                          : '网页显示首页书目后，点下方按钮返回。文库8的首页、详情、目录和正文会继续使用该站点会话。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: AppButton.filledIcon(
                        onPressed:
                            !_initialized ||
                                    _injectingSession ||
                                    _extractingHome ||
                                    _accessDenied
                                ? null
                                : _useLoadedHome,
                        icon:
                            _extractingHome
                                ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.check_rounded),
                        label: Text(
                          _extractingHome
                              ? '正在读取…'
                              : widget.sessionOnly
                              ? '验证完成并返回'
                              : '采用网页首页并返回',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
