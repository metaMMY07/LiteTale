import 'dart:convert';

import 'package:wild/services/wenku8_host.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const int _maxPayloadLength = 512 * 1024;
const int _maxIntroLength = 48 * 1024;
const int _maxChapterLength = 384 * 1024;
const int _maxUrlLength = 2048;
const int _maxVolumes = 200;
const int _maxChapters = 10000;
const int _maxTagGroups = 128;
const int _maxTagsPerGroup = 500;
const int _maxRecords = 500;

/// Builds a synchronous, same-document extraction script for a Wenku8 read
/// page. The script returns only fields consumed by the existing Rust models;
/// it never serializes HTML, body text, forms, account controls, or cookies.
String wenku8ReadDomExtractionScript(
  String apiHost, {
  required String kind,
  String? aid,
}) {
  if (!const {'detail', 'reader', 'chapter', 'tags', 'list'}.contains(kind)) {
    throw const FormatException('不支持的文库8页面类型。');
  }
  final expectedHost = jsonEncode(Uri.parse(normalizeWenku8Host(apiHost)).host);
  final expectedAid = jsonEncode(aid ?? '');
  final expectedKind = jsonEncode(kind);
  return r'''
(function(expectedHost, expectedKind, expectedAid) {
  var payload = {
    url: location.href,
    kind: expectedKind,
    aid: expectedAid,
    challenge: false,
    data: null
  };
  try {
    var page = new URL(location.href);
    var expectedOrigin = 'https://' + expectedHost;
    var validPort = !page.port ||
      (page.protocol === 'https:' && page.port === '443') ||
      (page.protocol === 'http:' && page.port === '80');
    if (page.origin !== expectedOrigin || page.protocol !== 'https:' ||
        !validPort || page.username || page.password || page.hash) {
      return JSON.stringify(payload);
    }

    var pageTitle = (document.title || '').toLowerCase();
    var hasChallenge = !!document.querySelector(
      '#challenge-form, #cf-challenge-running, .cf-browser-verification, #cf-wrapper'
    ) || /just a moment|attention required|sorry, you have been blocked|checking your browser/.test(pageTitle);
    var contentRoot = expectedKind === 'reader' ? document.querySelector('table.css') :
      expectedKind === 'tags' ? document.querySelector('ul.ultops') :
      expectedKind === 'list' ? document.querySelector('table.grid') :
      document.querySelector('#content');
    var loginTitle = /log ?in|sign ?in|登录|用户登录/.test(pageTitle);
    var passwordForm = document.querySelector('form input[type="password"]');
    var loginMarker = document.querySelector('#login, .login, #loginform, form[action*="login"]');
    payload.challenge = hasChallenge || (!contentRoot && !!(loginTitle || passwordForm || loginMarker));
    if (payload.challenge) return JSON.stringify(payload);

    var maxString = 32768;
    var maxUrl = 2048;
    var maxVolumes = 200;
    var maxChapters = 10000;
    var maxTagGroups = 128;
    var maxTags = 500;
    var maxRecords = 500;

    function cleanText(value, limit) {
      var text = (value || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
      return text.length <= (limit || maxString) ? text : '';
    }
    function takeChars(value, count) {
      return Array.from(value || '').slice(count).join('');
    }
    function validBookAid(value) {
      return /^[1-9][0-9]{0,11}$/.test(value || '');
    }
    function safePageImage(raw) {
      if (!raw || raw.length > maxUrl) return '';
      try {
        var image = new URL(raw, page.href);
        var host = image.hostname.toLowerCase();
        var wenkuHost = host === 'wenku8.net' || host.endsWith('.wenku8.net') ||
          host === 'wenku8.com' || host.endsWith('.wenku8.com');
        var imagePortOkay = !image.port ||
          (image.protocol === 'https:' && image.port === '443') ||
          (image.protocol === 'http:' && image.port === '80');
        if ((image.protocol !== 'http:' && image.protocol !== 'https:') ||
            !wenkuHost || !imagePortOkay || image.username || image.password) return '';
        image.protocol = 'https:';
        image.port = '';
        image.hash = '';
        return image.href;
      } catch (_) { return ''; }
    }
    function chapterImage(raw) {
      if (!raw || raw.length > maxUrl) return '';
      try {
        var image = new URL(raw, page.href);
        var imagePortOkay = !image.port ||
          (image.protocol === 'https:' && image.port === '443') ||
          (image.protocol === 'http:' && image.port === '80');
        if ((image.protocol !== 'http:' && image.protocol !== 'https:') ||
            !image.hostname || !imagePortOkay || image.username || image.password) return '';
        image.protocol = 'https:';
        image.port = '';
        image.hash = '';
        return image.href;
      } catch (_) { return ''; }
    }
    function directBookLink(anchor) {
      if (!anchor) return null;
      var raw = (anchor.getAttribute('href') || '').trim();
      if (!raw || raw.length > maxUrl) return null;
      try {
        var url = new URL(raw, page.href);
        var match = /^\/book\/([1-9][0-9]{0,11})\.htm$/.exec(url.pathname);
        var linkPortOkay = !url.port ||
          (url.protocol === 'https:' && url.port === '443') ||
          (url.protocol === 'http:' && url.port === '80');
        if (!match || url.hostname !== page.hostname || !linkPortOkay ||
            (url.protocol !== 'https:' && url.protocol !== 'http:') ||
            url.username || url.password || url.search || url.hash) return null;
        url.protocol = 'https:';
        url.port = '';
        return { aid: match[1], url: url.href };
      } catch (_) { return null; }
    }
    function safeIntro(node) {
      var allowed = {b:1, strong:1, i:1, em:1, u:1, br:1, p:1, div:1, span:1, hr:1};
      var blocked = {script:1, style:1, iframe:1, object:1, embed:1, form:1,
        input:1, button:1, select:1, textarea:1, ul:1, img:1};
      function escapeText(text) {
        return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      }
      function visit(current) {
        if (current.nodeType === 3) return escapeText(current.nodeValue || '');
        if (current.nodeType !== 1) return '';
        var tag = current.tagName.toLowerCase();
        if (blocked[tag]) return '';
        var inner = '';
        Array.from(current.childNodes).forEach(function(child) { inner += visit(child); });
        if (!allowed[tag]) return inner;
        if (tag === 'br' || tag === 'hr') return '<' + tag + '>';
        return '<' + tag + '>' + inner + '</' + tag + '>';
      }
      return node ? Array.from(node.childNodes).map(visit).join('') : '';
    }
    function requireExpectedAid(value) {
      return validBookAid(expectedAid) && value === expectedAid;
    }
    function firstUniqueParam(url, name) {
      var all = url.searchParams.getAll(name);
      return all.length === 1 ? all[0] : null;
    }
    function readerChapter(anchor) {
      var raw = (anchor.getAttribute('href') || '').trim();
      if (!raw || raw.length > maxUrl) return null;
      try {
        var url = new URL(raw, page.href);
        if (url.protocol !== 'https:' || url.origin !== expectedOrigin ||
            url.username || url.password || url.hash) return null;
        var cid = '';
        var aidValue = '';
        var match = /^\/novel\/([0-9]+)\/([1-9][0-9]{0,11})\/([0-9]+)\.htm$/.exec(url.pathname);
        if (match) {
          aidValue = match[2];
          cid = match[3];
          var numericAid = Number(aidValue);
          if (match[1] !== String(Math.floor(numericAid / 1000)) || url.search) return null;
        } else if (url.pathname === '/modules/article/reader.php') {
          aidValue = firstUniqueParam(url, 'aid') || '';
          cid = firstUniqueParam(url, 'cid') || '';
          var allowed = ['aid', 'cid', 'charset'];
          var keys = Array.from(url.searchParams.keys());
          if (keys.some(function(key) { return allowed.indexOf(key) < 0; }) ||
              url.searchParams.getAll('aid').length !== 1 ||
              url.searchParams.getAll('cid').length !== 1 ||
              (url.searchParams.has('charset') &&
               (url.searchParams.getAll('charset').length !== 1 ||
                url.searchParams.get('charset').toLowerCase() !== 'gbk'))) return null;
        } else return null;
        if (!requireExpectedAid(aidValue) || !/^[0-9]{1,12}$/.test(cid)) return null;
        return {title: cleanText(anchor.textContent), url: url.href, cid: cid, aid: aidValue};
      } catch (_) { return null; }
    }
    function collectDetail() {
      var content = document.querySelector('#content');
      if (!content || !requireExpectedAid(expectedAid)) return null;
      var tables = Array.from(content.querySelectorAll('table'));
      var table = tables[0];
      if (!table) return null;
      var titleNode = table.querySelector('span b');
      var rows = Array.from(table.querySelectorAll('tr'));
      var cells = rows[2] ? Array.from(rows[2].querySelectorAll('td')) : [];
      var images = Array.from(content.querySelectorAll('img'));
      var image = images.length ? safePageImage(
        images[0].getAttribute('src') || images[0].getAttribute('data-src') || ''
      ) : '';
      var infoCells = tables[2] ? Array.from(tables[2].querySelectorAll('td')) : [];
      var info = infoCells[1] || null;
      var spans = info ? Array.from(info.querySelectorAll('span')) : [];
      var intro = spans[5] ? safeIntro(spans[5]) :
        spans[3] ? takeChars(cleanText(spans[3].textContent, 48000), 5) : '';
      var rawTags = spans[0] ? cleanText(spans[0].textContent) : '';
      rawTags = rawTags.replace(
        /^(?:作品|小说|小說)?(?:标签|標籤|tags)(?:分类|分類)?\s*[:：]\s*/i,
        ''
      );
      var tags = rawTags.split(' ').filter(function(tag) { return !!tag; }).slice(0, maxTags);
      return {
        title: cleanText(titleNode && titleNode.textContent),
        author: cells[1] ? takeChars(cleanText(cells[1].textContent), 5) : '',
        status: cells[2] ? takeChars(cleanText(cells[2].textContent), 5) : '',
        finUpdate: cells[3] ? takeChars(cleanText(cells[3].textContent), 5) : '',
        image: image,
        introduce: intro,
        tags: tags,
        isAnimated: !!spans[1]
      };
    }
    function collectReader() {
      var table = document.querySelector('table.css');
      if (!table || !requireExpectedAid(expectedAid)) return null;
      var volumes = [];
      var chaptersTotal = 0;
      var current = null;
      Array.from(table.querySelectorAll('tr')).forEach(function(row) {
        var volumeCell = row.querySelector('td.vcss');
        if (volumeCell) {
          if (current) volumes.push(current);
          current = {
            id: (volumeCell.getAttribute('vid') || '').slice(0, 64),
            title: cleanText(volumeCell.textContent),
            chapters: []
          };
          return;
        }
        if (!current) return;
        Array.from(row.querySelectorAll('td.ccss a')).forEach(function(anchor) {
          if (current.chapters.length >= maxChapters || chaptersTotal >= maxChapters) return;
          var chapter = readerChapter(anchor);
          if (chapter && chapter.title) {
            current.chapters.push(chapter);
            chaptersTotal++;
          }
        });
      });
      if (current) volumes.push(current);
      if (volumes.length > maxVolumes || chaptersTotal > maxChapters) return null;
      return {volumes: volumes};
    }
    function extractChapter(node, output) {
      Array.from(node.childNodes).forEach(function(child) {
        if (child.nodeType === 3) {
          output.push((child.nodeValue || '').replace(/\u00a0/g, ' '));
          return;
        }
        if (child.nodeType !== 1) return;
        var tag = child.tagName.toLowerCase();
        var markers = ((child.id || '') + ' ' +
          (typeof child.className === 'string' ? child.className : '')).toLowerCase();
        if (tag === 'ul' || tag === 'script' || tag === 'style' || tag === 'iframe' ||
            tag === 'form' || tag === 'input' || tag === 'button' || tag === 'nav' ||
            /(^|[\s_-])(ad|ads|advert|watermark|error|login|navigation)([\s_-]|$)/.test(markers)) return;
        if (tag === 'br') { output.push('\n'); return; }
        if (tag === 'img') {
          var src = child.getAttribute('src') || child.getAttribute('data-src') || '';
          var image = chapterImage(src.trim());
          if (image) output.push('\n<!--image-->' + image + '<!--image-->\n');
          return;
        }
        extractChapter(child, output);
      });
    }
    function collectChapter() {
      var content = document.querySelector('#content');
      if (!content || !requireExpectedAid(expectedAid)) return null;
      var parts = [];
      extractChapter(content, parts);
      return {content: parts.join('').trim()};
    }
    function collectTags() {
      var groups = [];
      var groupTitle = '';
      var tags = [];
      Array.from(document.querySelectorAll('ul.ultops')).forEach(function(list) {
        Array.from(list.querySelectorAll('li')).forEach(function(item) {
          var html = (item.innerHTML || '').trim();
          if (html.endsWith('Tags：') || html.endsWith('Tags:')) {
            if (groupTitle) groups.push({title: groupTitle, tags: tags.slice()});
            groupTitle = cleanText(item.textContent)
              .replace(/Tags[:：]\s*$/, '')
              .replace(/系|属性|类/g, '').trim();
            tags = [];
          } else {
            Array.from(item.querySelectorAll('a')).forEach(function(anchor) {
              var tag = cleanText(anchor.textContent);
              if (tag && tags.length < maxTags) tags.push(tag);
            });
          }
        });
      });
      if (groupTitle) groups.push({title: groupTitle, tags: tags.slice()});
      return {groups: groups.slice(0, maxTagGroups)};
    }
    function listUrlPage() {
      var parameters = page.searchParams;
      var keys = Array.from(parameters.keys());
      if (parameters.getAll('charset').length > 1 ||
          (parameters.has('charset') && parameters.get('charset').toLowerCase() !== 'gbk')) return null;
      if (page.pathname === '/modules/article/tags.php') {
        var allowedTags = ['t', 'v', 'page', 'charset'];
        if (keys.some(function(key) { return allowedTags.indexOf(key) < 0; }) ||
            parameters.getAll('t').length !== 1 || parameters.getAll('v').length !== 1 ||
            parameters.getAll('page').length !== 1 || !parameters.get('t') ||
            !/^[0-3]$/.test(parameters.get('v')) || !/^[1-9][0-9]{0,5}$/.test(parameters.get('page'))) return null;
      } else if (page.pathname === '/modules/article/toplist.php') {
        var allowedTop = ['sort', 'page', 'charset'];
        if (keys.some(function(key) { return allowedTop.indexOf(key) < 0; }) ||
            parameters.getAll('sort').length !== 1 || parameters.getAll('page').length !== 1 ||
            !/^[a-zA-Z0-9_-]{1,32}$/.test(parameters.get('sort')) ||
            !/^[1-9][0-9]{0,5}$/.test(parameters.get('page'))) return null;
      } else if (page.pathname === '/modules/article/search.php') {
        var allowedSearch = ['searchtype', 'searchkey', 'page', 'charset'];
        if (keys.some(function(key) { return allowedSearch.indexOf(key) < 0; }) ||
            parameters.getAll('searchtype').length !== 1 ||
            parameters.getAll('searchkey').length !== 1 ||
            parameters.getAll('page').length !== 1 ||
            !/^(articlename|author)$/.test(parameters.get('searchtype')) ||
            !parameters.get('searchkey') || parameters.get('searchkey').length > 300 ||
            !/^[1-9][0-9]{0,5}$/.test(parameters.get('page'))) return null;
      } else if (page.pathname === '/modules/article/articlelist.php') {
        var allowedArticle = ['fullflag', 'page', 'charset'];
        if (keys.some(function(key) { return allowedArticle.indexOf(key) < 0; }) ||
            parameters.getAll('fullflag').length !== 1 || parameters.getAll('page').length !== 1 ||
            !/^[0-9]{1,2}$/.test(parameters.get('fullflag')) ||
            !/^[1-9][0-9]{0,5}$/.test(parameters.get('page'))) return null;
      } else return null;
      return true;
    }
    function collectList() {
      if (!listUrlPage()) return null;
      var records = [];
      var seen = new Set();
      var blocks = Array.from(document.querySelectorAll('table.grid tr td>div'));
      blocks.forEach(function(block) {
        Array.from(block.querySelectorAll('div>a>img')).forEach(function(image) {
          if (records.length >= maxRecords) return;
          var anchor = image.parentElement;
          var book = directBookLink(anchor);
          if (!book || seen.has(book.aid)) return;
          var title = cleanText(anchor && anchor.getAttribute('title'));
          if (!title) {
            // Current lists put the title beside the cover, inside b > a.
            // Bind it to the same book URL rather than another card's text.
            var names = Array.from(block.querySelectorAll('b a[href], strong a[href]'));
            var name = names.find(function(candidate) {
              var linkedBook = directBookLink(candidate);
              return linkedBook && linkedBook.aid === book.aid && cleanText(candidate.textContent);
            });
            title = name ? cleanText(name.textContent) : cleanText(image.getAttribute('alt'));
          }
          var cover = safePageImage(image.getAttribute('src') || '');
          if (book && title && cover) {
            seen.add(book.aid);
            records.push({title: title, image: cover, detailUrl: book.url, aid: book.aid});
          }
        });
      });
      var stats = document.querySelector('em#pagestats');
      var parts = (stats ? cleanText(stats.textContent) : '').split('/');
      var current = parts.length > 0 && /^[0-9]+$/.test(parts[0].trim()) ? Number(parts[0].trim()) : 0;
      var maximum = parts.length > 1 && /^[0-9]+$/.test(parts[1].trim()) ? Number(parts[1].trim()) : 0;
      if (!records.length && page.pathname === '/modules/article/search.php') {
        var content = document.querySelector('#content');
        var noResults = content && /(?:没有|沒有)符合(?:条件|條件)(?:的)?(?:小说|小說|作品|结果|結果)|(?:没有找到|沒有找到|未找到)(?:相关|相關|匹配)(?:的)?(?:小说|小說|作品|结果|結果)|无搜索结果|無搜尋結果/.test(content.textContent || '');
        var grid = content && content.querySelector('table.grid');
        var firstRow = grid && grid.querySelector('tr');
        var emptyGrid = grid && current === 1 && maximum === 1 &&
          firstRow && !cleanText(firstRow.textContent) && !grid.querySelector('img') &&
          !Array.from(grid.querySelectorAll('a[href]')).some(function(anchor) { return !!directBookLink(anchor); });
        if (noResults || emptyGrid) return {currentPage: 1, maxPage: 1, records: [], emptyReason: 'no_results'};
      }
      return {currentPage: current, maxPage: maximum, records: records};
    }

    if (expectedKind === 'detail') payload.data = collectDetail();
    else if (expectedKind === 'reader') payload.data = collectReader();
    else if (expectedKind === 'chapter') payload.data = collectChapter();
    else if (expectedKind === 'tags') payload.data = collectTags();
    else if (expectedKind === 'list') payload.data = collectList();
  } catch (_) {
    payload.data = null;
  }
  return JSON.stringify(payload);
})($expectedHost, $expectedKind, $expectedAid)
'''
      .replaceFirst(r'$expectedHost', expectedHost)
      .replaceFirst(r'$expectedKind', expectedKind)
      .replaceFirst(r'$expectedAid', expectedAid);
}

/// Validates a compact WebView result and maps it to the established FRB
/// models. Both the reported document URL and the WebView's loaded URL must be
/// the requested Wenku8 page; empty/blocked pages are errors, never successes.
Object parseWenku8ReadWebViewResult(
  Object? result, {
  required String apiHost,
  required String loadedUrl,
  required String kind,
  String? aid,
}) {
  if (!const {'detail', 'reader', 'chapter', 'tags', 'list'}.contains(kind)) {
    throw const FormatException('不支持的文库8页面类型。');
  }
  if (result is String && result.length > _maxPayloadLength) {
    throw const FormatException('文库8网页提取结果过大，请重新加载。');
  }
  Object? decoded = result;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      throw const FormatException('文库8网页没有返回可识别的书目数据。');
    }
  }
  if (decoded is! Map) {
    throw const FormatException('文库8网页没有返回可识别的书目数据。');
  }
  final payload = Map<String, dynamic>.from(decoded);
  _requireKeys(payload, const {'url', 'kind', 'aid', 'challenge', 'data'});
  if (payload['kind'] != kind || payload['challenge'] != false) {
    throw const FormatException('文库8验证或登录页面未提供书目数据。');
  }
  final expected = Uri.parse(normalizeWenku8Host(apiHost));
  if (loadedUrl.isEmpty || loadedUrl.length > _maxUrlLength * 2) {
    throw const FormatException('文库8页面地址无效，请返回书页后重试。');
  }
  final pageText = payload['url'];
  if (pageText is! String ||
      pageText.isEmpty ||
      pageText.length > _maxUrlLength * 2 ||
      pageText != loadedUrl) {
    throw const FormatException('网页在读取时发生跳转，请返回文库8书页后重试。');
  }
  final page = Uri.tryParse(pageText);
  if (!_isValidPage(page, expected, kind, aid)) {
    throw const FormatException('请先打开对应的文库8书页，再读取书目内容。');
  }
  final expectedAid = _bookAidForKind(kind, aid);
  if (payload['aid'] != expectedAid) {
    throw const FormatException('读取到的书号与当前书页不一致。');
  }
  final data = payload['data'];
  if (data is! Map) {
    throw const FormatException('文库8书页为空或未完成加载，请重试。');
  }
  final fields = Map<String, dynamic>.from(data);

  switch (kind) {
    case 'detail':
      _requireKeys(fields, const {
        'title',
        'author',
        'status',
        'finUpdate',
        'image',
        'introduce',
        'tags',
        'isAnimated',
      });
      final title = _boundedString(fields, 'title', 300, required: true);
      final author = _boundedString(fields, 'author', 300, required: true);
      final status = _boundedString(fields, 'status', 120, required: true);
      final finUpdate = _boundedString(fields, 'finUpdate', 300);
      final image = _coverImage(fields, 'image', expected);
      final introduce = _boundedString(fields, 'introduce', _maxIntroLength);
      final tags = _parseStringList(fields['tags'], _maxTagsPerGroup, 120);
      if (fields['isAnimated'] is! bool) {
        throw const FormatException('文库8详情字段格式无效。');
      }
      if (title.isEmpty || author.isEmpty || status.isEmpty || image.isEmpty) {
        throw const FormatException('文库8详情页缺少书名、作者、状态或封面。');
      }
      return NovelInfo(
        title: title,
        author: author,
        status: status,
        finUpdate: finUpdate,
        imgUrl: image,
        introduce: introduce,
        tags: List.unmodifiable(tags),
        heat: '',
        trending: '',
        isAnimated: fields['isAnimated'] as bool,
      );
    case 'reader':
      _requireKeys(fields, const {'volumes'});
      final rawVolumes = fields['volumes'];
      if (rawVolumes is! List || rawVolumes.length > _maxVolumes) {
        throw const FormatException('文库8目录为空或超出解析上限。');
      }
      final volumes = <Volume>[];
      var chaptersRead = 0;
      for (final rawVolume in rawVolumes) {
        if (rawVolume is! Map) {
          throw const FormatException('文库8目录卷格式无效。');
        }
        final volume = Map<String, dynamic>.from(rawVolume);
        _requireKeys(volume, const {'id', 'title', 'chapters'});
        final id = _boundedString(volume, 'id', 64);
        final title = _boundedString(volume, 'title', 300, required: true);
        final rawChapters = volume['chapters'];
        if (rawChapters is! List ||
            rawChapters.length > _maxChapters - chaptersRead) {
          throw const FormatException('文库8章节目录超出解析上限。');
        }
        final chapters = <Chapter>[];
        for (final rawChapter in rawChapters) {
          if (rawChapter is! Map) {
            throw const FormatException('文库8章节格式无效。');
          }
          final chapter = Map<String, dynamic>.from(rawChapter);
          _requireKeys(chapter, const {'title', 'url', 'cid', 'aid'});
          final chapterTitle = _boundedString(
            chapter,
            'title',
            300,
            required: true,
          );
          final chapterUrl = _boundedString(
            chapter,
            'url',
            _maxUrlLength,
            required: true,
          );
          final cid = _boundedDigits(chapter, 'cid', 12);
          final chapterAid = _boundedDigits(chapter, 'aid', 12);
          if (chapterAid != expectedAid ||
              !_validReaderChapterUrl(chapterUrl, expected, expectedAid, cid)) {
            throw const FormatException('章节链接与当前文库8书号不一致。');
          }
          chapters.add(
            Chapter(
              title: chapterTitle,
              url: Uri.parse(chapterUrl).toString(),
              cid: cid,
              aid: chapterAid,
            ),
          );
          chaptersRead++;
        }
        volumes.add(
          Volume(id: id, title: title, chapters: List.unmodifiable(chapters)),
        );
      }
      if (volumes.isEmpty || chaptersRead == 0) {
        throw const FormatException('文库8目录没有可用的卷或章节。');
      }
      return List<Volume>.unmodifiable(volumes);
    case 'chapter':
      _requireKeys(fields, const {'content'});
      final content = _boundedString(fields, 'content', _maxChapterLength);
      if (content.trim().isEmpty) {
        throw const FormatException('文库8正文为空，请确认章节已经加载。');
      }
      _validateChapterImageMarkers(content);
      return content;
    case 'tags':
      _requireKeys(fields, const {'groups'});
      final rawGroups = fields['groups'];
      if (rawGroups is! List ||
          rawGroups.isEmpty ||
          rawGroups.length > _maxTagGroups) {
        throw const FormatException('文库8标签页为空或超出解析上限。');
      }
      final groups = <TagGroup>[];
      for (final rawGroup in rawGroups) {
        if (rawGroup is! Map) {
          throw const FormatException('文库8标签组格式无效。');
        }
        final group = Map<String, dynamic>.from(rawGroup);
        _requireKeys(group, const {'title', 'tags'});
        final title = _boundedString(group, 'title', 160, required: true);
        final tags = _parseStringList(group['tags'], _maxTagsPerGroup, 120);
        if (title.isEmpty || tags.isEmpty) continue;
        groups.add(TagGroup(title: title, tags: List.unmodifiable(tags)));
      }
      if (groups.isEmpty) {
        throw const FormatException('文库8标签页没有可用标签。');
      }
      return List<TagGroup>.unmodifiable(groups);
    case 'list':
      if (fields.containsKey('emptyReason')) {
        _requireKeys(fields, const {
          'currentPage',
          'maxPage',
          'records',
          'emptyReason',
        });
        if (page!.path != '/modules/article/search.php' ||
            fields['emptyReason'] != 'no_results' ||
            fields['currentPage'] != 1 ||
            fields['maxPage'] != 1 ||
            fields['records'] is! List ||
            (fields['records'] as List).isNotEmpty) {
          throw const FormatException('文库8搜索空结果标记无效。');
        }
        return const PageStatsNovelCover(
          currentPage: 1,
          maxPage: 1,
          records: [],
        );
      }
      _requireKeys(fields, const {'currentPage', 'maxPage', 'records'});
      final currentPage = _boundedInt(fields, 'currentPage', 0, 1000000);
      final maxPage = _boundedInt(fields, 'maxPage', 0, 1000000);
      final rawRecords = fields['records'];
      if (rawRecords is! List ||
          rawRecords.isEmpty ||
          rawRecords.length > _maxRecords ||
          (maxPage > 0 && currentPage > maxPage)) {
        throw const FormatException('文库8书目列表为空或分页字段无效。');
      }
      final records = <NovelCover>[];
      for (final rawRecord in rawRecords) {
        if (rawRecord is! Map) {
          throw const FormatException('文库8书目字段格式无效。');
        }
        final record = Map<String, dynamic>.from(rawRecord);
        _requireKeys(record, const {'title', 'image', 'detailUrl', 'aid'});
        final title = _boundedString(record, 'title', 300, required: true);
        final recordAid = _boundedDigits(record, 'aid', 12);
        final detailUrl = _validBookDetailUrl(
          _boundedString(record, 'detailUrl', _maxUrlLength, required: true),
          expected,
          recordAid,
        );
        final image = _coverImage(record, 'image', expected);
        if (title.isEmpty || detailUrl == null || image.isEmpty) {
          throw const FormatException('文库8列表封面字段无效。');
        }
        records.add(
          NovelCover(
            title: title,
            img: image,
            detailUrl: detailUrl,
            aid: recordAid,
          ),
        );
      }
      return PageStatsNovelCover(
        currentPage: currentPage,
        maxPage: maxPage,
        records: List.unmodifiable(records),
      );
  }
  throw const FormatException('不支持的文库8页面类型。');
}

String _bookAidForKind(String kind, String? aid) {
  if (kind == 'detail' || kind == 'reader' || kind == 'chapter') {
    if (aid == null || !RegExp(r'^[1-9][0-9]{0,11}$').hasMatch(aid)) {
      throw const FormatException('文库8书号无效。');
    }
    return aid;
  }
  return '';
}

/// Reuses the raw-query validator, including legacy GBK percent bytes, before
/// accepting Wenku8's exact-search redirect to a detail page.
bool isWenku8SearchRequest(Uri request, String apiHost) =>
    request.path == '/modules/article/search.php' &&
    _isValidPage(
      request,
      Uri.parse(normalizeWenku8Host(apiHost)),
      'list',
      null,
    );

bool _isValidPage(Uri? page, Uri expected, String kind, String? aid) {
  if (page == null ||
      page.scheme != 'https' ||
      page.host.toLowerCase() != expected.host.toLowerCase() ||
      page.port != expected.port ||
      page.userInfo.isNotEmpty ||
      page.hasFragment) {
    return false;
  }
  final expectedAid = _bookAidForKind(kind, aid);
  final query = _rawQueryParameters(page);
  bool exactQuery(Set<String> keys, {Set<String> optional = const {}}) {
    if (query.keys.any((key) => !keys.contains(key)) ||
        keys.any((key) => !optional.contains(key) && !query.containsKey(key))) {
      return false;
    }
    return query.values.every((values) => values.length == 1);
  }

  bool charsetAllowed() =>
      !query.containsKey('charset') ||
      query['charset']!.single.toLowerCase() == 'gbk';
  switch (kind) {
    case 'detail':
      final book = RegExp(
        r'^/book/([1-9][0-9]{0,11})\.htm$',
      ).firstMatch(page.path);
      if (book != null) {
        return book.group(1) == expectedAid &&
            exactQuery(const {'charset'}, optional: const {'charset'}) &&
            charsetAllowed();
      }
      if (page.path == '/modules/article/articleinfo.php' &&
          exactQuery(const {'id', 'charset'}, optional: const {'charset'}) &&
          charsetAllowed()) {
        return query['id']!.single == expectedAid;
      }
      return false;
    case 'reader':
      final group = (int.parse(expectedAid) ~/ 1000).toString();
      final match = RegExp(
        r'^/novel/([0-9]+)/([1-9][0-9]{0,11})/index\.htm$',
      ).firstMatch(page.path);
      if (match != null) {
        return match.group(1) == group &&
            match.group(2) == expectedAid &&
            exactQuery(const {'charset'}, optional: const {'charset'}) &&
            charsetAllowed();
      }
      return page.path == '/modules/article/reader.php' &&
          exactQuery(const {'aid', 'charset'}, optional: const {'charset'}) &&
          charsetAllowed() &&
          query['aid']!.single == expectedAid;
    case 'chapter':
      if (page.hasQuery) return false;
      final group = (int.parse(expectedAid) ~/ 1000).toString();
      final match = RegExp(
        r'^/novel/([0-9]+)/([1-9][0-9]{0,11})/([0-9]+)\.htm$',
      ).firstMatch(page.path);
      return match != null &&
          match.group(1) == group &&
          match.group(2) == expectedAid;
    case 'tags':
      return page.path == '/modules/article/tags.php' &&
          exactQuery(const {'charset'}, optional: const {'charset'}) &&
          charsetAllowed();
    case 'list':
      if (page.path == '/modules/article/tags.php') {
        return exactQuery(
              const {'t', 'v', 'page', 'charset'},
              optional: const {'charset'},
            ) &&
            charsetAllowed() &&
            query['t']!.single.isNotEmpty &&
            query['t']!.single.length <= 80 &&
            RegExp(r'^[0-3]$').hasMatch(query['v']!.single) &&
            _positivePage(query['page']!.single);
      }
      if (page.path == '/modules/article/toplist.php') {
        return exactQuery(
              const {'sort', 'page', 'charset'},
              optional: const {'charset'},
            ) &&
            charsetAllowed() &&
            RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(query['sort']!.single) &&
            _positivePage(query['page']!.single);
      }
      if (page.path == '/modules/article/search.php') {
        return exactQuery(
              const {'searchtype', 'searchkey', 'page', 'charset'},
              optional: const {'charset'},
            ) &&
            charsetAllowed() &&
            const {
              'articlename',
              'author',
            }.contains(query['searchtype']!.single) &&
            query['searchkey']!.single.isNotEmpty &&
            query['searchkey']!.single.length <= 300 &&
            _positivePage(query['page']!.single);
      }
      if (page.path == '/modules/article/articlelist.php') {
        return exactQuery(
              const {'fullflag', 'page', 'charset'},
              optional: const {'charset'},
            ) &&
            charsetAllowed() &&
            RegExp(r'^[0-9]{1,2}$').hasMatch(query['fullflag']!.single) &&
            _positivePage(query['page']!.single);
      }
      return false;
  }
  return false;
}

bool _positivePage(String value) =>
    RegExp(r'^[1-9][0-9]{0,5}$').hasMatch(value) && int.parse(value) <= 100000;

String _boundedString(
  Map<String, dynamic> object,
  String key,
  int maximum, {
  bool required = false,
}) {
  final value = object[key];
  if (value is! String ||
      value.length > maximum ||
      (required && value.trim().isEmpty)) {
    throw FormatException('文库8字段 $key 为空或超出长度限制。');
  }
  return value;
}

void _validateChapterImageMarkers(String content) {
  const marker = '<!--image-->';
  final pieces = content.split(marker);
  if (pieces.length.isEven) {
    throw const FormatException('文库8正文插图标记不完整。');
  }
  for (var index = 1; index < pieces.length; index += 2) {
    final rawUrl = pieces[index];
    final uri = Uri.tryParse(rawUrl);
    if (rawUrl.isEmpty ||
        rawUrl.length > _maxUrlLength ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment) {
      throw const FormatException('文库8正文插图地址无效。');
    }
  }
}

String _boundedDigits(
  Map<String, dynamic> object,
  String key,
  int maximumDigits,
) {
  final value = _boundedString(object, key, maximumDigits, required: true);
  if (!RegExp('^[0-9]{1,$maximumDigits}\$').hasMatch(value)) {
    throw FormatException('文库8字段 $key 格式无效。');
  }
  return value;
}

int _boundedInt(
  Map<String, dynamic> object,
  String key,
  int minimum,
  int maximum,
) {
  final value = object[key];
  if (value is! int || value < minimum || value > maximum) {
    throw FormatException('文库8字段 $key 超出分页范围。');
  }
  return value;
}

List<String> _parseStringList(
  Object? value,
  int maximumItems,
  int maximumLength,
) {
  if (value is! List || value.length > maximumItems) {
    throw const FormatException('文库8列表字段格式无效或超出上限。');
  }
  final output = <String>[];
  for (final item in value) {
    if (item is! String || item.length > maximumLength) {
      throw const FormatException('文库8列表文本超出长度限制。');
    }
    if (item.trim().isNotEmpty) output.add(item);
  }
  return output;
}

String _coverImage(Map<String, dynamic> object, String key, Uri expected) {
  final raw = _boundedString(object, key, _maxUrlLength, required: true);
  final uri = Uri.tryParse(raw);
  final resolved =
      uri == null ? null : (uri.hasScheme ? uri : expected.resolveUri(uri));
  if (resolved == null ||
      !const {'http', 'https'}.contains(resolved.scheme) ||
      resolved.host.isEmpty ||
      resolved.userInfo.isNotEmpty ||
      (resolved.hasPort &&
          !((resolved.scheme == 'http' && resolved.port == 80) ||
              (resolved.scheme == 'https' && resolved.port == 443)))) {
    throw const FormatException('文库8封面地址无效。');
  }
  final host = resolved.host.toLowerCase();
  final isWenkuImageHost =
      host == 'wenku8.net' ||
      host.endsWith('.wenku8.net') ||
      host == 'wenku8.com' ||
      host.endsWith('.wenku8.com');
  if (!isWenkuImageHost) {
    throw const FormatException('文库8封面必须来自文库8图片域名。');
  }
  return resolved
      .replace(scheme: 'https', port: 443)
      .removeFragment()
      .toString();
}

String? _validBookDetailUrl(String value, Uri expected, String aid) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != expected.host.toLowerCase() ||
      uri.port != expected.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final match = RegExp(r'^/book/([1-9][0-9]{0,11})\.htm$').firstMatch(uri.path);
  if (match?.group(1) != aid) return null;
  return uri.toString();
}

bool _validReaderChapterUrl(
  String value,
  Uri expected,
  String aid,
  String cid,
) {
  if (value.length > _maxUrlLength) return false;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != expected.host.toLowerCase() ||
      uri.port != expected.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  final group = (int.parse(aid) ~/ 1000).toString();
  final direct = RegExp(
    r'^/novel/([0-9]+)/([1-9][0-9]{0,11})/([0-9]+)\.htm$',
  ).firstMatch(uri.path);
  if (direct != null) {
    return !uri.hasQuery &&
        direct.group(1) == group &&
        direct.group(2) == aid &&
        direct.group(3) == cid;
  }
  final query = _rawQueryParameters(uri);
  return uri.path == '/modules/article/reader.php' &&
      query.keys.every(
        (key) => const {'aid', 'cid', 'charset'}.contains(key),
      ) &&
      query.values.every((values) => values.length == 1) &&
      query['aid']?.single == aid &&
      query['cid']?.single == cid &&
      (!query.containsKey('charset') ||
          query['charset']!.single.toLowerCase() == 'gbk');
}

/// Decodes URL query octets as Latin-1 so legacy GBK percent bytes stay
/// inspectable. Route checks only need ASCII keys and fixed ASCII values;
/// tag/search terms are validated for presence and length without pretending
/// their GBK bytes are UTF-8.
Map<String, List<String>> _rawQueryParameters(Uri uri) {
  final values = <String, List<String>>{};
  if (!uri.hasQuery || uri.query.isEmpty) return values;
  for (final pair in uri.query.split('&')) {
    final separator = pair.indexOf('=');
    final rawKey = separator < 0 ? pair : pair.substring(0, separator);
    final rawValue = separator < 0 ? '' : pair.substring(separator + 1);
    final key = _decodeQueryOctets(rawKey);
    final value = _decodeQueryOctets(rawValue);
    values.putIfAbsent(key, () => <String>[]).add(value);
  }
  return values;
}

String _decodeQueryOctets(String value) {
  final bytes = <int>[];
  for (var index = 0; index < value.length; index++) {
    final character = value.codeUnitAt(index);
    if (character == 0x25) {
      if (index + 2 >= value.length) {
        throw const FormatException('文库8页面查询参数编码无效。');
      }
      final byte = int.tryParse(
        value.substring(index + 1, index + 3),
        radix: 16,
      );
      if (byte == null) {
        throw const FormatException('文库8页面查询参数编码无效。');
      }
      bytes.add(byte);
      index += 2;
    } else if (character == 0x2b) {
      bytes.add(0x20);
    } else if (character <= 0xff) {
      bytes.add(character);
    } else {
      throw const FormatException('文库8页面查询参数编码无效。');
    }
  }
  return latin1.decode(bytes);
}

void _requireKeys(Map<String, dynamic> object, Set<String> expected) {
  if (object.length != expected.length ||
      object.keys.any((key) => !expected.contains(key))) {
    throw const FormatException('文库8页面数据包含未知或缺失字段。');
  }
}
