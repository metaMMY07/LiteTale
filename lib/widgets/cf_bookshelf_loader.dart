import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wild/src/rust/api/wenku8.dart' show getSessionCookieString;
import 'package:wild/src/rust/wenku8/models.dart';

/// 長駐背景的 WebView 書架載入器。
/// 透過 GlobalKey<CfBookshelfLoaderState> 呼叫 reload() 觸發載入。
/// WebView 永久存活，CF clearance 一次建立後可重複使用。
class CfBookshelfLoader extends StatefulWidget {
  final String apiHost;
  final void Function(List<Bookcase> bookcases, Map<String, BookcaseDto> contents)? onPartialData;
  final void Function(List<Bookcase> bookcases, Map<String, BookcaseDto> contents) onSuccess;
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
  late final WebViewController _controller;

  // CF clearance 狀態 —— 跨 reload() 保留
  bool _homeLoaded = false;
  bool _cookiesInjected = false;

  // 每次 reload() 重置的狀態
  bool _active = false;
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
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: _onPageFinished,
        onWebResourceError: (err) {
          if (_active) widget.onError('WebView 載入失敗: ${err.description}');
        },
      ));
    // 預熱：靜默載入首頁，提前取得 CF clearance
    _controller.loadRequest(Uri.parse('${widget.apiHost}/'));
  }

  /// 觸發（重新）載入書架資料
  void reload() {
    _active = true;
    _bookcases = [];
    _contents.clear();

    if (_homeLoaded) {
      // 已有 CF clearance → 直接跳到書架頁
      _navigateToBookcase();
    } else {
      // 還沒完成首頁預熱 → 等 _onPageFinished 處理
    }
  }

  Future<void> _navigateToBookcase() async {
    if (!_cookiesInjected) {
      await _injectCookies();
    }
    await _controller.loadRequest(Uri.parse(
      '${widget.apiHost}/modules/article/bookcase.php',
    ));
  }

  Future<void> _injectCookies() async {
    try {
      final cookieStr = await getSessionCookieString();
      if (cookieStr.isNotEmpty) {
        for (final part in cookieStr.split('; ')) {
          final eq = part.indexOf('=');
          if (eq > 0) {
            final name = part.substring(0, eq);
            final value = part.substring(eq + 1);
            await _controller.runJavaScript(
              'document.cookie = "${name}=${value}; path=/; domain=.wenku8.net";',
            );
          }
        }
      }
      _cookiesInjected = true;
    } catch (_) {}
  }

  Future<void> _onPageFinished(String url) async {
    await Future.delayed(const Duration(milliseconds: 1200));

    if (!_homeLoaded) {
      // 首頁預熱階段
      final blocked = await _controller.runJavaScriptReturningResult(
        'document.title.toLowerCase().includes("blocked") || '
        '(document.body ? document.body.innerText.includes("Sorry, you have been blocked") : false) '
        '? "yes" : "no"',
      );
      if (blocked.toString().contains('yes')) {
        if (_active) widget.onError('IP 被 Cloudflare 封鎖，請嘗試更換網路或使用 VPN');
        _active = false;
        return;
      }
      final isCfChallenge = await _controller.runJavaScriptReturningResult(
        'document.getElementById("challenge-form") !== null ? "yes" : "no"',
      );
      if (isCfChallenge.toString().contains('yes')) return; // 等挑戰完成

      _homeLoaded = true;

      if (_active) {
        // reload() 已呼叫，繼續載入書架
        await _navigateToBookcase();
      }
      // 否則只是預熱完成，靜默等待
      return;
    }

    // 書架頁階段（_active 才處理）
    if (!_active) return;

    final check = await _controller.runJavaScriptReturningResult(
      'document.querySelector(\'select[name="classlist"]\') ? "ready" : "not_ready"',
    );
    if (check.toString().contains('not_ready')) {
      // 可能被重定向到登入頁或其他頁 → cookies 可能過期，重注入
      _cookiesInjected = false;
      await _navigateToBookcase();
      return;
    }

    if (_bookcases.isEmpty) {
      await _loadBookcaseList();
    } else {
      await _loadCurrentCaseBooks(url);
    }
  }

  Future<void> _loadBookcaseList() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(_jsGetBookcases);
      final json = _stripJsonString(raw.toString());
      final list = jsonDecode(json) as List;
      _bookcases = list.map((e) => Bookcase(id: e['id'], title: e['title'])).toList();
      if (_bookcases.isEmpty) {
        _active = false;
        widget.onSuccess([], {});
        return;
      }
      await _extractBooksAndContinue(_bookcases[0].id);
    } catch (e) {
      if (_active) widget.onError('解析書架分類失敗: $e');
    }
  }

  Future<void> _loadCurrentCaseBooks(String url) async {
    final caseId = Uri.tryParse(url)?.queryParameters['classid'];
    if (caseId != null) await _extractBooksAndContinue(caseId);
  }

  Future<void> _extractBooksAndContinue(String caseId) async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(_jsGetBooks);
      final json = _stripJsonString(raw.toString());
      final data = jsonDecode(json) as Map;
      final items = (data['items'] as List).map((e) => BookcaseItem(
        aid: e['aid'] ?? '',
        bid: e['bid'] ?? '',
        title: e['title'] ?? '',
        author: e['author'] ?? '',
        cid: e['cid'] ?? '',
        chapterName: e['chapterName'] ?? '',
      )).toList();
      _contents[caseId] = BookcaseDto(items: items, tip: data['tip'] ?? '');

      // 每個分類載好就即時回呼
      widget.onPartialData?.call(List.from(_bookcases), Map.from(_contents));

      final pending = _bookcases
          .map((b) => b.id)
          .where((id) => id != _bookcases[0].id && !_contents.containsKey(id))
          .toList();

      if (pending.isEmpty) {
        _active = false;
        widget.onSuccess(List.from(_bookcases), Map.from(_contents));
      } else {
        await _controller.loadRequest(Uri.parse(
          '${widget.apiHost}/modules/article/bookcase.php?classid=${pending.first}',
        ));
      }
    } catch (e) {
      if (_active) widget.onError('解析書本列表失敗: $e');
    }
  }

  String _stripJsonString(String s) {
    if (s.startsWith('"') && s.endsWith('"')) return jsonDecode(s) as String;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    // 永遠在 widget tree 中，但只佔 1×1px
    return WebViewWidget(controller: _controller);
  }
}
