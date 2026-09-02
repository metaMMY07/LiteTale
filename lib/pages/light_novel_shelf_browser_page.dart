import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:wild/services/light_novel_shelf_theme.dart';

/// Keeps the optional LightNovelShelf catalogue separate from Wenku8's account.
/// Any authentication takes place on LightNovelShelf's own website.
class LightNovelShelfBrowserPage extends StatefulWidget {
  const LightNovelShelfBrowserPage({
    super.key,
    required this.initialUrl,
    this.title = '轻书架',
  });

  final String initialUrl;
  final String title;

  @override
  State<LightNovelShelfBrowserPage> createState() =>
      _LightNovelShelfBrowserPageState();
}

class _LightNovelShelfBrowserPageState
    extends State<LightNovelShelfBrowserPage> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _initialized = false;
  bool _loading = true;
  bool _canGoBack = false;
  ThemeData? _theme;
  Future<void> _themeWork = Future.value();
  ScriptID? _themeScriptId;
  String? _installedThemeScript;
  String? _error;
  late String _currentUrl = widget.initialUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _theme = Theme.of(context);
    if (_initialized) unawaited(_updateTheme());
  }

  Future<void> _updateTheme() {
    final theme = _theme;
    if (theme == null) return Future.value();
    // Serialize updates so a previous theme cannot finish after a newer one.
    _themeWork = _themeWork.then((_) async {
      if (!mounted || !_initialized) return;
      try {
        await _controller.setBackgroundColor(theme.scaffoldBackgroundColor);
        final script = LightNovelShelfTheme.script(theme);
        if (_installedThemeScript != script) {
          final previous = _themeScriptId;
          _themeScriptId = await _controller
              .addScriptToExecuteOnDocumentCreated(script);
          if (previous != null) {
            await _controller.removeScriptToExecuteOnDocumentCreated(previous);
          }
          _installedThemeScript = script;
        }
        if (mounted) await _controller.executeScript(script);
      } catch (_) {
        // A skin failure must never block the original website or login.
      }
    });
    return _themeWork;
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      if (!mounted) {
        await _controller.dispose();
        return;
      }
      _initialized = true;

      // Expose only bundled public fonts, never the app's data/profile folder.
      final fonts = Directory.fromUri(
        File(
          Platform.resolvedExecutable,
        ).parent.uri.resolve('data/flutter_assets/lib/assets/fonts/'),
      );
      if (await fonts.exists()) {
        try {
          await _controller.addVirtualHostNameMapping(
            LightNovelShelfTheme.fontHost,
            fonts.path,
            WebviewHostResourceAccessKind.allow,
          );
        } catch (_) {
          // System fonts remain a readable fallback on older WebView runtimes.
        }
      }
      await _updateTheme();
      if (!mounted) return;

      _subscriptions.add(
        _controller.loadingState.listen((state) {
          if (!mounted) return;
          setState(() {
            _loading = state != LoadingState.navigationCompleted;
            if (_loading) _error = null;
          });
          if (state == LoadingState.navigationCompleted) {
            unawaited(_updateTheme());
          }
        }),
      );
      _subscriptions.add(_controller.url.listen((url) => _currentUrl = url));
      _subscriptions.add(
        _controller.historyChanged.listen((history) {
          if (mounted) setState(() => _canGoBack = history.canGoBack);
        }),
      );
      _subscriptions.add(
        _controller.onLoadError.listen((error) {
          if (error == WebErrorStatus.WebErrorStatusUnknown ||
              error == WebErrorStatus.WebErrorStatusConnectionAborted ||
              error == WebErrorStatus.WebErrorStatusOperationCanceled) {
            return;
          }
          _showError('页面暂时无法加载，请重试或在浏览器中打开。');
        }),
      );
      await _controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.sameWindow,
      );
      if (!mounted) return;
      setState(() {});
      await _controller.loadUrl(widget.initialUrl);
    } catch (_) {
      _showError('内置浏览器暂不可用，可在浏览器中打开轻书架。');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  Future<void> _openExternal() async {
    try {
      final opened = await launchUrl(
        Uri.parse(_currentUrl),
        mode: LaunchMode.externalApplication,
      );
      if (opened || !mounted) return;
    } catch (_) {
      if (!mounted) return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，请稍后重试')));
  }

  Future<void> _reload() async {
    if (!_initialized) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      await _controller.reload();
    } catch (_) {
      _showError('页面暂时无法加载，请重试或在浏览器中打开。');
    }
  }

  Future<void> _back() async {
    if (_initialized && _canGoBack) {
      try {
        await _controller.goBack();
      } catch (_) {
        if (mounted) Navigator.of(context).maybePop();
      }
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_initialized) unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _back),
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_canGoBack)
            IconButton(
              tooltip: '返回 novels',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          if (_initialized)
            IconButton(
              tooltip: '刷新',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: '在浏览器中打开',
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_browser),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child:
                _error != null
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            TextButton(
                              onPressed: _openExternal,
                              child: const Text('在浏览器中打开'),
                            ),
                          ],
                        ),
                      ),
                    )
                    : _initialized
                    ? LayoutBuilder(
                      builder:
                          (context, constraints) => Webview(
                            _controller,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                          ),
                    )
                    : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
