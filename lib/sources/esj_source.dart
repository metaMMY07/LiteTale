import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'book_source.dart';
import 'rule_book_source.dart' show readerTextFromHtml;
import 'rules/rule_source_engine.dart' show RuleSourceTransport;
import 'rules/scoped_rule_transport.dart';

class EsjSourceException implements Exception {
  const EsjSourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The site's ordinary public pages. No private API, imported script execution,
/// login automation or alternate hosts. Books requiring login stay restricted.
class EsjSource implements BookSource {
  EsjSource({
    RuleSourceTransport? transport,
    this.spacing = const Duration(milliseconds: 350),
  }) : _transport = transport ?? ScopedRuleSourceTransport(origin: origin);
  static final origin = Uri.parse('https://www.esjzone.cc/');
  final RuleSourceTransport _transport;
  final Duration spacing;
  final _flights = <Uri, Future<dom.Document>>{};
  Future<void> _tail = Future.value();
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _cooldown;
  static const _budget = Duration(seconds: 15);
  static const _maxBytes = 2 * 1024 * 1024;
  static const categories = <Map<String, Object>>[
    {'Id': 1, 'Name': '異世界'},
    {'Id': 2, 'Name': '奇幻'},
    {'Id': 3, 'Name': '魔法'},
    {'Id': 4, 'Name': '戀愛'},
    {'Id': 5, 'Name': '日常'},
    {'Id': 6, 'Name': '冒險'},
  ];

  @override
  SourceId get id => SourceId.esj;

  Future<dom.Document> _get(Uri uri) {
    if (uri.origin != origin.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('ESJ 只能读取原站公开页面');
    }
    final previous = _flights[uri];
    if (previous != null) return previous;
    if (_flights.length >= 16) {
      throw const EsjSourceException('ESJ 请求排队已满，请稍后重试');
    }
    final deadline = DateTime.now().add(_budget);
    final task = _tail.then((_) async {
      final wait = _next.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      var remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('ESJ 请求排队超时');
      if (_cooldown?.isAfter(DateTime.now()) == true) {
        throw const EsjSourceException('ESJ 请求过于频繁，请稍后重试');
      }
      _next = DateTime.now().add(spacing);
      if (remaining > const Duration(seconds: 12)) {
        remaining = const Duration(seconds: 12);
      }
      final response = await _transport
          .get(uri, timeout: remaining, maxBytes: _maxBytes)
          .timeout(remaining);
      if (response.statusCode == 429) {
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        final date =
            seconds == null
                ? _httpDate(response.headers['retry-after'])
                : DateTime.now().add(
                  Duration(seconds: seconds.clamp(1, 604800)),
                );
        final fallback = DateTime.now().add(const Duration(seconds: 60));
        final cap = DateTime.now().add(const Duration(days: 7));
        _cooldown =
            date == null || date.isBefore(DateTime.now())
                ? fallback
                : date.isAfter(cap)
                ? cap
                : date;
        throw const EsjSourceException('ESJ 请求过于频繁，请稍后重试');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const EsjSourceException('ESJ 原站暂不允许访问，请在原站确认阅读权限或稍后重试');
      }
      if (response.statusCode != 200) {
        throw EsjSourceException('ESJ 页面暂不可用（HTTP ${response.statusCode}）');
      }
      if (response.bytes.length > _maxBytes) {
        throw const FormatException('ESJ 页面超过大小上限');
      }
      final doc = html.parse(utf8.decode(response.bytes));
      final title = doc.querySelector('title')?.text ?? '';
      if (!title.contains('ESJ Zone') ||
          doc.querySelector(
                '#challenge-form, .cf-error-details, input[type="password"]',
              ) !=
              null) {
        throw const EsjSourceException('ESJ 返回了验证或限制页面，请在原站确认后重试');
      }
      return doc;
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    final bounded = task.timeout(_budget);
    _flights[uri] = bounded;
    bounded.then<void>(
      (_) {
        if (identical(_flights[uri], bounded)) _flights.remove(uri);
      },
      onError: (Object _, StackTrace __) {
        if (identical(_flights[uri], bounded)) _flights.remove(uri);
      },
    );
    return bounded;
  }

  static DateTime? _httpDate(String? value) {
    if (value == null) return null;
    // RFC 7231 dates use English month abbreviations, independent of locale.
    final match = RegExp(
      r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    if (match == null || !months.contains(match[2])) return null;
    return DateTime.utc(
      int.parse(match[3]!),
      months.indexOf(match[2]!) + 1,
      int.parse(match[1]!),
      int.parse(match[4]!),
      int.parse(match[5]!),
      int.parse(match[6]!),
    );
  }

  static String _book(String value) {
    final m = RegExp(r'^esj:([1-9][0-9]{0,17})$').firstMatch(value);
    if (m == null) throw const FormatException('无效的 ESJ 书籍编号');
    return m[1]!;
  }

  /// Keywords follow the original site's /tags/ search, which searches names,
  /// tags and authors. No fake client-side filtering of the first page.
  Future<PageStatsNovelCover> list({
    int page = 1,
    String? keyword,
    bool popular = false,
  }) async {
    if (page < 1 || page > 1000) throw const FormatException('ESJ 列表页码超出范围');
    final key = keyword?.trim() ?? '';
    if (key.length > 120 || key.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('搜索关键词过长或无效');
    }
    final route = key.isEmpty ? 'list-2${popular ? 4 : 1}' : 'tags-21';
    final uri = Uri(
      scheme: 'https',
      host: origin.host,
      pathSegments: [
        route,
        if (key.isNotEmpty) key,
        if (page > 1) '$page.html' else '',
      ],
    );
    final doc = await _get(uri);
    if (doc.querySelector('.shop-toolbar') == null) {
      throw const FormatException('ESJ 列表结构已变化');
    }
    final records = <NovelCover>[];
    final seen = <String>{};
    for (final card in doc.querySelectorAll('.card.mb-30')) {
      final a = card.querySelector('.card-title a[href]');
      final raw = a?.attributes['href'] ?? '';
      final link = origin.resolve(raw);
      final m = RegExp(
        r'^/detail/([1-9][0-9]{0,17})\.html$',
      ).firstMatch(link.path);
      final title = a?.text.trim() ?? '';
      if (link.origin != origin.origin ||
          m == null ||
          title.isEmpty ||
          !seen.add(m[1]!)) {
        continue;
      }
      final image = card.querySelector('.lazyload, img');
      records.add(
        NovelCover(
          aid: 'esj:${m[1]}',
          title: title,
          img: _image(
            image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
          ),
          detailUrl: link.toString(),
        ),
      );
    }
    if (records.length > 80) throw const FormatException('ESJ 列表数量超过上限');
    final scripts = doc
        .querySelectorAll('script:not([src])')
        .where((s) => s.text.contains('.bootpag('))
        .map((s) => s.text)
        .join('\n');
    final total = int.tryParse(
      RegExp(r'\btotal\s*:\s*(\d+)').firstMatch(scripts)?[1] ?? '',
    );
    final current = int.tryParse(
      RegExp(r'\bpage\s*:\s*(\d+)').firstMatch(scripts)?[1] ?? '',
    );
    if (total == null ||
        current != page ||
        total < 0 ||
        total > 1000 ||
        (records.isNotEmpty && total < page)) {
      throw const FormatException('ESJ 列表分页结构已变化');
    }
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: records.isEmpty ? page : total,
      records: records,
    );
  }

  @override
  Future<List<HomeBlock>> discover() async => [
    HomeBlock(title: 'ESJ Zone · 最近更新', list: (await list()).records),
  ];

  @override
  Future<PageStatsNovelCover> search(String keyword, String type, int page) =>
      list(page: page, keyword: keyword);

  @override
  Future<SourceBookDetail> detail(String bookId) async {
    final bid = _book(bookId);
    final doc = await _get(origin.resolve('detail/$bid.html'));
    final profile = doc.querySelector('div.book-detail');
    final title = profile?.querySelector('h2')?.text.trim() ?? '';
    final catalog = doc.querySelector('#chapterList');
    if (title.isEmpty || catalog == null) {
      throw const FormatException('ESJ 书籍详情或目录未公开');
    }
    final meta = <String, String>{};
    for (final li in profile!.querySelectorAll('ul.book-detail > li')) {
      final name = li.querySelector('strong')?.text.replaceAll(':', '').trim();
      if (name != null) {
        meta[name] =
            li.text.replaceFirst(li.querySelector('strong')!.text, '').trim();
      }
    }
    final volumes = <Volume>[];
    var heading = '正文';
    var chapters = <Chapter>[];
    final seen = <String>{};
    void flush() {
      if (chapters.isEmpty) return;
      volumes.add(
        Volume(
          id: '$bookId:v${volumes.length}',
          title: heading,
          chapters: chapters,
        ),
      );
      chapters = <Chapter>[];
    }

    void visit(dom.Element element, int depth) {
      if (depth > 24) throw const FormatException('ESJ 目录嵌套超过上限');
      if (element.localName != 'a') {
        if (element.localName == 'summary') return;
        if (element.children.any(
          (c) => c.localName == 'a' || c.querySelector('a') != null,
        )) {
          final parentHeading = heading;
          final summary =
              element.localName == 'details'
                  ? element.querySelector('summary')?.text.trim()
                  : null;
          if (summary != null && summary.isNotEmpty) {
            flush();
            heading = summary;
          }
          for (final child in element.children) {
            visit(child, depth + 1);
          }
          if (summary != null && summary.isNotEmpty) {
            flush();
            heading = parentHeading;
          }
          return;
        }
        final text = element.text.trim();
        if (text.isNotEmpty && text.length < 200) {
          flush();
          heading = text;
        }
        return;
      }
      final uri = origin.resolve(element.attributes['href'] ?? '');
      final match = RegExp(
        '^/forum/$bid/([1-9][0-9]{0,17})\\.html\$',
      ).firstMatch(uri.path);
      // External translation links stay on the original site, not fetched as
      // another book under this book's identity.
      if (uri.origin != origin.origin ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          match == null) {
        return;
      }
      if (!seen.add(match[1]!)) return;
      final name = element.text.trim();
      if (name.isEmpty) return;
      chapters.add(
        Chapter(
          aid: bookId,
          cid: '$bookId:${match[1]}',
          title: name,
          url: uri.toString(),
        ),
      );
      if (seen.length > 10000) throw const FormatException('ESJ 目录超过一万章上限');
    }

    for (final element in catalog.children) {
      visit(element, 0);
    }
    flush();
    if (volumes.isEmpty) {
      throw const EsjSourceException('本书没有原站公开章节，外部链接或需登录内容请前往原站阅读');
    }
    final image = doc.querySelector(
      '.product-gallery img, .product-gallery .lazyload',
    );
    return SourceBookDetail(
      NovelInfo(
        title: title,
        author: meta['作者'] ?? '',
        status: meta['類型'] ?? '',
        finUpdate: meta['更新日期'] ?? '',
        imgUrl: _image(
          image?.attributes['src'] ?? image?.attributes['data-src'] ?? '',
        ),
        introduce: doc.querySelector('.description')?.text.trim() ?? '',
        tags:
            doc
                .querySelectorAll('.tags a')
                .map((a) => a.text.trim())
                .where((s) => s.isNotEmpty)
                .take(30)
                .toList(),
        heat: '',
        trending: '',
        isAnimated: false,
      ),
      volumes,
    );
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    final bid = _book(bookId);
    final match = RegExp(
      '^esj:$bid:([1-9][0-9]{0,17})\$',
    ).firstMatch(chapterId);
    if (match == null) throw const FormatException('ESJ 章节与书籍不匹配');
    final doc = await _get(origin.resolve('forum/$bid/${match[1]}.html'));
    final body = doc.querySelector('.forum-content');
    if (body == null) throw const EsjSourceException('本章正文未公开或需要原站登录，请前往原站确认');
    final copy = body.clone(true);
    for (final element in copy.querySelectorAll(
      'script,style,iframe,form,button,object,embed,svg,canvas,nav',
    )) {
      element.remove();
    }
    void sanitize(dom.Node node) {
      if (node is dom.Text) node.text = node.text.replaceAll('<!--', '＜!--');
      for (final child in node.nodes.toList()) {
        if (child is dom.Comment) {
          child.remove();
        } else {
          sanitize(child);
        }
      }
    }

    sanitize(copy);
    for (final img in copy.querySelectorAll('img')) {
      final value = _image(
        img.attributes['data-src'] ?? img.attributes['src'] ?? '',
      );
      if (value.isEmpty) {
        img.remove();
      } else {
        img.attributes['src'] = value;
      }
    }
    final content = readerTextFromHtml(copy.outerHtml).trim();
    if (content.isEmpty) throw const FormatException('ESJ 正文为空，请稍后重试');
    return SourceChapter(content);
  }

  static String _image(String raw) {
    if (raw.isEmpty ||
        raw.length > 4096 ||
        raw.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      return '';
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null) return '';
    final uri = origin.resolveUri(parsed);
    final host = uri.host.toLowerCase();
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$').hasMatch(host) ||
        [
          '.local',
          '.localhost',
          '.internal',
          '.lan',
          '.home',
        ].any(host.endsWith)) {
      return '';
    }
    return uri.toString();
  }
}
