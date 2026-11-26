import 'dart:convert';

/// Submit the site's actual search form. GBK encoding, hidden fields and the
/// /so.php redirect remain in Chromium; no login form or account data is read.
String wenku8SearchSubmitScript(String host, String key, String type) {
  if (key.trim().isEmpty ||
      key.length > 100 ||
      !const {'articlename', 'author'}.contains(type)) {
    throw const FormatException('文库8搜索条件无效。');
  }
  return '''
(function(expectedOrigin, key, type) {
  // litetale-search-submit
  if (location.origin !== expectedOrigin) return false;
  var form = Array.from(document.forms).find(function(f) {
    return f.querySelector('[name="searchkey"]') && f.querySelector('[name="searchtype"]') &&
      !f.querySelector('input[type="password"]');
  });
  if (!form) return false;
  var action = new URL(form.action, location.href);
  if (action.origin !== expectedOrigin || action.username || action.password || action.hash ||
      action.search || !['/so.php', '/modules/article/search.php'].includes(action.pathname) ||
      !['post', 'get'].includes(form.method.toLowerCase())) return false;
  form.querySelector('[name="searchkey"]').value = key;
  var types = form.querySelector('[name="searchtype"]');
  types.value = type;
  if (types.value !== type) return false;
  form.acceptCharset = 'GBK';
  window.__liteTaleNavigating = true;
  form.submit();
  return true;
})(${jsonEncode(host)}, ${jsonEncode(key)}, ${jsonEncode(type)})
''';
}

/// Follow only the matching query's real pagination link. Do not manufacture
/// a GET with extra fields: the site filters those differently from its form.
String wenku8SearchPageScript(String host, int page) {
  return _searchLinkScript(host, page, navigate: true);
}

/// Keep only the next public URL, never the result DOM or account information.
String wenku8SearchNextPageUrlScript(String host, int page) {
  return _searchLinkScript(host, page, navigate: false);
}

String _searchLinkScript(String host, int page, {required bool navigate}) {
  if (page < 2 || page > 100000) throw const FormatException('搜索页码无效。');
  return '''
(function(expectedOrigin, page) {
  // ${navigate ? 'litetale-search-page' : 'litetale-search-next-url'}
  if (location.origin !== expectedOrigin || location.pathname !== '/modules/article/search.php') return false;
  var current = new URL(location.href);
  function rawKey(url) { return (/(?:^|&)searchkey=([^&]*)/.exec(url.search.slice(1)) || [])[1]; }
  var key = rawKey(current);
  var link = Array.from(document.querySelectorAll('#pagelink a[href]')).find(function(a) {
    var u = new URL(a.href, location.href);
    return u.origin === expectedOrigin && u.pathname === current.pathname &&
      !u.username && !u.password && !u.hash && key && rawKey(u) === key &&
      u.searchParams.get('searchtype') === current.searchParams.get('searchtype') &&
      u.searchParams.get('page') === String(page) &&
      ['searchtype','searchkey','page'].every(function(k) { return u.searchParams.getAll(k).length === 1; }) &&
      u.searchParams.getAll('charset').length <= 1 &&
      (!u.searchParams.has('charset') || u.searchParams.get('charset').toLowerCase() === 'gbk') &&
      Array.from(u.searchParams.keys()).every(function(k) { return ['searchtype','searchkey','page','charset'].includes(k); });
  });
  if (!link) return ${navigate ? 'false' : "''"};
  ${navigate ? 'window.__liteTaleNavigating = true; link.click(); return true;' : 'return link.href;'}
})(${jsonEncode(host)}, $page)
''';
}

/// Recognize only the site's explicit search-interval notice. No body text
/// leaves the WebView, and a normal book grid can never trigger a retry.
String wenku8SearchIntervalScript(String host) => r'''
(function(expectedOrigin) {
  // litetale-search-interval
  if (location.origin !== expectedOrigin || location.pathname !== '/modules/article/search.php' ||
      document.querySelector('table.grid')) return 0;
  var content = document.querySelector('#content') || document.body;
  var text = (content ? content.textContent : '').slice(0, 8000);
  var match = /(?:搜索|搜尋)[\s\S]{0,50}(?:间隔|間隔)[^0-9]{0,30}([0-9]{1,2})\s*秒/.exec(text);
  return match ? Number(match[1]) : 0;
})(EXPECTED_HOST)
'''.replaceFirst('EXPECTED_HOST', jsonEncode(host));
