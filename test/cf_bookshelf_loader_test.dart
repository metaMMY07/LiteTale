import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/cf_bookshelf_loader.dart';
import 'package:wild/widgets/wenku_webview.dart';

class _Browser extends WenkuWebView {
  int starts = 0, disposals = 0;
  final loads = <String>[];
  Completer<void>? initialization;

  @override
  Future<void> initialize({
    required VoidCallback onLoaded,
    required void Function(String) onError,
    bool Function(String)? allowMainFrameNavigation,
    bool normalBrowserUserAgent = false,
    bool enableVerificationCookies = false,
  }) async {
    starts++;
    if (initialization != null) await initialization!.future;
  }

  @override
  Future<void> loadUrl(String url) async => loads.add(url);
  @override
  Widget build() => const SizedBox.shrink();
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  Widget loader(_Browser browser, GlobalKey<CfBookshelfLoaderState> key) =>
      MaterialApp(
        home: CfBookshelfLoader(
          key: key,
          apiHost: 'https://www.wenku8.net',
          webView: browser,
          onSuccess: (_, __) {},
          onError: (_) {},
        ),
      );

  testWidgets(
    'an unused shelf tab creates no browser or competing home request',
    (tester) async {
      final browser = _Browser(), key = GlobalKey<CfBookshelfLoaderState>();
      await tester.pumpWidget(loader(browser, key));
      await tester.pump(const Duration(seconds: 2));
      expect(browser.starts, 0);
      expect(browser.loads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(browser.disposals, 0);
    },
  );

  testWidgets(
    'fallback still initializes once and begins its normal home visit',
    (tester) async {
      final browser = _Browser(), key = GlobalKey<CfBookshelfLoaderState>();
      await tester.pumpWidget(loader(browser, key));
      key.currentState!.reload();
      await tester.pump();
      expect(browser.starts, 1);
      expect(browser.loads, ['https://www.wenku8.net/']);
      key.currentState!.reload();
      await tester.pump();
      expect(browser.starts, 1);
      await tester.pumpWidget(const SizedBox());
      expect(browser.disposals, 1);
    },
  );

  testWidgets('leaving during initialization releases the late browser', (
    tester,
  ) async {
    final browser = _Browser()..initialization = Completer<void>();
    final key = GlobalKey<CfBookshelfLoaderState>();
    await tester.pumpWidget(loader(browser, key));
    key.currentState!.reload();
    await tester.pumpWidget(const SizedBox());
    browser.initialization!.complete();
    await tester.pump();
    expect(browser.disposals, 1);
    expect(browser.loads, isEmpty);
  });
}
