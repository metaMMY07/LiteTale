import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'book_source.dart';
import 'rules/rule_source.dart';

String ruleBookId(String sourceId, String url) =>
    'src:$sourceId:${base64Url.encode(utf8.encode(url)).replaceAll('=', '')}';

String ruleBookUrl(String id, String sourceId) {
  if (sourceOf(id) != SourceId.rule(sourceId)) {
    throw const FormatException('书籍不属于当前书源');
  }
  try {
    return utf8.decode(base64Url.decode(base64Url.normalize(id.split(':')[2])));
  } catch (_) {
    throw const FormatException('书源地址无效');
  }
}

class RuleBookSource implements BookSource {
  RuleBookSource(this.definition, {RuleSourceEngine? engine})
    : engine = engine ?? RuleSourceEngine(definition);
  final RuleSourceDefinition definition;
  final RuleSourceEngine engine;
  final _nextPages = <(String, int), String>{};
  final _seenNext = <String, Set<String>>{};
  final _queryGenerations = <String, int>{};
  int _generation = 0;
  void _recordPage(String key, int page, RulePage<RuleSourceBook> result) {
    final next = result.nextPageUrl;
    if (next == null) return;
    final seen = _seenNext.putIfAbsent(key, () => <String>{});
    if (!seen.add(next)) throw const FormatException('书源分页链接循环，请重试或更新规则');
    _nextPages[(key, page + 1)] = next;
    // Bound interactive query state, independently from the response limits.
    if (_seenNext.length > 16) {
      final expired = _seenNext.keys.first;
      _seenNext.remove(expired);
      _queryGenerations.remove(expired);
      _nextPages.removeWhere((value, _) => value.$1 == expired);
    }
  }

  @override
  SourceId get id => SourceId.rule(definition.id, label: definition.name);
  bool get hasSearch => definition.capabilities.search;

  NovelCover _cover(RuleSourceBook book) => NovelCover(
    aid: ruleBookId(definition.id, book.detailUrl),
    title: book.title,
    img: book.coverUrl,
    detailUrl: book.detailUrl,
  );

  @override
  Future<List<HomeBlock>> discover() async {
    if (!definition.capabilities.discover) return const [];
    final books = await engine.discover();
    return [
      HomeBlock(title: definition.name, list: books.map(_cover).toList()),
    ];
  }

  Future<PageStatsNovelCover> listPage(int page) async {
    if (page == 1) {
      _nextPages.removeWhere((key, _) => key.$1 == '#catalog');
      _seenNext.remove('#catalog');
      _queryGenerations['#catalog'] = ++_generation;
    }
    final generation = _queryGenerations.putIfAbsent(
      '#catalog',
      () => ++_generation,
    );
    final result = await engine.discoverPage(
      page: page,
      nextPageUrl: _nextPages[('#catalog', page)],
    );
    if (_queryGenerations['#catalog'] == generation) {
      _recordPage('#catalog', page, result);
    }
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: result.reachedEnd ? page : page + 1,
      records: result.items.map(_cover).toList(),
    );
  }

  @override
  Future<PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) async {
    if (type == 'author') throw UnsupportedError('此书源暂仅支持书名查找');
    final key = 'search:$keyword';
    if (page == 1) {
      _nextPages.removeWhere((k, _) => k.$1 == key);
      _seenNext.remove(key);
      _queryGenerations[key] = ++_generation;
    }
    final generation = _queryGenerations.putIfAbsent(key, () => ++_generation);
    final next = _nextPages[(key, page)];
    final result =
        hasSearch
            ? await engine.search(keyword, page: page, nextPageUrl: next)
            : await engine.discoverPage(page: page, nextPageUrl: next);
    if (_queryGenerations[key] == generation) _recordPage(key, page, result);
    final query = keyword.trim().toLowerCase();
    final books =
        hasSearch
            ? result.items
            : result.items.where((b) => b.title.toLowerCase().contains(query));
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: result.reachedEnd ? page : page + 1,
      records: books.map(_cover).toList(),
    );
  }

  @override
  Future<SourceBookDetail> detail(String bookId) async {
    final url = ruleBookUrl(bookId, definition.id);
    final book = await engine.detail(url);
    final catalog = await engine.catalog(
      book.catalogUrl.isEmpty ? url : book.catalogUrl,
      detailUrl: url,
    );
    return SourceBookDetail(
      NovelInfo(
        title: book.title,
        author: book.author,
        status: book.status,
        finUpdate: '',
        imgUrl: book.coverUrl,
        introduce: book.description,
        tags: const [],
        heat: '',
        trending: '',
        isAnimated: false,
      ),
      [
        Volume(
          id: '$bookId:catalog',
          title: '目录',
          chapters:
              catalog.chapters
                  .map(
                    (c) => Chapter(
                      aid: bookId,
                      cid: ruleBookId(definition.id, c.url),
                      title: c.title,
                      url: c.url,
                    ),
                  )
                  .toList(),
        ),
      ],
    );
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    final book = ruleBookUrl(bookId, definition.id);
    final chapter = await engine.chapter(
      ruleBookUrl(chapterId, definition.id),
      detailUrl: book,
    );
    return SourceChapter(readerTextFromHtml(chapter.contentHtml));
  }
}

/// Keep paragraph boundaries and illustrations without running remote HTML.
String readerTextFromHtml(String content) {
  final fragment = html.parseFragment(content);
  final buffer = StringBuffer();
  void visit(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is! dom.Element) return;
    if (['script', 'style', 'iframe', 'form'].contains(node.localName)) return;
    if (node.localName == 'img') {
      final src = node.attributes['src'];
      if (src != null && src.isNotEmpty) {
        buffer.write('\n<!--image-->$src<!--image-->\n');
      }
      return;
    }
    if (node.localName == 'br') {
      buffer.write('\n');
      return;
    }
    final block = [
      'p',
      'div',
      'section',
      'article',
      'h1',
      'h2',
      'li',
    ].contains(node.localName);
    if (block) buffer.write('\n');
    for (final child in node.nodes) {
      visit(child);
    }
    if (block) buffer.write('\n');
  }

  for (final node in fragment.nodes) {
    visit(node);
  }
  return buffer
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}
