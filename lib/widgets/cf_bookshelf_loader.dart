import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:wild/src/rust/api/wenku8.dart' show getSessionCookieString;
import 'package:wild/src/rust/wenku8/models.dart';

/// Windows WebView2 书架加载器。
///
/// wenku8 的书架接口会被 Cloudflare 拦截，普通 HTTP 请求拿到 403。
/// 这个组件用真正的 Edge WebView2 完成验证，再从已登录的页面解析书架。
class CfBookshelfLoader extends StatefulWidget {
  final String apiHost;
  final void Function(
    List<Bookcase> bookcases,
    Map<String, BookcaseDto> contents,
  )?
  onPartialData;
  final void Function(
    List<Bookcase> bookcases,
    Map<String, BookcaseDto> contents,
  )
  onSuccess;
  final void Function(String error) onError;

  const CfBookshelfLoader({
    super.key,
    required this.apiHost,
    this.onPartialData,
    required this.onSuccess,
    required this.onError,
  });

  @override
  CfBookshelfLoaderState createState() => CfBookshelfLoaderState();
}

class CfBookshelfLoaderState extends State<CfBookshelfLoader> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool _initialized = false;
  String? _initializationError;
  bool _homeLoaded = false;
  bool _cookiesInjected = false;
  bool _active = false;
  bool _handlingNavigation = false;
  bool _navigationPending = false;
  int _loginRetries = 0;
  Timer? _timeout;

  List<Bookcase> _bookcases = [];
  final Map<String, BookcaseDto> _contents = {};

  static const _jsGetBookcases = r'''
(function() {
  var opts = document.querySelectorAll('select[name="classlist"] option');
  var result = [];
  opts.forEach(function(opt) {
    var id = opt.value || '';
    var title = (opt.textContent || opt.innerText || '').trim();
    if (id) result.push({id: id, title: title});
  });
  return JSON.stringify(result);
})()
''';

  static const _jsGetBooks = r'''
(function() {
  var checkboxes = document.querySelectorAll('td.odd > input[type="checkbox"]');
  var items = [];
  function getParam(href, key) {
    try { return new URL(href, location.href).searchParams.get(key) || ''; }
    catch(e) { return ''; }
  }
  checkboxes.forEach(function(cb) {
    try {
      var row = cb.parentElement.parentElement;
      var tds = Array.from(row.getElementsByTagName('td'));
      var idx = tds.indexOf(cb.parentElement);
      if (idx < 0 || idx + 3 >= tds.length) return;
      var titleA = tds[idx+1].querySelector('a');
      var authorA = tds[idx+2].querySelector('a');
      var chapterA = tds[idx+3].querySelector('a');
      if (!titleA || !authorA || !chapterA) return;
      items.push({
        aid: getParam(titleA.getAttribute('href'), 'aid'),
        bid: getParam(titleA.getAttribute('href'), 'bid'),
        title: (titleA.textContent || '').trim(),
        author: (authorA.textContent || '').trim(),
        cid: getParam(chapterA.getAttribute('href'), 'cid'),
        chapterName: (chapterA.textContent || '').trim()
      });
    } catch(e) {}
  });
  var tipMatch = (document.body ? document.body.innerHTML : '').match(/您的书架可收藏 \d+ 本，已收藏 \d+ 本/);
  return JSON.stringify({items: items, tip: tipMatch ? tipMatch[0] : ''});
})()
''';

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  Future<void> _initializeWebView() async {
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
            _queueNavigationCompleted();
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
          if (_active) _fail('WebView2 加载失败: $error');
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
      _initializationError = 'WebView2 初始化失败: $e';
      if (_active) _fail(_initializationError!);
    }
  }

  /// 触发（重新）加载书架资料。
  void reload() {
    _active = true;
    _bookcases = [];
    _contents.clear();
    _loginRetries = 0;
    _startTimeout();

    if (_initializationError != null) {
      _fail(_initializationError!);
    } else if (!_initialized) {
      // 初始化完成后，首页导航事件会继续流程。
    } else if (_homeLoaded) {
      _navigateToBookcase();
    } else {
      _controller.loadUrl('${widget.apiHost}/');
    }
  }

  void _startTimeout() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 60), () {
      if (_active) {
        _fail('书架加载超时。Cloudflare 验证未完成，请下拉重试或更换网络。');
      }
    });
  }

  void _queueNavigationCompleted() {
    if (_handlingNavigation) {
      _navigationPending = true;
      return;
    }
    _drainNavigationEvents();
  }

  Future<void> _drainNavigationEvents() async {
    _handlingNavigation = true;
    do {
      _navigationPending = false;
      await _onNavigationCompleted();
    } while (_navigationPending && mounted);
    _handlingNavigation = false;
  }

  Future<void> _navigateToBookcase() async {
    if (!_active || !_initialized) return;
    if (!_cookiesInjected) await _injectCookies();
    if (!_active) return;
    await _controller.loadUrl(
      '${widget.apiHost}/modules/article/bookcase.php?classid=0',
    );
  }

  Future<void> _injectCookies() async {
    try {
      final cookieStr = await getSessionCookieString();
      if (cookieStr.isNotEmpty) {
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
      }
      _cookiesInjected = true;
    } catch (e) {
      _fail('注入登录信息失败: $e');
    }
  }

  Future<void> _onNavigationCompleted() async {
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    if (!mounted || !_initialized) return;

    try {
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
        if (_active) _fail('IP 被 Cloudflare 封锁，请更换网络后下拉重试。');
        return;
      }

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

      if (!_homeLoaded) {
        _homeLoaded = true;
        if (_active) await _navigateToBookcase();
        return;
      }

      if (!_active) return;

      final ready =
          await _controller.executeScript(
                'document.querySelector(\'select[name="classlist"]\') !== null',
              )
              as bool? ??
          false;
      if (!ready) {
        if (_loginRetries >= 1) {
          _fail('书架页面未识别登录状态，请在“我的”页面重新登录后重试。');
          return;
        }
        _loginRetries++;
        _cookiesInjected = false;
        await _navigateToBookcase();
        return;
      }

      if (_bookcases.isEmpty) {
        await _loadBookcaseList();
      } else {
        final url = await _controller.executeScript('location.href') as String?;
        await _loadCurrentCaseBooks(url ?? '');
      }
    } catch (e) {
      if (_active) _fail('解析书架页面失败: $e');
    }
  }

  Future<void> _loadBookcaseList() async {
    final raw = await _controller.executeScript(_jsGetBookcases);
    final list = jsonDecode(raw as String) as List<dynamic>;
    _bookcases =
        list
            .map(
              (e) => Bookcase(
                id: (e as Map<String, dynamic>)['id'] as String,
                title: e['title'] as String,
              ),
            )
            .toList();
    if (_bookcases.isEmpty) {
      _complete();
      widget.onSuccess(const [], const {});
      return;
    }
    await _extractBooksAndContinue(_bookcases.first.id);
  }

  Future<void> _loadCurrentCaseBooks(String url) async {
    final caseId = Uri.tryParse(url)?.queryParameters['classid'];
    if (caseId != null) await _extractBooksAndContinue(caseId);
  }

  Future<void> _extractBooksAndContinue(String caseId) async {
    final raw = await _controller.executeScript(_jsGetBooks);
    final data = jsonDecode(raw as String) as Map<String, dynamic>;
    final items =
        (data['items'] as List<dynamic>).map((e) {
          final item = e as Map<String, dynamic>;
          return BookcaseItem(
            aid: item['aid'] as String? ?? '',
            bid: item['bid'] as String? ?? '',
            title: item['title'] as String? ?? '',
            author: item['author'] as String? ?? '',
            cid: item['cid'] as String? ?? '',
            chapterName: item['chapterName'] as String? ?? '',
          );
        }).toList();
    _contents[caseId] = BookcaseDto(
      items: items,
      tip: data['tip'] as String? ?? '',
    );

    widget.onPartialData?.call(List.of(_bookcases), Map.of(_contents));

    final pending =
        _bookcases
            .map((bookcase) => bookcase.id)
            .where((id) => !_contents.containsKey(id))
            .toList();
    if (pending.isEmpty) {
      _complete();
      widget.onSuccess(List.of(_bookcases), Map.of(_contents));
    } else {
      await _controller.loadUrl(
        '${widget.apiHost}/modules/article/bookcase.php'
        '?classid=${Uri.encodeQueryComponent(pending.first)}',
      );
    }
  }

  void _complete() {
    _active = false;
    _timeout?.cancel();
  }

  void _fail(String message) {
    if (!_active) return;
    _complete();
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
    if (!_initialized) return const SizedBox.shrink();
    return Webview(_controller, width: 1024, height: 768);
  }
}
