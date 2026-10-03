import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/sources/source_api.dart' show getSessionCookieString;
import 'package:wild/src/rust/wenku8/models.dart' show HomeBlock;
import 'package:wild/utils/wenku8_home_dom.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';
import 'package:wild/widgets/wenku_webview.dart';

/// Visible, ordinary site verification/login. Cookies stay in the WebView.
class Wenku8VerificationPage extends StatefulWidget {
  const Wenku8VerificationPage({
    super.key,
    required this.apiHost,
    this.sessionOnly = false,
    this.startAtLogin = false,
  });

  final String apiHost;
  final bool sessionOnly;
  final bool startAtLogin;

  @override
  State<Wenku8VerificationPage> createState() => _Wenku8VerificationPageState();
}

class _Wenku8VerificationPageState extends State<Wenku8VerificationPage> {
  final WenkuWebView _webView = WenkuWebView();
  late final String _apiHost;
  bool _initialized = false;
  bool _injectingSession = false;
  bool _sessionSeeded = false;
  bool _extractingHome = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final normalized = normalizeWenku8Host(widget.apiHost);
    _apiHost = normalized.isEmpty ? defaultWenku8Host : normalized;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _webView.initialize(
        onLoaded: _seedSessionCookies,
        allowMainFrameNavigation:
            (url) =>
                url == 'about:blank' ||
                Wenku8BrowserSession.sameOrigin(url, _apiHost),
        onError: (_) {
          if (mounted) {
            setState(() {
              _error = '无法打开文库8站点，请检查网络后重试。';
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _initialized = true);
      await _webView.loadUrl(
        widget.startAtLogin ? '$_apiHost/login.php' : '$_apiHost/',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '文库8网页组件未能启动，请返回后重试。';
      });
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
      if (cookieString.isNotEmpty) {
        for (final part in cookieString.split('; ')) {
          final equalsAt = part.indexOf('=');
          if (equalsAt <= 0) continue;
          final cookie =
              '${part.substring(0, equalsAt)}=${part.substring(equalsAt + 1)}; '
              'path=/; secure';
          await _webView.executeScript(
            'document.cookie = ${jsonEncode(cookie)};',
          );
        }
      }
      _sessionSeeded = true;
      if (cookieString.isNotEmpty) await _webView.loadUrl('$_apiHost/');
    } catch (_) {
      _error = '未能加载应用中保存的文库8会话；可在站点内重新登录。';
    } finally {
      _injectingSession = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openLoginPage() async {
    setState(() => _error = null);
    try {
      await _webView.loadUrl('$_apiHost/login.php');
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法打开文库8登录页，请检查网络后重试。');
      }
    }
  }

  Future<void> _openHomePage() async {
    setState(() => _error = null);
    try {
      await _webView.loadUrl('$_apiHost/');
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法打开文库8首页，请检查网络后重试。');
      }
    }
  }

  Future<void> _useLoadedHome() async {
    if (!_initialized || _extractingHome) return;
    setState(() {
      _error = null;
      _extractingHome = true;
    });
    try {
      if (widget.sessionOnly) {
        final state = await _webView.executeScript(
          Wenku8BrowserSession.pageStateScript,
        );
        final authenticated = await Wenku8BrowserSession.instance
            .adoptVisiblePage(
              _apiHost,
              state,
              persistSession: _webView.persistSession,
            );
        if (mounted) Navigator.of(context).pop<bool>(authenticated);
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
      );
      if (!mounted) return;
      Navigator.of(context).pop<List<HomeBlock>>(blocks);
    } catch (error) {
      if (!mounted) return;
      final message =
          error is Wenku8BrowserException
              ? error.message
              : error is FormatException
              ? error.message.toString()
              : '未能读取文库8首页，请返回首页并重试。';
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _extractingHome = false);
    }
  }

  @override
  void dispose() {
    if (_initialized) unawaited(_webView.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文库8站点验证'),
        actions: [
          IconButton(
            onPressed: _initialized ? _openLoginPage : null,
            tooltip: '登录',
            icon: const Icon(Icons.login_rounded),
          ),
          IconButton(
            onPressed: _initialized ? _openHomePage : null,
            tooltip: '文库8首页',
            icon: const Icon(Icons.home_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error case final error?)
            MaterialBanner(
              content: Text(error),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('知道了'),
                ),
              ],
            ),
          Expanded(
            child:
                _initialized
                    ? _webView.build()
                    : const CenteredLoadingIndicator(),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.sessionOnly
                        ? '在此完成站点验证或登录，再点下方按钮返回。已验证的站点会话会继续用于文库8阅读。'
                        : '网页显示首页书目后，点下方按钮返回。文库8的首页、详情、目录和正文会继续使用该站点会话。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _extractingHome ? null : _useLoadedHome,
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
    );
  }
}
