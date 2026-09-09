import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as windows;

/// Shares the Wenku8 fallback parsers across Android WebView and WebView2.
class WenkuWebView {
  windows.WebviewController? _windows;
  mobile.WebViewController? _mobile;
  final _subscriptions = <StreamSubscription<dynamic>>[];

  Future<void> initialize({
    required VoidCallback onLoaded,
    required void Function(String) onError,
  }) async {
    if (Platform.isWindows) {
      final version = await windows.WebviewController.getWebViewVersion();
      if (version == null) {
        throw StateError('未检测到 Microsoft Edge WebView2 Runtime');
      }
      final controller = _windows = windows.WebviewController();
      await controller.initialize();
      final edgeVersion = RegExp(
        r'\d+\.\d+\.\d+\.\d+',
      ).firstMatch(version)?.group(0);
      if (edgeVersion != null) {
        await controller.setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/${edgeVersion.split('.').first}.0.0.0 Safari/537.36 Edg/$edgeVersion',
        );
      }
      _subscriptions.add(
        controller.loadingState.listen((state) {
          if (state == windows.LoadingState.navigationCompleted) onLoaded();
        }),
      );
      _subscriptions.add(
        controller.onLoadError.listen((error) {
          if (error != windows.WebErrorStatus.WebErrorStatusUnknown &&
              error != windows.WebErrorStatus.WebErrorStatusConnectionAborted &&
              error != windows.WebErrorStatus.WebErrorStatusOperationCanceled) {
            onError('WebView2 加载失败: $error');
          }
        }),
      );
      await controller.setPopupWindowPolicy(
        windows.WebviewPopupWindowPolicy.sameWindow,
      );
      await controller.setBackgroundColor(Colors.transparent);
    } else if (Platform.isAndroid || Platform.isIOS) {
      final controller = _mobile = mobile.WebViewController();
      await controller.setJavaScriptMode(mobile.JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        mobile.NavigationDelegate(
          onPageFinished: (_) => onLoaded(),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              onError('网页加载失败: ${error.description}');
            }
          },
        ),
      );
    } else {
      throw UnsupportedError('当前平台暂不支持网页重试');
    }
  }

  Future<void> loadUrl(String url) async {
    if (_windows != null) {
      await _windows!.loadUrl(url);
    } else {
      await _mobile!.loadRequest(Uri.parse(url));
    }
  }

  Future<dynamic> executeScript(String script) async {
    if (_windows != null) return _windows!.executeScript(script);
    final value = await _mobile!.runJavaScriptReturningResult(script);
    // Android exposes JSON-quoted strings; booleans and numbers are already typed.
    if (Platform.isAndroid && value is String) {
      try {
        return jsonDecode(value);
      } on FormatException {
        return value;
      }
    }
    return value;
  }

  Widget build() =>
      _windows != null
          ? windows.Webview(_windows!, width: 1024, height: 768)
          : mobile.WebViewWidget(controller: _mobile!);

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _windows?.dispose();
  }
}
