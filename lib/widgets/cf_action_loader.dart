import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wild/src/rust/api/wenku8.dart' show getSessionCookieString;

/// 用 WKWebView 繞過 Cloudflare，執行單次動作（GET 或 POST form 提交）
class CfActionLoader extends StatefulWidget {
  final String apiHost;
  /// GET 模式：提供相對路徑，例如 /modules/article/addbookcase.php?bid=123
  final String? actionPath;
  /// POST 模式：在 cookies 注入後執行的 JS（建立 form 並 submit）
  final String? jsAction;
  final String successUrlKeyword; // URL 包含此字串視為成功
  final String successBodyKeyword; // Body 包含此字串視為成功
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
  }) : assert(actionPath != null || jsAction != null, 'actionPath 或 jsAction 必須提供其中一個');

  @override
  State<CfActionLoader> createState() => _CfActionLoaderState();
}

class _CfActionLoaderState extends State<CfActionLoader> {
  late final WebViewController _controller;
  bool _done = false;
  bool _homeLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: _onPageFinished,
        onWebResourceError: (err) {
          if (!_done) {
            _done = true;
            widget.onError('WebView 載入失敗: ${err.description}');
          }
        },
      ))
      ..loadRequest(Uri.parse('${widget.apiHost}/'));
  }

  Future<void> _onPageFinished(String url) async {
    if (_done) return;
    await Future.delayed(const Duration(milliseconds: 1000));
    if (_done) return;

    if (!_homeLoaded) {
      // 確認 CF challenge 已通過
      final isCfChallenge = await _controller.runJavaScriptReturningResult(
        'document.getElementById("challenge-form") !== null ? "yes" : "no"',
      );
      if (isCfChallenge.toString().contains('yes')) return;

      _homeLoaded = true;

      // 注入 session cookies
      try {
        final cookieStr = await getSessionCookieString();
        if (cookieStr.isNotEmpty) {
          for (final part in cookieStr.split('; ')) {
            final eq = part.indexOf('=');
            if (eq > 0) {
              final name = part.substring(0, eq);
              final value = part.substring(eq + 1);
              await _controller.runJavaScript(
                'document.cookie = "$name=$value; path=/; domain=.wenku8.net";',
              );
            }
          }
        }
      } catch (_) {}

      if (widget.jsAction != null) {
        // POST 模式：用 JS 提交 form
        await _controller.runJavaScript(widget.jsAction!);
      } else {
        // GET 模式：直接導航
        await _controller.loadRequest(Uri.parse(
          '${widget.apiHost}${widget.actionPath}',
        ));
      }
      return;
    }

    // 動作頁面載入完畢 → 判斷成功/失敗
    // 若 URL 包含成功關鍵字（例如跳到 bookcase.php）
    if (url.contains(widget.successUrlKeyword)) {
      _done = true;
      widget.onSuccess();
      return;
    }

    // 若 body 包含成功關鍵字
    try {
      final bodyText = await _controller.runJavaScriptReturningResult(
        'document.body ? document.body.innerText : ""',
      );
      final text = bodyText.toString();
      if (text.contains(widget.successBodyKeyword)) {
        _done = true;
        widget.onSuccess();
        return;
      }
      // 回報錯誤（擷取頁面文字前 200 字）
      if (!_done) {
        _done = true;
        final preview = text.length > 200 ? text.substring(0, 200) : text;
        widget.onError('操作失敗: $preview');
      }
    } catch (e) {
      if (!_done) {
        _done = true;
        widget.onError('解析結果失敗: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // WebView 隱藏在角落，不顯示給使用者
        Positioned(
          left: 0, top: 0, width: 1, height: 1,
          child: WebViewWidget(controller: _controller),
        ),
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在處理，請稍候...', style: TextStyle(fontSize: 14, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }
}
