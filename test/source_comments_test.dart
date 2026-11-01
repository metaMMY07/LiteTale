import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/models/source_comment.dart';
import 'package:wild/services/shelf_api_error.dart';
import 'package:wild/sources/comment_parsers.dart';
import 'package:wild/sources/light_novel_shelf_source.dart';
import 'package:wild/sources/lnovel_source.dart';
import 'package:wild/sources/bili_site_source.dart';
import 'package:wild/sources/rule_book_source.dart';
import 'package:wild/sources/rules/rule_source.dart';
import 'package:wild/sources/sfacg_comments.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/utils/wenku8_read_dom.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsReviews;

Map<String, Object?> shelfPage({int page = 1}) => {
  'Page': page,
  'TotalPages': 2,
  'Users': {
    '5': {'Id': 5, 'UserName': '读者甲'},
    '6': {'Id': 6, 'UserName': '读者乙'},
  },
  'Commentaries': {
    '12': {
      'UserId': 5,
      'Content': 'A < B & C',
      'CreatedAt': '2026-11-01T12:00:00Z',
    },
    '13': {
      'UserId': 6,
      'Content': '回复正文',
      'CreatedAt': '2026-11-01T12:01:00Z',
      'ReplyId': 12,
    },
  },
  'Data': [
    {
      'Id': 12,
      'Reply': [13],
    },
  ],
};

const lnovelMarkup = '''<main><article><h1>书名</h1>
<div class="row"><div class="col"><h2>評論</h2></div></div>
<div class="row g-3 mb-2"><div class="col-auto">头像</div><div class="col">
  <div class="row mb-1 small"><div class="col">读者甲</div><div class="col text-end">2026年11月01日</div></div>
  <div class="bg-body-tertiary"><div class="row g-2"><div class="col-auto">被引用者</div><div class="col"><p>原评论</p></div></div></div>
  <div class="border-bottom"><p>第一段<br>第二段<script>secret()</script></p></div>
</div></div></article></main>''';

String biliMarkup({String id = '42', String body = '测试书评', bool next = true}) =>
    '''
<ol id="list_content" class="book-ol book-ol-comment"><li class="book-li">
 <a class="book-layout" href="/reviewshow_${id}_1.html">
 <div class="book-meta-l"><em>读者乙</em></div><div class="book-meta-r">50/2</div>
 <time>2026-11-01</time><div class="book-comment-p" data-netabare="true">$body</div></a>
</li><li class="book-li"><a href="https://evil.test/reviewshow_8_1.html" class="book-layout"><div class="book-comment-p">不应显示</div></a></li></ol>
${next ? '<div id="pagelink"><a href="/reviews_88_2.html">下一页</a></div>' : ''}''';

Map<String, Object?> sfRow(int id) => {
  'CommentID': id,
  'DisplayName': 'SF读者',
  'Content': '<p>评论 <b>正文</b></p>',
  'Title': '标题',
  'CreateTime': '2026/11/01',
  'ReplyNum': 2,
};

class _SfTransport implements RuleSourceTransport {
  _SfTransport(this.response);
  Object response;
  int status = 200;
  final requests = <Uri>[];
  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    requests.add(uri);
    expect(uri.origin, 'https://book.sfacg.com');
    return RuleSourceHttpResponse(
      statusCode: status,
      headers: const {},
      bytes: Uint8List.fromList(
        utf8.encode(
          response is String ? response as String : jsonEncode(response),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('inert comment text', () {
    test(
      'retains paragraphs and entities without executing or fetching markup',
      () {
        expect(
          commentText(
            '<p>甲 &amp; 乙<br>下一行</p><script>secret</script><iframe>private</iframe><img alt="表情" src="https://evil.test">',
          ),
          '甲 & 乙\n下一行\n表情',
        );
      },
    );
    test('oversize markup and text are explicit errors', () {
      expect(
        () => commentText('a' * (128 * 1024 + 1)),
        throwsA(isA<SourceCommentException>()),
      );
      expect(
        () => commentText('<b>abcdef</b>', maxLength: 2),
        throwsA(isA<SourceCommentException>()),
      );
    });
  });
  group('LightNovelShelf comments', () {
    test(
      'uses the official read method and retains normalized replies',
      () async {
        final source = LightNovelShelfSource(
          invoke: (method, args) async {
            expect(method, 'GetComments');
            expect(args, {'Type': 'Book', 'Id': 77, 'Page': 1});
            return shelfPage();
          },
        );
        final page = await source.comments('lns:77');
        expect(page.hasMore, true);
        expect(page.items.single.content, 'A < B & C');
        expect(page.items.single.replies.single.author, '读者乙');
        expect(page.items.single.replies.single.content, '回复 读者甲：回复正文');
      },
    );
    test(
      'camel-case hub DTOs match the PascalCase dictionary contract',
      () async {
        final source = LightNovelShelfSource(
          invoke:
              (_, __) async => {
                'page': 1,
                'totalPages': 1,
                'users': {
                  '5': {'userName': '甲'},
                },
                'commentaries': {
                  '12': {'userId': 5, 'content': '正文'},
                },
                'data': [
                  {'id': 12, 'reply': []},
                ],
              },
        );
        expect((await source.comments('lns:77')).items.single.content, '正文');
      },
    );
    test('changing the account rejects a pending comment result', () async {
      final response = Completer<Object?>();
      final source = LightNovelShelfSource(invoke: (_, __) => response.future);
      final pending = source.comments('lns:77');
      final check = expectLater(
        pending,
        throwsA(isA<SourceCommentException>()),
      );
      source.clearSessionCache();
      response.complete(shelfPage());
      await check;
    });
    test(
      'auth and network failures are never successful empty pages',
      () async {
        for (final error in [
          const ShelfSignInRequired(),
          const ShelfApiException('502'),
        ]) {
          final source = LightNovelShelfSource(
            invoke: (_, __) => Future.error(error),
          );
          await expectLater(source.comments('lns:77'), throwsA(same(error)));
        }
      },
    );
    test('missing bodies and mismatched pages are rejected', () {
      expect(
        () => shelfComments({'Page': 1, 'Data': []}, 1),
        throwsA(isA<SourceCommentException>()),
      );
      expect(
        () => shelfComments(shelfPage(page: 2), 1),
        throwsA(isA<SourceCommentException>()),
      );
    });
  });
  group('LNovel embedded comments', () {
    test('book comments and quotes preserve order and paragraphs', () async {
      final source = LNovelSource(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://lnovel.tw/books-3638');
          return http.Response(
            lnovelMarkup,
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );
      final page = await source.comments('lnv:3638');
      expect(page.hasMore, false);
      expect(page.items, hasLength(1));
      expect(page.items.single.content, '第一段\n第二段');
      expect(page.items.single.replies.single.content, '原评论');
      expect(page.items.single.replies.single.title, '引用');
    });
    test('an intact empty comments area is valid, changed markup is not', () {
      expect(
        lnovelComments(
          html.parse('<main><article><h2>評論</h2></article></main>'),
        ).items,
        isEmpty,
      );
      expect(
        () => lnovelComments(html.parse('<main>bad response</main>')),
        throwsA(isA<SourceCommentException>()),
      );
    });
    test('does not invent a second page on the site', () async {
      final source = LNovelSource(
        client: MockClient((_) async => throw StateError('must not request')),
      );
      await expectLater(
        source.comments('lnv:3638', page: 2),
        throwsA(isA<SourceCommentException>()),
      );
    });
  });
  group('Bili public reviews', () {
    test(
      'uses the real paginated mobile URL, not detail/chapter requests',
      () async {
        final source = BiliSiteSource(
          searcher: (_, __) async => throw StateError('unused'),
          chapterLoader: (_, __) async => throw StateError('unused'),
          documentLoader: (uri) async {
            expect('$uri', 'https://www.bilinovel.net/reviews_88_1.html');
            return biliMarkup(body: '长评...');
          },
        );
        final page = await source.comments('bili:88');
        expect(page.items, hasLength(1));
        final item = page.items.single;
        expect(item.author, '读者乙');
        expect(item.spoiler, true);
        expect(item.preview, true);
        expect(item.replyCount, 2);
        expect(page.notice, contains('登录'));
        expect(page.hasMore, true);
      },
    );
    test('empty lists differ from a challenge or unknown page', () {
      expect(
        biliComments(
          html.parse('<ol id="list_content" class="book-ol-comment"></ol>'),
          '88',
          1,
        ).items,
        isEmpty,
      );
      expect(
        () => biliComments(html.parse('<h1>Blocked</h1>'), '88', 1),
        throwsA(isA<SourceCommentException>()),
      );
    });
    test('next page must belong to the same book, no duplicated root IDs', () {
      final markup = biliMarkup().replaceAll(
        '/reviews_88_2.html',
        '/reviews_99_2.html',
      );
      final doc = html.parse(markup);
      doc
          .querySelector('#list_content')!
          .append(doc.querySelector('li')!.clone(true));
      final page = biliComments(doc, '88', 1);
      expect(page.items, hasLength(1));
      expect(page.hasMore, false);
    });
    test('disabled pagination in HTML comments is not an active next page', () {
      final doc = html.parse(
        '${biliMarkup(next: false)}<!-- <a href="/reviews_88_2.html">2</a> -->',
      );
      expect(biliComments(doc, '88', 1).hasMore, false);
    });
  });
  group('SF comments and long reviews', () {
    test('public API sends zero-based index and long-review kind', () async {
      final transport = _SfTransport({
        'status': 200,
        'Cmts': [sfRow(12)],
      });
      final page = await SfacgComments(
        transport,
      ).load('775264', page: 2, feed: CommentFeed.reviews);
      expect(transport.requests.single.queryParameters, {
        'op': 'getcmtlist',
        'nid': '775264',
        'ctype': 'long',
        'len': '32768',
        'so': 'addtime',
        'pi': '1',
        'ps': '20',
      });
      expect(page.items.single.content, '评论 正文');
      expect(page.items.single.canOpenThread, true);
    });
    test('replies load on demand and preserve ascending order', () async {
      final transport = _SfTransport({
        'status': 200,
        'Replys': [sfRow(21), sfRow(22)],
      });
      final page = await SfacgComments(
        transport,
      ).load('775264', threadId: '12');
      expect(transport.requests.single.queryParameters, {
        'op': 'getCmtReply',
        'cid': '12',
        'order': 'asc',
        'pi': '0',
        'ps': '20',
      });
      expect(page.items.map((e) => e.id), ['21', '22']);
      expect(page.items.first.canOpenThread, false);
    });
    test(
      'maintenance is a visible notice, not a reader or empty-state claim',
      () {
        final page = sfComments({
          'status': 200,
          'Cmts': [
            {...sfRow(0), 'Content': '评论系统维护中,请耐心等待哦'},
          ],
        }, 1);
        expect(page.items, isEmpty);
        expect(page.notice, contains('维护'));
        expect(page.hasMore, false);
      },
    );
    test('malformed/API/HTTP failures stay failures', () async {
      final transport = _SfTransport('<html>challenge</html>');
      await expectLater(
        SfacgComments(transport).load('775264'),
        throwsA(isA<SourceCommentException>()),
      );
      transport.response = {'status': 501, 'msg': 'bad'};
      await expectLater(
        SfacgComments(transport).load('775264'),
        throwsA(isA<SourceCommentException>()),
      );
      transport.status = 429;
      await expectLater(
        SfacgComments(transport).load('775264'),
        throwsA(isA<SourceCommentException>()),
      );
    });
    test('only the bundled SF origin/ID gets the SF adapter', () async {
      final definitions =
          jsonDecode(
                await File('assets/book_sources/bundled.json').readAsString(),
              )
              as List;
      final definition = RuleSourceDefinition.fromJson(
        Map<String, dynamic>.from(definitions.single),
      );
      final transport = _SfTransport({
        'status': 200,
        'Cmts': [sfRow(12)],
      });
      final source = RuleBookSource(
        definition,
        engine: RuleSourceEngine(definition, transport: transport),
      );
      expect(source.supportsComments, true);
      expect(source.commentFeeds, [CommentFeed.comments, CommentFeed.reviews]);
      final book = ruleBookId(
        'sfacg_public',
        'https://book.sfacg.com/Novel/775264/',
      );
      expect((await source.comments(book)).items.single.id, '12');
      final foreign = ruleBookId(
        'sfacg_public',
        'https://evil.test/Novel/775264/',
      );
      await expectLater(
        source.comments(foreign),
        throwsA(isA<SourceCommentException>()),
      );
    });
  });
  group('Wenku8 browser comments', () {
    const url =
        'https://www.wenku8.net/modules/article/reviews.php?aid=101&page=1&charset=gbk';
    Map<String, Object> payload({String pageUrl = url}) => {
      'url': pageUrl,
      'kind': 'reviews',
      'aid': '101',
      'challenge': false,
      'data': {
        'currentPage': 1,
        'maxPage': 2,
        'records': [
          {
            'rid': '42',
            'content': '评论标题',
            'replyCount': 2,
            'uid': '1',
            'uname': '甲',
            'time': '2026-11-01',
          },
        ],
      },
    };
    test(
      'compact same-origin payload preserves the existing FRB review model',
      () {
        final value =
            parseWenku8ReadWebViewResult(
                  payload(),
                  apiHost: 'https://www.wenku8.net',
                  loadedUrl: url,
                  kind: 'reviews',
                  aid: '101',
                )
                as PageStatsReviews;
        expect(value.records.single.rid, '42');
        expect(value.records.single.replyCount, 2);
        expect(value.maxPage, 2);
      },
    );
    test(
      'mismatched book, page, origin and duplicate parameters are rejected',
      () {
        for (final invalid in [
          url.replaceFirst('aid=101', 'aid=102'),
          url.replaceFirst('wenku8.net', 'evil.test'),
          '$url&aid=101',
          url.replaceFirst('page=1', 'page=2'),
        ]) {
          expect(
            () => parseWenku8ReadWebViewResult(
              payload(pageUrl: invalid),
              apiHost: 'https://www.wenku8.net',
              loadedUrl: invalid,
              kind: 'reviews',
              aid: '101',
            ),
            throwsFormatException,
          );
        }
      },
    );
  });
  test('six built-in source capabilities do not invent Huanmeng comments', () {
    expect(api.sourceSupportsComments('101'), true);
    expect(api.sourceSupportsComments('lns:77'), true);
    expect(api.sourceSupportsComments('lnv:3638'), true);
    expect(api.sourceSupportsComments('bili:88'), true);
    expect(api.sourceSupportsComments('hm:8676'), false);
    expect(api.sourceSupportsComments('epub:${'a' * 64}'), false);
  });
}
