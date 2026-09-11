import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/src/rust/api/font.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'book_source.dart';
import 'shelf_session.dart';

typedef ShelfInvoke =
    Future<Object?> Function(String method, Map<String, Object?> args);

Object? shelfPayload(Object? value) {
  if (value is! Map) throw const FormatException('轻书架响应格式不正确');
  if ((value['Success'] ?? value['success']) != true) {
    final message = '${value['Msg'] ?? value['msg'] ?? '请求未完成'}';
    throw StateError('轻书架：$message。需要账号时请前往设置登录');
  }
  return _normalizeShelfFields(value['Response'] ?? value['response']);
}

// SignalR JSON camel-cases DTOs, while dictionary book cards keep PascalCase.
Object? _normalizeShelfFields(Object? value) {
  if (value is Map) {
    return value.map((key, child) {
      final text = '$key';
      return MapEntry(
        text.isEmpty ? text : text[0].toUpperCase() + text.substring(1),
        _normalizeShelfFields(child),
      );
    });
  }
  if (value is List) return value.map(_normalizeShelfFields).toList();
  return value;
}

/// Converts HTML into the shared reader's ordered text/image stream.
String shelfReaderContent(String input) {
  final document = html.parseFragment(input);
  final out = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      out.write(node.text);
      return;
    }
    if (node is dom.Element) {
      if (['script', 'style', 'iframe'].contains(node.localName)) return;
      if (node.localName == 'img') {
        final raw = node.attributes['src'] ?? node.attributes['data-src'] ?? '';
        final uri = Uri.parse('https://www.lightnovel.app/').resolve(raw);
        if (raw.isNotEmpty && ['https', 'http'].contains(uri.scheme)) {
          out.write('<!--image-->$uri<!--image-->');
        }
        return;
      }
      if (node.localName == 'br') {
        out.writeln();
        return;
      }
    }
    for (final child in node.nodes) {
      walk(child);
    }
    if (node is dom.Element &&
        [
          'p',
          'div',
          'section',
          'h1',
          'h2',
          'h3',
          'li',
          'blockquote',
        ].contains(node.localName)) {
      out.writeln();
    }
  }

  walk(document);
  return out.toString().trim();
}

NovelCover shelfCover(Map raw) => NovelCover(
  aid: shelfBookId(raw['Id']),
  title: '${raw['Title'] ?? ''}',
  img: '${raw['Cover'] ?? ''}',
  detailUrl: 'https://www.lightnovel.app/book/info/${raw['Id']}',
);

SourceBookDetail shelfDetail(Map payload) {
  payload = _normalizeShelfFields(payload) as Map;
  final book = payload['Book'];
  if (book is! Map || book['Id'] == null) {
    throw const FormatException('轻书架书籍信息缺失');
  }
  final id = shelfBookId(book['Id']);
  final category = book['Category'];
  final info = NovelInfo(
    title: '${book['Title'] ?? ''}',
    author: '${book['Author'] ?? book['Arthur'] ?? ''}',
    status: '轻书架',
    finUpdate: '${book['LastUpdatedAt'] ?? ''}',
    imgUrl: '${book['Cover'] ?? ''}',
    introduce: '${book['Introduction'] ?? ''}',
    tags: [
      if (category is Map && category['Name'] != null) '${category['Name']}',
    ],
    heat: '${book['Views'] ?? 0}',
    trending: '${book['Favorite'] ?? 0}',
    isAnimated: false,
  );
  final chapters =
      ((book['Chapter'] ?? book['Chapters']) as List? ?? [])
          .whereType<Map>()
          .map(
            (c) => Chapter(
              title: '${c['Title'] ?? ''}',
              url: '',
              aid: id,
              cid: '$id:${c['Id']}',
            ),
          )
          .toList();
  return SourceBookDetail(info, [
    Volume(id: id, title: info.title, chapters: chapters),
  ]);
}

class LightNovelShelfSource implements BookSource {
  LightNovelShelfSource({ShelfInvoke? invoke}) : _invoke = invoke ?? _call;
  final ShelfInvoke _invoke;
  final _details = <String, SourceBookDetail>{};
  final _pendingDetails = <String, Future<SourceBookDetail>>{};
  final _fonts = <String, String>{};
  int _fontSequence = 0;
  int _sessionGeneration = 0;
  @override
  SourceId get id => SourceId.lightNovelShelf;

  static Future<Object?> _call(String method, Map<String, Object?> args) async {
    final session = ShelfSession.instance;
    final token = await session.token();
    final raw = await LightNovelShelfService.instance.invoke(
      method,
      args,
      token: token,
    );
    return shelfPayload(raw);
  }

  void clearSessionCache() {
    _sessionGeneration++;
    _details.clear();
    _pendingDetails.clear();
  }

  Future<PageStatsNovelCover> list({
    int page = 1,
    String order = 'latest',
    int? category,
  }) async {
    final payload = await _invoke('GetBookList', {
      'Page': page,
      'Size': 20,
      'Order': order,
      if (category != null) 'CategoryId': category,
      'IgnoreJapanese': false,
      'IgnoreAI': false,
    });
    return _page(payload, page);
  }

  PageStatsNovelCover _page(Object? raw, int page) {
    if (raw is! Map || (raw['Data'] ?? raw['data']) is! List) {
      throw const FormatException('轻书架列表缺失');
    }
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: (((raw['TotalPages'] ?? raw['totalPages']) as num?)?.toInt() ??
              page)
          .clamp(1, 100000),
      records:
          ((raw['Data'] ?? raw['data']) as List)
              .whereType<Map>()
              .map(shelfCover)
              .toList(),
    );
  }

  @override
  Future<List<HomeBlock>> discover() async {
    // This endpoint intentionally allows a six-book preview before login.
    final raw = shelfPayload(
      await LightNovelShelfService.instance.invoke('GetLatestBookList', {
        'Page': 1,
        'Size': 6,
        'Order': 'latest',
        'IgnoreJapanese': false,
        'IgnoreAI': false,
      }),
    );
    return [HomeBlock(title: '近期录入', list: _page(raw, 1).records)];
  }

  @override
  Future<PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) async => _page(
    await _invoke(
      type == 'author' ? 'GetBookListByAuthor' : 'GetBookListByTitle',
      {
        'Page': page,
        'Size': 20,
        'KeyWords': keyword.trim(),
        'IgnoreJapanese': false,
        'IgnoreAI': false,
      },
    ),
    page,
  );

  Future<List<Map>> categories() async =>
      (await _invoke('GetBookCategories', {'Type': 'Novel'}) as List)
          .whereType<Map>()
          .toList();

  Future<PageStatsNovelCover> rank(int days) async => PageStatsNovelCover(
    currentPage: 1,
    maxPage: 1,
    records:
        (await _invoke('GetRank', {'Days': days}) as List)
            .whereType<Map>()
            .map(shelfCover)
            .toList(),
  );

  @override
  Future<SourceBookDetail> detail(String bookId) {
    final generation = _sessionGeneration;
    return _pendingDetails[bookId] ??= _loadDetail(bookId).whenComplete(() {
      if (generation == _sessionGeneration) _pendingDetails.remove(bookId);
    });
  }

  Future<SourceBookDetail> _loadDetail(String bookId) async {
    final generation = _sessionGeneration;
    final result = shelfDetail(
      await _invoke('GetBookInfo', {'Id': remoteShelfId(bookId)}) as Map,
    );
    if (generation == _sessionGeneration) _details[bookId] = result;
    return result;
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    final book = _details[bookId] ?? await detail(bookId);
    final index = book.volumes
        .expand((v) => v.chapters)
        .toList()
        .indexWhere((c) => c.cid == chapterId);
    if (index < 0) throw StateError('章节已变更，请返回目录刷新');
    final raw = _normalizeShelfFields(
      await _invoke('GetNovelContent', {
        'Bid': remoteShelfId(bookId),
        'SortNum': index + 1,
      }),
    );
    final chapter = raw is Map ? raw['Chapter'] : null;
    if (chapter is! Map || chapter['Content'] is! String) {
      throw const FormatException('章节内容缺失');
    }
    final font = '${chapter['Font'] ?? ''}';
    String? family;
    if (font.isNotEmpty) {
      family = _fonts[font];
      if (family == null) {
        final uri = Uri.parse('https://api.lightnovel.life/').resolve(font);
        if (uri.scheme != 'https') throw const FormatException('章节字体地址无效');
        final response = await http
            .get(uri, headers: {'Referer': 'https://www.lightnovel.app/'})
            .timeout(const Duration(seconds: 25));
        if (response.statusCode != 200) throw StateError('章节字体加载失败，请重试');
        family = 'LiteTaleShelf${_fontSequence++}';
        final decoded = await decodeChapterFont(data: response.bodyBytes);
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(decoded)));
        await loader.load();
        _fonts[font] = family;
      }
    }
    return SourceChapter(
      shelfReaderContent(chapter['Content'] as String),
      fontFamily: family,
    );
  }
}
