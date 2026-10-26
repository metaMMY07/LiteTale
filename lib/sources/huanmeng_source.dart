import 'dart:async';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

import 'book_source.dart';
import 'rule_book_source.dart' show readerTextFromHtml;

/// The caller owns HTTP, redirect, byte, Cookie and verification policies.
/// Implementations must return decoded JSON without evaluating source scripts.
abstract interface class HuanmengTransport {
  Future<Map<String, dynamic>> read(Uri uri);
}

class HuanmengSourceException implements Exception {
  const HuanmengSourceException(this.message);
  final String message;

  @override
  String toString() => message;
}

class HuanmengBudget {
  const HuanmengBudget({
    this.requestTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 30),
    this.maxChapters = 10000,
    this.maxCatalogPages = 3,
    this.maxListPages = 1000,
    this.maxContentCharacters = 2 * 1024 * 1024,
  });

  final Duration requestTimeout;
  final Duration operationTimeout;
  final int maxChapters;
  final int maxCatalogPages;
  final int maxListPages;
  final int maxContentCharacters;

  void _validate() {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(minutes: 1) ||
        operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(minutes: 2) ||
        maxChapters < 1 ||
        maxChapters > 20000 ||
        maxCatalogPages < 1 ||
        maxCatalogPages > 8 ||
        maxListPages < 1 ||
        maxListPages > 1000 ||
        maxContentCharacters < 1 ||
        maxContentCharacters > 4 * 1024 * 1024) {
      throw ArgumentError('幻梦 API 资源预算无效');
    }
  }
}

/// Public API contract confirmed against timyang2005/HuanmengPlugin's 9.0
/// adapter. The published integration key is not a user account credential.
/// These declarations are not evidence that the current network is reachable.
class HuanmengSource implements BookSource {
  HuanmengSource({
    required this.transport,
    this.budget = const HuanmengBudget(),
  }) {
    budget._validate();
  }

  static final Uri origin = Uri.parse('https://www.huanmengacg.com/');
  // https://github.com/timyang2005/HuanmengPlugin/blob/d285de64fdc6092d012f245619d759468ca31278/README.md
  static const publicApiKey = 'chiyu666';
  static const _pageSize = 20;
  static const _catalogPageSize = 5000;
  final HuanmengTransport transport;
  final HuanmengBudget budget;

  /// Checks only the current response before accepting visible verification.
  /// This does not execute HTML/JS, perform HTTP, or prove later catalog pages
  /// are complete. Unknown success-code conventions still require valid data.
  static bool canVerifyResponse(Uri target, Map<String, dynamic> envelope) {
    try {
      if (target.scheme != origin.scheme ||
          target.host != origin.host ||
          target.port != origin.port ||
          target.userInfo.isNotEmpty ||
          target.hasFragment) {
        return false;
      }
      const prefix = '/index.php/bookapi/';
      if (!target.path.startsWith(prefix)) return false;
      final operation = target.path.substring(prefix.length);
      if (!const {
        'search',
        'detail',
        'chapters',
        'content',
      }.contains(operation)) {
        return false;
      }
      String parameter(String key) {
        final values = target.queryParametersAll[key];
        if (values == null || values.length != 1) {
          throw const FormatException('缺少或重复的 API 编号');
        }
        return _numeric(values.single, 'API $key');
      }

      _checkFailure(envelope);
      final data = _map(envelope['data'], 'API data');
      if (operation == 'detail') {
        if (_numeric(data['id'], '详情书籍编号') != parameter('id')) return false;
        _text(data['name'], '书名', required: true);
        _text(data['author'], '作者');
        _text(data['pic'], '封面');
        _readerText(_text(data['intro'], '简介'), images: false);
        _tags(data['kind']);
        return true;
      }
      if (operation == 'content') {
        final bid = parameter('bid');
        final cid = parameter('cid');
        if ((data.containsKey('bid') &&
                _numeric(data['bid'], '正文书籍编号') != bid) ||
            (data.containsKey('cid') &&
                _numeric(data['cid'], '正文章节编号') != cid)) {
          return false;
        }
        final content = _readerText(
          _text(data['content'], '正文', required: true),
        );
        _rejectAccessNotice(content);
        return content.isNotEmpty;
      }
      final catalog = operation == 'chapters';
      final bid = catalog ? parameter('id') : null;
      final rows = _rows(
        data,
        catalog ? '章节列表' : '书目列表',
        catalog ? _catalogPageSize : _pageSize,
      );
      if (catalog && rows.isEmpty) return false;
      final total = _total(data);
      if (total != null && total < rows.length) return false;
      final seen = <String>{};
      for (final raw in rows) {
        final row = _map(raw, catalog ? '章节' : '书目');
        final numeric = _numeric(row['id'], catalog ? '章节编号' : '书籍编号');
        if (!seen.add(numeric)) return false;
        if (catalog && _numeric(row['bid'], '章节书籍编号') != bid) return false;
        _text(row['name'], catalog ? '章节名' : '书名', required: true);
        if (!catalog) _text(row['pic'], '封面');
      }
      return true;
    } catch (_) {
      // Invalid response data is never a successful verification signal.
      return false;
    }
  }

  @override
  SourceId get id => SourceId.huanmeng;

  @override
  Future<List<HomeBlock>> discover() async {
    final latest = await list();
    return [HomeBlock(title: '${id.label} · 最新更新', list: latest.records)];
  }

  Future<PageStatsNovelCover> list({int page = 1, int? tag, int? state}) {
    _page(page);
    if (tag != null && (tag < 1 || tag > 50)) {
      throw const FormatException('幻梦题材编号必须在 1–50 内');
    }
    if (state != null && state != 1 && state != 2) {
      throw const FormatException('幻梦连载状态只支持 1 或 2');
    }
    return _operation(
      (clock) => _books(
        {
          'page': '$page',
          'size': '$_pageSize',
          if (tag != null) 'tags': '$tag',
          if (state != null) 'state': '$state',
        },
        page,
        clock,
      ),
    );
  }

  @override
  Future<PageStatsNovelCover> search(String keyword, String type, int page) {
    if (type != 'title') throw UnsupportedError('幻梦 API 仅支持书名搜索');
    _page(page);
    final key = keyword.trim();
    if (key.isEmpty || key.length > 500) {
      throw const FormatException('搜索书名须为 1–500 字符');
    }
    return _operation(
      (clock) => _books(
        {'key': key, 'page': '$page', 'size': '$_pageSize'},
        page,
        clock,
      ),
    );
  }

  Future<PageStatsNovelCover> _books(
    Map<String, String> query,
    int page,
    _Clock clock,
  ) async {
    final data = await _read('search', query, clock);
    final rows = _rows(data, '书目列表', _pageSize);
    final records = <NovelCover>[];
    final seen = <String>{};
    for (final raw in rows) {
      clock.check();
      final row = _map(raw, '书目');
      final numeric = _numeric(row['id'], '书籍编号');
      if (!seen.add(numeric)) throw const FormatException('同一页书目编号重复');
      final localId = 'hm:$numeric';
      records.add(
        NovelCover(
          aid: localId,
          detailUrl: localId,
          title: _text(row['name'], '书名', required: true),
          img: _imageUrl(_text(row['pic'], '封面')) ?? '',
        ),
      );
    }
    if (data.containsKey('page') && '${data['page']}' != '$page') {
      throw const FormatException('幻梦书目分页未前进');
    }
    final total = _pageTotal(data, rows.length, page, _pageSize);
    int maxPage;
    if (total != null) {
      if (total > budget.maxListPages * _pageSize) {
        throw const HuanmengSourceException('幻梦书目总量超过分页资源上限');
      }
      if (records.isNotEmpty &&
          total < (page - 1) * _pageSize + records.length) {
        throw const FormatException('书目 total 与返回记录数量不一致');
      }
      maxPage = total == 0 ? 1 : (total + _pageSize - 1) ~/ _pageSize;
    } else {
      maxPage = records.length == _pageSize ? page + 1 : page;
      if (maxPage > budget.maxListPages) {
        throw const HuanmengSourceException('幻梦书目超过分页资源上限');
      }
    }
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: maxPage,
      records: records,
    );
  }

  @override
  Future<SourceBookDetail> detail(String bookId) {
    final bid = _bookId(bookId);
    return _operation((clock) async {
      final data = await _read('detail', {'id': bid}, clock);
      if (_numeric(data['id'], '详情书籍编号') != bid) {
        throw const FormatException('幻梦详情不属于当前书籍');
      }
      final name = _text(data['name'], '书名', required: true);
      final author = _text(data['author'], '作者');
      final pic = _imageUrl(_text(data['pic'], '封面')) ?? '';
      final intro = _readerText(
        _text(data['intro'], '简介'),
        images: false,
        maxCharacters: budget.maxContentCharacters,
      );
      final tags = _tags(data['kind']);
      // text_num has no counterpart in NovelInfo. Do not mislabel it as heat,
      // ranking, or completion status.
      final chapters = await _catalog(bid, bookId, clock);
      return SourceBookDetail(
        NovelInfo(
          title: name,
          author: author,
          status: '',
          finUpdate: '',
          imgUrl: pic,
          introduce: intro,
          tags: tags,
          heat: '',
          trending: '',
          isAnimated: false,
        ),
        [Volume(id: '$bookId:catalog', title: '目录', chapters: chapters)],
      );
    });
  }

  Future<List<Chapter>> _catalog(
    String bid,
    String bookId,
    _Clock clock,
  ) async {
    final chapters = <Chapter>[];
    final seen = <String>{};
    int? expectedTotal;
    for (var page = 1; page <= budget.maxCatalogPages; page++) {
      clock.check();
      final data = await _read('chapters', {
        'id': bid,
        'size': '$_catalogPageSize',
        if (page > 1) 'page': '$page',
      }, clock);
      final rows = _rows(data, '章节列表', _catalogPageSize);
      final total = _pageTotal(data, rows.length, page, _catalogPageSize);
      if (total != null) {
        if (total > budget.maxChapters) {
          throw HuanmengSourceException('幻梦目录超过 ${budget.maxChapters} 章上限');
        }
        if (expectedTotal != null && total != expectedTotal) {
          throw const FormatException('目录分页期间 total 改变，请重新加载');
        }
        expectedTotal = total;
      }
      if (chapters.length + rows.length > budget.maxChapters) {
        throw HuanmengSourceException('幻梦目录超过 ${budget.maxChapters} 章上限');
      }
      for (final raw in rows) {
        clock.check();
        final row = _map(raw, '章节');
        if (_numeric(row['bid'], '章节书籍编号') != bid) {
          throw const FormatException('幻梦目录章节不属于当前书籍');
        }
        final cid = _numeric(row['id'], '章节编号');
        if (!seen.add(cid)) {
          throw const FormatException('幻梦目录章节重复，接口分页未前进');
        }
        final localId = 'hm:$bid:$cid';
        chapters.add(
          Chapter(
            aid: bookId,
            cid: localId,
            url: localId,
            title: _text(row['name'], '章节名', required: true),
          ),
        );
      }
      if (expectedTotal != null && chapters.length > expectedTotal) {
        throw const FormatException('目录 total 小于实际章节数量');
      }
      final complete =
          expectedTotal != null
              ? chapters.length == expectedTotal
              : rows.length < _catalogPageSize;
      if (complete) {
        if (chapters.isEmpty) {
          throw const HuanmengSourceException('幻梦目录暂时没有可读章节');
        }
        return chapters;
      }
      if (rows.isEmpty) throw const FormatException('幻梦目录分页未完整返回');
    }
    throw const HuanmengSourceException('幻梦目录超过分页预算，未返回完整目录');
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) {
    final bid = _bookId(bookId);
    final match = RegExp(
      r'^hm:([1-9][0-9]{0,15}):([1-9][0-9]{0,15})$',
    ).firstMatch(chapterId);
    if (match == null || _numeric(match.group(1), '章节书籍编号') != bid) {
      throw const FormatException('幻梦章节编号无效或不属于当前书籍');
    }
    final cid = _numeric(match.group(2), '章节编号');
    return _operation((clock) async {
      final data = await _read('content', {'bid': bid, 'cid': cid}, clock);
      if ((data.containsKey('bid') && _numeric(data['bid'], '正文书籍编号') != bid) ||
          (data.containsKey('cid') && _numeric(data['cid'], '正文章节编号') != cid)) {
        throw const FormatException('幻梦正文编号与请求不一致');
      }
      final content = _readerText(
        _text(data['content'], '正文', required: true),
        maxCharacters: budget.maxContentCharacters,
      );
      clock.check();
      _rejectAccessNotice(content);
      if (content.isEmpty) throw const HuanmengSourceException('幻梦章节正文为空');
      return SourceChapter(content);
    });
  }

  Future<Map<String, dynamic>> _read(
    String endpoint,
    Map<String, String> query,
    _Clock clock,
  ) async {
    clock.check();
    final uri = origin
        .resolve('/index.php/bookapi/$endpoint')
        .replace(queryParameters: {'password': publicApiKey, ...query});
    final remaining = clock.remaining;
    final timeout =
        remaining < budget.requestTimeout ? remaining : budget.requestTimeout;
    Map<String, dynamic> envelope;
    try {
      envelope = await transport.read(uri).timeout(timeout);
    } on TimeoutException {
      throw const HuanmengSourceException('幻梦 API 请求超时');
    }
    clock.check();
    _checkFailure(envelope);
    return _map(envelope['data'], 'API data');
  }

  static int? _pageTotal(
    Map<String, dynamic> data,
    int rows,
    int page,
    int size,
  ) {
    // The current published API reports total=rows and pages=1 on EVERY page,
    // even page two. Those are page-local counters, not the library's size.
    // Preserve strict global-total checks for envelopes without this signature.
    if ('${data['page']}' == '$page' &&
        '${data['size']}' == '$size' &&
        '${data['pages']}' == '1' &&
        '${data['total']}' == '$rows') {
      return null;
    }
    return _total(data);
  }

  Future<T> _operation<T>(Future<T> Function(_Clock) run) {
    final clock = _Clock(budget.operationTimeout);
    return Future<T>.sync(() => run(clock)).timeout(
      budget.operationTimeout,
      onTimeout: () => throw const HuanmengSourceException('幻梦 API 操作超过总时限'),
    );
  }

  void _page(int page) {
    if (page < 1 || page > budget.maxListPages) {
      throw const FormatException('幻梦页码超出范围');
    }
  }

  static String _readerText(
    String source, {
    bool images = true,
    int maxCharacters = 2 * 1024 * 1024,
  }) {
    if (source.length > maxCharacters) {
      throw const HuanmengSourceException('幻梦正文或简介超过字符资源上限');
    }
    final fragment = html.parseFragment(source);
    final stack = <(dom.Node, int)>[(fragment, 0)];
    var visited = 0;
    const blocked = {
      'script',
      'style',
      'iframe',
      'frame',
      'form',
      'object',
      'embed',
      'svg',
      'math',
      'template',
      'base',
      'link',
      'meta',
      'noscript',
    };
    while (stack.isNotEmpty) {
      final (node, depth) = stack.removeLast();
      if (++visited > 50000 || depth > 128) {
        throw const HuanmengSourceException('幻梦正文 DOM 超过资源预算');
      }
      if (node is dom.Comment) {
        node.remove();
        continue;
      }
      if (node is dom.Text) {
        // Reader image markers are control data: ordinary escaped HTML text
        // must not be able to manufacture an unchecked image URL.
        node.text = node.text.replaceAll('<!--image-->', '＜!--image--＞');
        continue;
      }
      if (node is dom.Element) {
        if (blocked.contains(node.localName)) {
          node.remove();
          continue;
        }
        if (node.localName == 'img') {
          final url =
              images
                  ? _imageUrl(
                    node.attributes['src'] ??
                        node.attributes['data-src'] ??
                        node.attributes['data-original'] ??
                        '',
                  )
                  : null;
          if (url == null) {
            node.remove();
            continue;
          }
          node.attributes
            ..clear()
            ..['src'] = url;
        } else {
          node.attributes.clear();
        }
      }
      for (final child in node.nodes.reversed) {
        stack.add((child, depth + 1));
      }
    }
    final result = readerTextFromHtml(fragment.outerHtml).trim();
    if (result.length > maxCharacters) {
      throw const HuanmengSourceException('幻梦正文超过字符资源上限');
    }
    return result;
  }
}

class _Clock {
  _Clock(Duration limit) : deadline = DateTime.now().add(limit);
  final DateTime deadline;
  Duration get remaining => deadline.difference(DateTime.now());
  void check() {
    if (remaining <= Duration.zero) {
      throw const HuanmengSourceException('幻梦 API 操作超过总时限');
    }
  }
}

Map<String, dynamic> _map(dynamic value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$field 必须是对象');
  }
  return Map<String, dynamic>.from(value);
}

List<dynamic> _rows(Map<String, dynamic> data, String field, int max) {
  final list = data['list'];
  if (list is! List) throw FormatException('$field缺少 data.list 数组');
  if (list.length > max) throw HuanmengSourceException('$field超过请求数量上限');
  return list;
}

String _text(dynamic value, String field, {bool required = false}) {
  if (value == null && !required) return '';
  if (value is! String || (required && value.trim().isEmpty)) {
    throw FormatException('$field必须是${required ? '非空' : ''}字符串');
  }
  return value.trim();
}

String _numeric(dynamic value, String field) {
  final text = value is int ? '$value' : value;
  if (text is! String || !RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(text)) {
    throw FormatException('$field必须是正整数编号');
  }
  final number = int.tryParse(text);
  if (number == null || number > 9007199254740991) {
    throw FormatException('$field超出安全编号范围');
  }
  return text;
}

String _bookId(String id) {
  final match = RegExp(r'^hm:([1-9][0-9]{0,15})$').firstMatch(id);
  if (match == null) throw const FormatException('幻梦书籍编号无效');
  return _numeric(match.group(1), '书籍编号');
}

int? _total(Map<String, dynamic> data) {
  final raw = data['total'];
  if (raw == null) return null;
  final value =
      raw is int
          ? raw
          : raw is String
          ? int.tryParse(raw)
          : null;
  if (value == null || value < 0) {
    throw const FormatException('API total 必须是非负记录总数');
  }
  return value;
}

List<String> _tags(dynamic value) {
  if (value == null || value == '') return const [];
  final parts = value is String ? value.split(RegExp(r'[,，、|]+')) : value;
  if (parts is! List || parts.length > 100) {
    throw const FormatException('幻梦分类格式无效');
  }
  return parts
      .map((part) => _text(part, '分类'))
      .where((part) => part.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

void _checkFailure(Map<String, dynamic> envelope) {
  final error = envelope['error'];
  if (error != null && error != false && error != 0 && error != '') {
    throw const HuanmengSourceException('幻梦 API 返回明确错误');
  }
  if (envelope['success'] == false) {
    throw const HuanmengSourceException('幻梦 API 返回失败');
  }
  final code = envelope['code'];
  final numericCode =
      code is num
          ? code
          : code is String
          ? num.tryParse(code)
          : null;
  if (code == false ||
      (numericCode != null && (numericCode < 0 || numericCode >= 400))) {
    throw HuanmengSourceException('幻梦 API 返回失败代码：$code');
  }
  final failure = RegExp(
    r'错误|失败|拒绝|封禁|限流|无权|不存在|维护|密码.{0,12}(?:错|无效)|(?:error|fail|denied|forbidden|unauthori[sz]ed|invalid|rate.?limit|blocked|not.?found|unavailable|maintenance)',
    caseSensitive: false,
  );
  for (final key in const ['code', 'message', 'msg']) {
    final value = envelope[key];
    if (value is String && failure.hasMatch(value)) {
      throw const HuanmengSourceException('幻梦 API 返回失败信息');
    }
  }
  // Success code values have not been observed on the live API. Valid required
  // data, not a guessed code=0/1/200 convention, determines successful parsing.
}

void _rejectAccessNotice(String text) {
  final normalized = text.replaceAll(RegExp(r'\s+'), '');
  if (normalized.length <= 4096 &&
      (normalized.contains('接口密码错误') || normalized.contains('接口密碼錯誤')) &&
      (normalized.contains('无法获取数据') ||
          normalized.contains('無法獲取數據') ||
          normalized.contains('新的接口密码') ||
          normalized.contains('新的接口密碼'))) {
    throw const HuanmengSourceException('幻梦原站已更换接口密码，当前接口暂不可用，请切换其他书源。');
  }
}

String? _imageUrl(String raw) {
  if (raw.isEmpty ||
      raw.length > 4096 ||
      raw.contains(RegExp(r'[\x00-\x20\x7f]'))) {
    return null;
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  final uri = HuanmengSource.origin.resolveUri(parsed);
  if (!const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      _privateHost(uri.host)) {
    return null;
  }
  return uri.toString();
}

bool _privateHost(String raw) {
  final host = raw
      .toLowerCase()
      .replaceAll(RegExp(r'\.$'), '')
      .replaceAll('[', '')
      .replaceAll(']', '');
  if (host == 'localhost' ||
      const [
        '.localhost',
        '.local',
        '.internal',
        '.lan',
        '.home',
      ].any(host.endsWith)) {
    return true;
  }
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    // Refuse nonstandard numeric IPv4 spellings and local single-label names.
    return !host.contains('.') ||
        RegExp(
          r'^(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+)){0,3}$',
        ).hasMatch(host);
  }
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _privateV4(bytes);
  if (bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    return _privateV4(bytes.sublist(12));
  }
  if (bytes.take(12).every((byte) => byte == 0)) return true;
  return (bytes[0] & 0xe0) != 0x20 ||
      (bytes[0] == 0x20 &&
          bytes[1] == 1 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8);
}

bool _privateV4(List<int> bytes) {
  final a = bytes[0];
  final b = bytes[1];
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      a >= 224 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 198 && (b == 18 || b == 19));
}
