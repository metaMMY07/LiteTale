import 'dart:convert';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'book_source.dart';

/// Native adapter for the public catalogue referenced by legado-source.
/// No downloaded JavaScript or account cookies are executed/shared.
class LNovelSource implements BookSource {
  LNovelSource({http.Client? client}) : _client = client;
  final http.Client? _client;
  static final base = Uri.parse('https://lnovel.tw/');
  static const headers = {
    'User-Agent': 'Mozilla/5.0',
    'Referer': 'https://lnovel.tw/',
  };
  @override
  SourceId get id => SourceId.lnovel;

  Future<Document> _get(Uri uri) async {
    final response = await (_client?.get(uri, headers: headers) ??
            http.get(uri, headers: headers))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw StateError('轻小说百科暂时无法访问（${response.statusCode}），请稍后重试');
    }
    final doc = html.parse(utf8.decode(response.bodyBytes));
    if (doc.querySelector('main') == null) {
      throw const FormatException('轻小说百科页面格式已变化');
    }
    return doc;
  }

  static String _number(String id) {
    final match = RegExp(r'^lnv:(\d+)$').firstMatch(id);
    if (match == null) throw const FormatException('无效的轻小说百科编号');
    return match.group(1)!;
  }

  static String _url(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final uri = base.resolve(raw);
    return ['https', 'http'].contains(uri.scheme) ? '$uri' : '';
  }

  Future<PageStatsNovelCover> list({
    int page = 1,
    int? category,
    bool popular = false,
    String? keyword,
  }) async {
    final uri = base
        .resolve('books')
        .replace(
          queryParameters: {
            'page': '$page',
            if (category != null) 'q[genres_id_eq]': '$category',
            if (popular) 'q[sorts]': 'readings_count desc',
            if (keyword != null) 'q[name_cont]': keyword,
          },
        );
    final doc = await _get(uri);
    final books = <NovelCover>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('main a[href]')) {
      final match = RegExp(r'^/books-(\d+)$').firstMatch(a.attributes['href']!);
      if (match == null ||
          a.querySelector('img') == null ||
          !seen.add(match.group(1)!)) {
        continue;
      }
      books.add(
        NovelCover(
          aid: 'lnv:${match.group(1)}',
          title: a.text.trim(),
          img: _url(a.querySelector('img')?.attributes['src']),
          detailUrl: _url(a.attributes['href']),
        ),
      );
    }
    if (books.isEmpty &&
        doc.querySelector('input[name="q[name_cont]"]') == null) {
      throw const FormatException('轻小说百科列表格式已变化');
    }
    final hasNext =
        doc.querySelector('a[rel="next"], link[rel="next"]') != null;
    return PageStatsNovelCover(
      currentPage: page,
      maxPage: hasNext ? page + 1 : page,
      records: books,
    );
  }

  Future<List<Map>> categories() async {
    final doc = await _get(base.resolve('books'));
    final result = <int, String>{};
    for (final a in doc.querySelectorAll('aside a[href]')) {
      final value = int.tryParse(
        base
                .resolve(a.attributes['href']!)
                .queryParameters['q[genres_id_eq]'] ??
            '',
      );
      if (value != null) result[value] = a.text.trim();
    }
    return result.entries.map((e) => {'Id': e.key, 'Name': e.value}).toList();
  }

  @override
  Future<List<HomeBlock>> discover() async => [
    HomeBlock(title: '最近更新', list: (await list()).records.take(12).toList()),
  ];
  @override
  Future<PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) async {
    if (type == 'author') throw UnsupportedError('轻小说百科暂仅支持书名查找');
    // The site's name_cont currently ignores the keyword. Search one catalogue
    // page at a time, explicitly labelled in the UI, instead of false matches.
    final result = await list(page: page);
    final query = keyword.trim().toLowerCase();
    return PageStatsNovelCover(
      currentPage: result.currentPage,
      maxPage: result.maxPage,
      records:
          result.records
              .where((b) => b.title.toLowerCase().contains(query))
              .toList(),
    );
  }

  @override
  Future<SourceBookDetail> detail(String bookId) async {
    final doc = await _get(base.resolve('books-${_number(bookId)}'));
    final article = doc.querySelector('main article');
    final title = article?.querySelector('h1')?.text.trim() ?? '';
    if (title.isEmpty) throw const FormatException('轻小说百科书籍信息缺失');
    final data = <String, String>{};
    for (final dl in article!.querySelectorAll('dl')) {
      data[dl.querySelector('dt')?.text.trim() ?? ''] =
          dl.querySelector('dd')?.text.trim() ?? '';
    }
    final volumes = <Volume>[];
    for (final item in article.querySelectorAll('.accordion-item')) {
      final chapters = <Chapter>[];
      final seen = <String>{};
      for (final a in item.querySelectorAll('.list-group a[href]')) {
        final m = RegExp(
          r'^/chapters-(\d+)$',
        ).firstMatch(a.attributes['href']!);
        if (m == null || !seen.add(m.group(1)!)) continue;
        chapters.add(
          Chapter(
            aid: bookId,
            cid: 'lnv:${m.group(1)}',
            title: a.text.trim(),
            url: _url(a.attributes['href']),
          ),
        );
      }
      if (chapters.isNotEmpty) {
        volumes.add(
          Volume(
            id: '$bookId:${volumes.length}',
            title: item.querySelector('h3')?.text.trim() ?? '正文',
            chapters: chapters,
          ),
        );
      }
    }
    return SourceBookDetail(
      NovelInfo(
        title: title,
        author: data['作者'] ?? '',
        status: data['狀態'] ?? '',
        finUpdate: data['更新'] ?? '',
        imgUrl: _url(article.querySelector('img')?.attributes['src']),
        introduce: article
            .querySelectorAll('p.my-2')
            .map((p) => p.text.trim())
            .join('\n'),
        tags: [if (data['類別'] != null) data['類別']!],
        heat: '',
        trending: '',
        isAnimated: false,
      ),
      volumes,
    );
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    _number(bookId);
    final doc = await _get(base.resolve('chapters-${_number(chapterId)}'));
    final content = doc.querySelector('main .card-body');
    if (content == null) throw const FormatException('轻小说百科正文缺失');
    final out = StringBuffer();
    void walk(Node node) {
      if (node is Text) {
        out.write(node.text);
        return;
      }
      if (node is Element) {
        if ([
          'script',
          'style',
          'iframe',
          'h1',
          'nav',
          'button',
          'svg',
        ].contains(node.localName)) {
          return;
        }
        if (node.localName == 'img') {
          final url = _url(
            node.attributes['src'] ?? node.attributes['data-src'],
          );
          if (url.isNotEmpty) out.write('<!--image-->$url<!--image-->');
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
      if (node is Element && ['p', 'div', 'section'].contains(node.localName)) {
        out.writeln();
      }
    }

    walk(content);
    final text = out.toString().trim();
    if (text.isEmpty) throw const FormatException('该章节暂无可读取的公开正文');
    return SourceChapter(text);
  }
}
