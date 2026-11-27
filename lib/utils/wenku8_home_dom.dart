import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const int _maxHtmlLength = 1024 * 1024;
const int _maxPayloadLength = 256 * 1024;
const int _maxBlocks = 128;
const int _maxBooksPerBlock = 100;
const int _maxBooksTotal = 500;
const int _maxTitleLength = 240;
const int _maxUrlLength = 2048;

/// Produces a DOM-only snapshot of recommendation book fields.
///
/// The returned JSON contract is `{url, challenge, blocks:[{title,covers:[{
/// title,image,detailUrl,aid}]}]}`. It deliberately never serializes page HTML,
/// forms, account controls, body text, or cookies.
String wenku8HomeDomExtractionScript(String apiHost) {
  final expectedHost = jsonEncode(Uri.parse(normalizeWenku8Host(apiHost)).host);
  return r'''
(function(expectedHost) {
  var payload = { url: location.href, challenge: false, blocks: [] };
  try {
    var page = new URL(location.href);
    var expectedOrigin = 'https://' + expectedHost;
    var homePath = page.pathname === '/' || page.pathname === '/index.php';
    var search = new URLSearchParams(page.search);
    var queryCount = Array.from(search.keys()).length;
    var queryAllowed = queryCount === 0 ||
      (queryCount === 1 && search.has('charset') &&
       search.get('charset').toLowerCase() === 'gbk');
    if (page.origin !== expectedOrigin || !homePath || !queryAllowed || page.hash) {
      return JSON.stringify(payload);
    }

    var title = (document.title || '').toLowerCase();
    payload.challenge = !!document.querySelector(
      '#challenge-form, #cf-challenge-running, .cf-browser-verification, #cf-wrapper'
    ) || /just a moment|attention required|sorry, you have been blocked/.test(title);
    if (payload.challenge) return JSON.stringify(payload);

    var maxBlocks = 128;
    var maxBooksPerBlock = 100;
    var maxBooksTotal = 500;
    var maxTitleLength = 240;
    var maxUrlLength = 2048;
    var blocks = [];
    var total = 0;
    var roots = Array.from(document.querySelectorAll('#centers, div.main')).slice(0, maxBlocks);
    var seenSections = new Set();

    function cleanText(value) {
      var text = (value || '').replace(/\s+/g, ' ').trim();
      return text.length > 0 && text.length <= maxTitleLength ? text : '';
    }
    function isBookUrl(anchor) {
      if (!anchor || !anchor.hasAttribute('href')) return null;
      var raw = (anchor.getAttribute('href') || '').trim();
      if (!raw || raw.length > maxUrlLength) return null;
      try {
        var url = new URL(raw, page.href);
        var match = /^\/book\/(\d+)\.htm$/.exec(url.pathname);
        var validPort = !url.port ||
          (url.protocol === 'http:' && url.port === '80') ||
          (url.protocol === 'https:' && url.port === '443');
        if ((url.protocol !== 'https:' && url.protocol !== 'http:') ||
            url.hostname !== page.hostname || !validPort || url.username ||
            url.password || url.search || url.hash || !match) return null;
        url.protocol = 'https:';
        url.port = '';
        return { url: url.href, aid: match[1] };
      } catch (_) { return null; }
    }
    function imageUrl(image) {
      var raw = '';
      ['data-original', 'data-original-src', 'data-lazy-src', 'data-src', 'src'].some(function(name) {
        raw = (image.getAttribute(name) || '').trim();
        return !!raw;
      });
      if (!raw) {
        var srcset = image.getAttribute('data-srcset') || image.getAttribute('srcset') || '';
        raw = srcset.trim().split(/\s+/)[0] || '';
      }
      if (!raw || raw.length > maxUrlLength) return '';
      try {
        var url = new URL(raw, page.href);
        var host = url.hostname.toLowerCase();
        var knownImageHost = host === 'wenku8.net' || host.endsWith('.wenku8.net') ||
          host === 'wenku8.com' || host.endsWith('.wenku8.com');
        if ((url.protocol !== 'http:' && url.protocol !== 'https:') ||
            !knownImageHost || url.username || url.password || url.port) return '';
        url.protocol = 'https:';
        url.port = '';
        url.hash = '';
        return url.href;
      } catch (_) { return ''; }
    }
    function sectionTitle(section) {
      var node = section.matches('.blocktitle, h1, h2, h3, h4') ? section :
        section.querySelector('.blocktitle, h1, h2, h3, h4');
      if (!node || node.querySelector('.txt')) return '';
      var text = cleanText(node.textContent);
      if ((text === '广告' || text.indexOf('广告推广') === 0) || text === '文库Telegram群组' ||
          text.indexOf('轻小说文库公告') === 0) return '';
      return text;
    }
    function bookLinks(node) {
      var found = [];
      var anchors = [];
      if (node.matches && node.matches('a[href]')) anchors.push(node);
      anchors = anchors.concat(Array.from(node.querySelectorAll('a[href]')));
      anchors.forEach(function(anchor) {
        var book = isBookUrl(anchor);
        if (book) found.push({ book: book, anchor: anchor });
      });
      return found;
    }
    function eligibleCard(node) {
      if (node.querySelector('form, input, select, textarea')) return false;
      return Array.from(node.querySelectorAll('*')).every(function(item) {
        var structural = ((item.id || '') + ' ' + (item.className || '')).toLowerCase();
        return structural.indexOf('login') < 0 && structural.indexOf('登录') < 0;
      });
    }
    function cardFor(image, section) {
      var imageAnchor = image.closest('a[href]');
      var direct = isBookUrl(imageAnchor);
      if (imageAnchor) {
        if (!direct) return null;
        var wrapper = imageAnchor.parentElement;
        if (wrapper && !eligibleCard(wrapper)) return null;
        var wrapperBooks = wrapper ? bookLinks(wrapper) : [];
        var distinct = wrapperBooks.filter(function(item, index) {
          return wrapperBooks.findIndex(function(other) { return other.book.url === item.book.url; }) === index;
        });
        return { book: direct, anchor: imageAnchor,
          card: distinct.length === 1 && distinct[0].book.url === direct.url &&
            wrapper && eligibleCard(wrapper) ? wrapper : imageAnchor };
      }
      var node = image.parentElement;
      while (node && node !== section.parentElement) {
        if (node === section) break;
        var candidates = bookLinks(node);
        var distinctBooks = candidates.filter(function(item, index) {
          return candidates.findIndex(function(other) { return other.book.url === item.book.url; }) === index;
        });
        if (distinctBooks.length === 1 && eligibleCard(node)) {
          return { book: distinctBooks[0].book, anchor: distinctBooks[0].anchor, card: node };
        }
        node = node.parentElement;
      }
      return null;
    }
    function sectionsFor(root) {
      var sections = [];
      if (root.matches('.block')) sections.push(root);
      sections = sections.concat(Array.from(root.querySelectorAll('.block')));
      if (!sections.length) {
        Array.from(root.querySelectorAll('section, article, h1, h2, h3, h4, .blocktitle'))
          .forEach(function(node) {
            var section = node.matches('section, article') ? node : node.parentElement;
            if (section && !sections.includes(section)) sections.push(section);
          });
      }
      return sections;
    }

    roots.forEach(function(root) {
      sectionsFor(root).slice(0, maxBlocks).forEach(function(section) {
        if (seenSections.has(section)) return;
        seenSections.add(section);
        var title = sectionTitle(section);
        if (!title || title === '文库Telegram群组' || title.indexOf('轻小说文库公告') === 0) return;
        var covers = [];
        var seenBooks = new Set();
        Array.from(section.querySelectorAll('img')).slice(0, maxBooksPerBlock * 2)
          .forEach(function(image) {
            if (covers.length >= maxBooksPerBlock || total >= maxBooksTotal) return;
            var card = cardFor(image, section);
            if (!card || seenBooks.has(card.book.url)) return;
            var imageSource = imageUrl(image);
            if (!imageSource) return;
            var name = cleanText(card.anchor.getAttribute('title')) ||
              cleanText(image.getAttribute('alt')) || cleanText(card.anchor.textContent);
            if (!name) {
              var nearby = bookLinks(card.card).find(function(item) {
                return item.book.url === card.book.url && item.anchor !== card.anchor && cleanText(item.anchor.textContent);
              });
              if (nearby) name = cleanText(nearby.anchor.textContent);
            }
            if (!name) {
              var plainName = card.card.querySelector('a:not([href])');
              if (plainName) name = cleanText(plainName.textContent);
            }
            if (!name) return;
            seenBooks.add(card.book.url);
            covers.push({
              title: name,
              image: imageSource,
              detailUrl: card.book.url,
              aid: card.book.aid
            });
            total++;
          });
        if (covers.length) blocks.push({ title: title, covers: covers });
      });
    });
    payload.blocks = blocks.slice(0, maxBlocks);
  } catch (_) {
    payload.blocks = [];
  }
  return JSON.stringify(payload);
})($expectedHost)
'''.replaceFirst(r'$expectedHost', expectedHost);
}

/// Validates and parses the compact WebView result. Only book fields are
/// trusted; the extraction page itself must still be the selected HTTPS home.
List<HomeBlock> parseWenku8HomeWebViewResult(
  Object? value, {
  required String apiHost,
  String? loadedUrl,
}) {
  Object? decoded = value;
  if (decoded is String) {
    if (decoded.length > _maxPayloadLength) {
      throw const FormatException('文库8首页数据过大，请重新加载首页。');
    }
    decoded = jsonDecode(decoded);
  }
  if (decoded is! Map) {
    throw const FormatException('文库8网页没有返回可识别的首页数据。');
  }
  final payload = Map<String, dynamic>.from(decoded);
  final expected = Uri.parse(normalizeWenku8Host(apiHost));
  final page = Uri.tryParse(
    payload['url'] is String ? payload['url'] as String : '',
  );
  if (!_isHomeUri(page, expected)) {
    throw const FormatException('请先返回文库8首页，再读取首页推荐。');
  }
  if (loadedUrl != null && loadedUrl.isNotEmpty) {
    final loaded = Uri.tryParse(loadedUrl);
    if (!_isHomeUri(loaded, expected) || loaded.toString() != page.toString()) {
      throw const FormatException('网页在读取时发生跳转，请返回首页后重试。');
    }
  }
  if (payload['challenge'] == true) {
    throw const FormatException('站点验证页面尚未完成，请完成验证后再试。');
  }
  if (payload['challenge'] != false || payload['url'] is! String) {
    throw const FormatException('文库8首页数据格式无效。');
  }
  final rawBlocks = payload['blocks'];
  if (rawBlocks is! List || rawBlocks.length > _maxBlocks) {
    throw const FormatException('文库8首页数据格式无效或超出限制。');
  }
  final blocks = _parseBlocks(rawBlocks, expected);
  if (blocks.isEmpty || blocks.every((block) => block.list.isEmpty)) {
    throw const FormatException('首页中没有可用的文库8推荐书目。');
  }
  return List.unmodifiable(blocks);
}

bool _isHomeUri(Uri? uri, Uri expected) {
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != expected.host.toLowerCase() ||
      uri.port != expected.port ||
      uri.userInfo.isNotEmpty ||
      (uri.path != '/' && uri.path != '/index.php') ||
      uri.hasFragment) {
    return false;
  }
  final query = uri.queryParametersAll;
  return query.isEmpty ||
      (query.length == 1 &&
          query.containsKey('charset') &&
          query['charset']!.length == 1 &&
          query['charset']!.single.toLowerCase() == 'gbk');
}

/// Retained fixture/parser entry point. It applies the same book-field rules
/// to the known home recommendation regions without relying on block order.
List<HomeBlock> parseWenku8HomeIndexHtml(String sourceHtml) {
  if (sourceHtml.isEmpty || sourceHtml.length > _maxHtmlLength) {
    throw const FormatException('文库8首页数据为空或过大，请重新加载首页。');
  }
  final document = html.parse(sourceHtml);
  final base = Uri.parse('https://www.wenku8.net/');
  final roots = <dom.Element>[
    if (document.querySelector('#centers') case final center?) center,
    ...document.querySelectorAll('div.main'),
  ];
  if (roots.isEmpty) {
    throw const FormatException('文库8首页推荐区域未找到。');
  }
  final blocks = <HomeBlock>[];
  final seenSections = <dom.Element>{};
  var totalBooks = 0;
  for (final root in roots.take(_maxBlocks)) {
    for (final section in _sectionsFor(root).take(_maxBlocks)) {
      if (!seenSections.add(section)) continue;
      final title = _sectionTitle(section);
      if (title.isEmpty ||
          title == '文库Telegram群组' ||
          title.startsWith('轻小说文库公告')) {
        continue;
      }
      final covers = <NovelCover>[];
      final seenBooks = <String>{};
      for (final image in section
          .querySelectorAll('img')
          .take(_maxBooksPerBlock * 2)) {
        if (covers.length >= _maxBooksPerBlock ||
            totalBooks >= _maxBooksTotal) {
          break;
        }
        final card = _cardFor(image, section, base);
        if (card == null || seenBooks.contains(card.book.href)) continue;
        final imageSource = _imageUrl(image, base);
        if (imageSource == null) continue;
        final name = _cardTitle(card, image);
        if (name.isEmpty) continue;
        covers.add(
          NovelCover(
            title: name,
            img: imageSource,
            detailUrl: card.book.href,
            aid: card.book.aid,
          ),
        );
        seenBooks.add(card.book.href);
        totalBooks++;
      }
      if (covers.isNotEmpty) blocks.add(HomeBlock(title: title, list: covers));
    }
  }
  if (blocks.isEmpty) {
    throw const FormatException('首页中没有可用的文库8推荐书目。');
  }
  return List.unmodifiable(blocks);
}

List<HomeBlock> _parseBlocks(List rawBlocks, Uri expected) {
  final result = <HomeBlock>[];
  var totalBooks = 0;
  var payloadTextLength = 0;
  for (final rawBlock in rawBlocks) {
    if (rawBlock is! Map) continue;
    final rawTitle = rawBlock['title'];
    if (rawTitle is String) payloadTextLength += rawTitle.length;
    if (payloadTextLength > _maxPayloadLength) {
      throw const FormatException('文库8首页数据过大，请重新加载首页。');
    }
    final title =
        rawTitle is String ? _cleanText(rawTitle, _maxTitleLength) : '';
    final rawCovers = rawBlock['covers'];
    if (title.isEmpty ||
        rawCovers is! List ||
        rawCovers.length > _maxBooksPerBlock) {
      continue;
    }
    final covers = <NovelCover>[];
    final seen = <String>{};
    for (final rawCover in rawCovers) {
      if (totalBooks >= _maxBooksTotal) break;
      if (rawCover is! Map) continue;
      for (final key in const ['title', 'image', 'detailUrl', 'aid']) {
        final field = rawCover[key];
        if (field is String) payloadTextLength += field.length;
      }
      if (payloadTextLength > _maxPayloadLength) {
        throw const FormatException('文库8首页数据过大，请重新加载首页。');
      }
      final cover = _coverFromFields(
        title: rawCover['title'],
        image: rawCover['image'],
        detailUrl: rawCover['detailUrl'],
        expected: expected,
      );
      if (cover == null || seen.contains(cover.detailUrl)) continue;
      final aid = rawCover['aid'];
      if (aid is! String ||
          !RegExp(r'^\d+$').hasMatch(aid) ||
          aid != cover.aid) {
        continue;
      }
      covers.add(cover);
      seen.add(cover.detailUrl);
      totalBooks++;
    }
    if (covers.isNotEmpty) result.add(HomeBlock(title: title, list: covers));
  }
  return result;
}

List<dom.Element> _sectionsFor(dom.Element root) {
  final sections = <dom.Element>[];
  if (root.classes.contains('block')) sections.add(root);
  sections.addAll(root.querySelectorAll('.block'));
  if (sections.isEmpty) {
    for (final node in root.querySelectorAll(
      'section, article, h1, h2, h3, h4, .blocktitle',
    )) {
      final section =
          node.localName == 'section' || node.localName == 'article'
              ? node
              : node.parent;
      if (section != null && !sections.contains(section)) sections.add(section);
    }
  }
  return sections;
}

String _sectionTitle(dom.Element section) {
  final titleNode =
      section.classes.contains('blocktitle')
          ? section
          : section.querySelector('.blocktitle, h1, h2, h3, h4');
  if (titleNode == null || titleNode.querySelector('.txt') != null) {
    return '';
  }
  final title = _cleanText(titleNode.text, _maxTitleLength);
  if ((title == '广告' || title.startsWith('广告推广')) ||
      title == '文库Telegram群组' ||
      title.startsWith('轻小说文库公告')) {
    return '';
  }
  return title;
}

class _BookLink {
  const _BookLink(this.href, this.aid, this.anchor);

  final String href;
  final String aid;
  final dom.Element anchor;
}

class _BookCard {
  const _BookCard(this.book, this.anchor, this.card);

  final _BookLink book;
  final dom.Element anchor;
  final dom.Element card;
}

_BookLink? _validBookLink(dom.Element? anchor, Uri page) {
  if (anchor == null) return null;
  final raw = anchor.attributes['href']?.trim() ?? '';
  if (raw.isEmpty || raw.length > _maxUrlLength) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  final resolved = parsed.hasScheme ? parsed : page.resolveUri(parsed);
  final match = RegExp(r'^/book/(\d+)\.htm$').firstMatch(resolved.path);
  if (match == null ||
      (resolved.scheme != 'https' && resolved.scheme != 'http') ||
      resolved.host.toLowerCase() != page.host.toLowerCase() ||
      resolved.port != (resolved.scheme == 'http' ? 80 : 443) ||
      resolved.userInfo.isNotEmpty ||
      resolved.hasQuery ||
      resolved.hasFragment) {
    return null;
  }
  final secure = Uri(scheme: 'https', host: resolved.host, path: resolved.path);
  return _BookLink(secure.toString(), match.group(1)!, anchor);
}

List<_BookLink> _bookLinks(dom.Element node, Uri page) {
  final anchors = <dom.Element>[
    if (node.localName == 'a' && node.attributes.containsKey('href')) node,
    ...node.querySelectorAll('a[href]'),
  ];
  final links = <String, _BookLink>{};
  for (final anchor in anchors) {
    final link = _validBookLink(anchor, page);
    if (link != null) links.putIfAbsent(link.href, () => link);
  }
  return links.values.toList(growable: false);
}

_BookCard? _cardFor(dom.Element image, dom.Element section, Uri page) {
  final parentAnchor =
      image.parent is dom.Element &&
              (image.parent as dom.Element).localName == 'a'
          ? image.parent as dom.Element
          : null;
  if (parentAnchor != null) {
    final direct = _validBookLink(parentAnchor, page);
    if (direct == null) return null;
    final card = parentAnchor.parent;
    if (card != null && !_eligibleCard(card)) return null;
    if (card != null) {
      final siblings = _bookLinks(card, page);
      if (siblings.length == 1 &&
          siblings.single.href == direct.href &&
          _eligibleCard(card)) {
        return _BookCard(direct, direct.anchor, card);
      }
    }
    return _BookCard(direct, direct.anchor, direct.anchor);
  }
  dom.Element? node = image.parent;
  while (node != null && node != section.parent) {
    if (identical(node, section)) break;
    final candidates = _bookLinks(node, page);
    if (candidates.length == 1 && _eligibleCard(node)) {
      final book = candidates.single;
      return _BookCard(book, book.anchor, node);
    }
    node = node.parent;
  }
  return null;
}

String _cardTitle(_BookCard card, dom.Element image) {
  final fromTitle = _cleanText(
    card.anchor.attributes['title'],
    _maxTitleLength,
  );
  if (fromTitle.isNotEmpty) return fromTitle;
  final fromAlt = _cleanText(image.attributes['alt'], _maxTitleLength);
  if (fromAlt.isNotEmpty) return fromAlt;
  final fromLink = _cleanText(card.anchor.text, _maxTitleLength);
  if (fromLink.isNotEmpty) return fromLink;
  for (final anchor in card.card.querySelectorAll('a[href]')) {
    final sameBook = _validBookLink(anchor, Uri.parse(card.book.href));
    if (sameBook?.href == card.book.href && !identical(anchor, card.anchor)) {
      final text = _cleanText(anchor.text, _maxTitleLength);
      if (text.isNotEmpty) return text;
    }
  }
  final plainName = card.card.querySelector('a:not([href])');
  if (plainName != null) {
    final text = _cleanText(plainName.text, _maxTitleLength);
    if (text.isNotEmpty) return text;
  }
  return '';
}

bool _eligibleCard(dom.Element node) {
  if (node.querySelector('form, input, select, textarea') != null) return false;
  for (final item in node.querySelectorAll('*')) {
    final structural = '${item.id} ${item.classes.join(' ')}'.toLowerCase();
    if (structural.contains('login') || structural.contains('登录')) return false;
  }
  return true;
}

String? _imageUrl(dom.Element image, Uri page) {
  String raw = '';
  for (final key in const [
    'data-original',
    'data-original-src',
    'data-lazy-src',
    'data-src',
    'src',
  ]) {
    raw = image.attributes[key]?.trim() ?? '';
    if (raw.isNotEmpty) break;
  }
  if (raw.isEmpty) {
    final srcset = (image.attributes['data-srcset'] ??
            image.attributes['srcset'] ??
            '')
        .trim()
        .split(RegExp(r'\s+'));
    if (srcset.isNotEmpty) raw = srcset.first;
  }
  if (raw.isEmpty || raw.length > _maxUrlLength) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  final url = parsed.hasScheme ? parsed : page.resolveUri(parsed);
  final host = url.host.toLowerCase();
  final knownImageHost =
      host == 'wenku8.net' ||
      host.endsWith('.wenku8.net') ||
      host == 'wenku8.com' ||
      host.endsWith('.wenku8.com');
  if (!knownImageHost ||
      (url.scheme != 'http' && url.scheme != 'https') ||
      url.userInfo.isNotEmpty ||
      url.port != (url.scheme == 'http' ? 80 : 443)) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: url.host,
    path: url.path,
    query: url.hasQuery ? url.query : null,
  ).toString();
}

NovelCover? _coverFromFields({
  required Object? title,
  required Object? image,
  required Object? detailUrl,
  required Uri expected,
}) {
  if (title is! String || image is! String || detailUrl is! String) return null;
  final safeTitle = _cleanText(title, _maxTitleLength);
  final rawImage = image.trim();
  final rawDetail = detailUrl.trim();
  if (safeTitle.isEmpty ||
      rawImage.isEmpty ||
      rawImage.length > _maxUrlLength ||
      rawDetail.isEmpty ||
      rawDetail.length > _maxUrlLength) {
    return null;
  }
  final page = Uri.tryParse(rawDetail);
  if (page == null) return null;
  final resolved = page.hasScheme ? page : expected.resolveUri(page);
  final match = RegExp(r'^/book/(\d+)\.htm$').firstMatch(resolved.path);
  if (match == null ||
      (resolved.scheme != 'https' && resolved.scheme != 'http') ||
      resolved.host.toLowerCase() != expected.host.toLowerCase() ||
      resolved.port != (resolved.scheme == 'http' ? 80 : 443) ||
      resolved.userInfo.isNotEmpty ||
      resolved.hasQuery ||
      resolved.hasFragment) {
    return null;
  }
  final imageUri = Uri.tryParse(rawImage);
  if (imageUri == null) return null;
  final absoluteImage =
      imageUri.hasScheme ? imageUri : expected.resolveUri(imageUri);
  final imageHost = absoluteImage.host.toLowerCase();
  if (!((imageHost == 'wenku8.net' ||
          imageHost.endsWith('.wenku8.net') ||
          imageHost == 'wenku8.com' ||
          imageHost.endsWith('.wenku8.com')) &&
      (absoluteImage.scheme == 'http' || absoluteImage.scheme == 'https') &&
      absoluteImage.userInfo.isEmpty &&
      absoluteImage.port == (absoluteImage.scheme == 'http' ? 80 : 443))) {
    return null;
  }
  final secureImage =
      Uri(
        scheme: 'https',
        host: absoluteImage.host,
        path: absoluteImage.path,
        query: absoluteImage.hasQuery ? absoluteImage.query : null,
      ).toString();
  final secureDetail =
      Uri(scheme: 'https', host: resolved.host, path: resolved.path).toString();
  return NovelCover(
    title: safeTitle,
    img: secureImage,
    detailUrl: secureDetail,
    aid: match.group(1)!,
  );
}

String _cleanText(Object? input, int maxLength) {
  if (input == null) return '';
  final text = input.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isNotEmpty && text.length <= maxLength ? text : '';
}
