import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:wild/src/rust/api/wenku8.dart' show getSessionCookieString;

/// 通过 Windows WebView2 绕过 Cloudflare，执行一次书架操作。
class CfActionLoader extends StatefulWidget {
  final String apiHost;
  final String? actionPath;
  final String? jsAction;
  final String successUrlKeyword;
  final String successBodyKeyword;
  final void Function() onSuccess;
  final void Function(String error) onError;

  const CfActionLoader({
    super.key,
    required this.apiHost,
    this.actionPath,
    this.jsAction,
    required this.successUrlKeyword,
    required this.successBodyKeyword,
    required this.onSuccess,
    required this.onError,
  }) : assert(
         actionPath != null || jsAction != null,
         'actionPath 或 jsAction 必须提供其中一个',
       );

  @override
  State<CfActionLoader> createState() => _CfActionLoaderState();
}

class _CfActionLoaderState extends State<CfActionLoader> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _initialized = false;
  bool _done = false;
  bool _homeLoaded = false;
  bool _handlingNavigation = false;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    _timeout = Timer(const Duration(seconds: 60), () {
      _fail('操作超时，Cloudflare 验证未完成，请重试。');
    });

    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        throw StateError('未检测到 Microsoft Edge WebView2 Runtime');
      }
      await _controller.initialize();
      if (!mounted) return;

      final edgeVersion = RegExp(
        r'\d+\.\d+\.\d+\.\d+',
      ).firstMatch(version)?.group(0);
      if (edgeVersion != null) {
        final chromiumMajor = edgeVersion.split('.').first;
        await _controller.setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/$chromiumMajor.0.0.0 Safari/537.36 '
          'Edg/$edgeVersion',
        );
      }

      _subscriptions.add(
        _controller.loadingState.listen((state) {
          if (state == LoadingState.navigationCompleted) {
            _onNavigationCompleted();
          }
        }),
      );
      _subscriptions.add(
        _controller.onLoadError.listen((error) {
          if (error == WebErrorStatus.WebErrorStatusUnknown ||
              error == WebErrorStatus.WebErrorStatusConnectionAborted ||
              error == WebErrorStatus.WebErrorStatusOperationCanceled) {
            return;
          }
          _fail('WebView2 加载失败: $error');
        }),
      );

      await _controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.sameWindow,
      );
      await _controller.setBackgroundColor(Colors.transparent);
      if (!mounted) return;
      setState(() => _initialized = true);
      await _controller.loadUrl('${widget.apiHost}/');
    } catch (e) {
      _fail('WebView2 初始化失败: $e');
    }
  }

  Future<void> _onNavigationCompleted() async {
    if (_done || _handlingNavigation) return;
    _handlingNavigation = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      if (_done || !mounted) return;

      final challenge =
          await _controller.executeScript(r'''
(function() {
  var title = (document.title || '').toLowerCase();
  return document.getElementById('challenge-form') !== null ||
    title.includes('just a moment') || title.includes('请稍候');
})()
''')
              as bool? ??
          false;
      if (challenge) return;

      final blocked =
          await _controller.executeScript(r'''
(function() {
  var title = (document.title || '').toLowerCase();
  var text = document.body ? document.body.innerText : '';
  return title.includes('blocked') || text.includes('Sorry, you have been blocked');
})()
''')
              as bool? ??
          false;
      if (blocked) {
        _fail('IP 被 Cloudflare 封锁，请更换网络后重试。');
        return;
      }

      if (!_homeLoaded) {
        _homeLoaded = true;
        await _injectCookies();
        if (_done) return;

        if (widget.jsAction != null) {
          await _controller.executeScript(widget.jsAction!);
        } else {
          await _controller.loadUrl('${widget.apiHost}${widget.actionPath}');
        }
        return;
      }

      final url =
          await _controller.executeScript('location.href') as String? ?? '';
      if (url.contains(widget.successUrlKeyword)) {
        _succeed();
        return;
      }

      final body =
          await _controller.executeScript(
                'document.body ? document.body.innerText : ""',
              )
              as String? ??
          '';
      if (body.contains(widget.successBodyKeyword)) {
        _succeed();
        return;
      }

      final preview = body.length > 200 ? body.substring(0, 200) : body;
      _fail('操作失败: $preview');
    } catch (e) {
      _fail('解析操作结果失败: $e');
    } finally {
      _handlingNavigation = false;
    }
  }

  Future<void> _injectCookies() async {
    try {
      final cookieStr = await getSessionCookieString();
      for (final part in cookieStr.split('; ')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final cookie =
            '${part.substring(0, eq)}=${part.substring(eq + 1)}; '
            'path=/; domain=.wenku8.net';
        await _controller.executeScript(
          'document.cookie = ${jsonEncode(cookie)};',
        );
      }
    } catch (e) {
      _fail('注入登录信息失败: $e');
    }
  }

  void _succeed() {
    if (_done) return;
    _done = true;
    _timeout?.cancel();
    widget.onSuccess();
  }

  void _fail(String message) {
    if (_done) return;
    _done = true;
    _timeout?.cancel();
    widget.onError(message);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    if (_initialized) unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (_initialized)
          Positioned(
            left: -1100,
            top: 0,
            width: 1024,
            height: 768,
            child: Webview(_controller, width: 1024, height: 768),
          ),
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                '正在处理，请稍候...',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
