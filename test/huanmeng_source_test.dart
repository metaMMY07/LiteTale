import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/huanmeng_source.dart';

// All envelopes below are short, artificial JSON fixtures built from the
// author's public field declarations. They are not captured API successes.
Map<String, dynamic> _book([int id = 794]) => {
  'id': id,
  'name': 'SeaBed $id',
  'author': '作者甲',
  'pic': '/covers/$id.jpg',
  'intro': '简介',
  'kind': '奇幻',
};

Map<String, dynamic> _data(Map<String, dynamic> value, {dynamic code = 1}) => {
  'code': code,
  'data': value,
};

Map<String, dynamic> _detail() => _data({
  ..._book(),
  'id': '794',
  'intro': '<p>第一段简介</p><p>第二段简介</p><script>不应显示</script>',
  'kind': ['奇幻', '校园'],
  'text_num': 123456,
});

Map<String, dynamic> _chapters({int bid = 794, int cid = 763}) => _data({
  'list': [
    {'bid': bid, 'id': cid, 'name': '第一章'},
  ],
});

Uri _target(String operation, [Map<String, String> query = const {}]) =>
    HuanmengSource.origin
        .resolve('/index.php/bookapi/$operation')
        .replace(queryParameters: {'password': 'chiyu666', ...query});

void main() {
  test(
    'password-change announcement is rejected as content and as verification',
    () async {
      final envelope = _data({
        'content':
            '<p>由于有人恶意倒卖此书源，目前已修改端口密码</p><p>接口密码错误，无法获取数据，请联系开发者获取新的接口密码</p>',
      });
      final source = HuanmengSource(
        transport: _Transport((_) async => envelope),
      );
      await expectLater(
        source.chapter('hm:794', 'hm:794:763'),
        throwsA(isA<HuanmengSourceException>()),
      );
      expect(
        HuanmengSource.canVerifyResponse(
          _target('content', {'bid': '794', 'cid': '763'}),
          envelope,
        ),
        isFalse,
      );
    },
  );
  group('Huanmeng public API declarations with artificial fixtures', () {
    test(
      '9.0 page-local counters do not truncate the library after page one',
      () async {
        final source = HuanmengSource(
          transport: _Transport((uri) async {
            final page = int.parse(uri.queryParameters['page']!);
            return _data({
              'list': List.generate(20, (i) => _book(page * 100 + i)),
              'total': 20,
              'page': page,
              'size': 20,
              'pages': 1,
            });
          }),
        );
        expect((await source.list()).maxPage, 2);
        expect((await source.list(page: 2)).maxPage, 3);
      },
    );

    test(
      'an ignored requested page is rejected before appending records',
      () async {
        final source = HuanmengSource(
          transport: _Transport(
            (_) async => _data({
              'list': [_book()],
              'total': 1,
              'page': 1,
              'size': 20,
              'pages': 1,
            }),
          ),
        );
        await expectLater(source.list(page: 2), throwsFormatException);
      },
    );
    test(
      'discovery uses the unfiltered latest search and keeps a local stable id',
      () async {
        final transport = _Transport((uri) async {
          expect(uri.origin, HuanmengSource.origin.origin);
          expect(uri.path, '/index.php/bookapi/search');
          expect(uri.queryParameters, {
            'password': 'chiyu666',
            'page': '1',
            'size': '20',
          });
          return _data({
            'list': [_book()],
          });
        });
        final source = HuanmengSource(transport: transport);
        expect(source.id, SourceId.huanmeng);
        final block = (await source.discover()).single;
        expect(block.title, contains('最新更新'));
        expect(block.list.single.aid, 'hm:794');
        expect(block.list.single.detailUrl, 'hm:794');
        expect(
          block.list.single.img,
          '${HuanmengSource.origin.origin}/covers/794.jpg',
        );
        expect(transport.visited, hasLength(1));
      },
    );

    test('list only uses the declared tags and state parameters', () async {
      final transport = _Transport((uri) async {
        expect(uri.queryParameters, {
          'password': 'chiyu666',
          'page': '2',
          'size': '20',
          'tags': '17',
          'state': '2',
        });
        return _data({
          'list': [_book()],
        });
      });
      final source = HuanmengSource(transport: transport);
      final result = await source.list(page: 2, tag: 17, state: 2);
      expect(result.currentPage, 2);
      expect(result.maxPage, 2);
      expect(() => source.list(page: 0), throwsFormatException);
      expect(() => source.list(tag: 51), throwsFormatException);
      expect(() => source.list(state: 3), throwsFormatException);
      expect(transport.visited, hasLength(1));
    });

    test(
      'title search encodes the keyword once and rejects other search types',
      () async {
        const key = 'SeaBed 中文 & ?x=/+%#';
        final transport = _Transport((uri) async {
          expect(uri.path, '/index.php/bookapi/search');
          expect(uri.queryParameters['key'], key);
          expect(uri.queryParameters['page'], '3');
          return _data({
            'list': [_book()],
          });
        });
        final source = HuanmengSource(transport: transport);
        expect(
          (await source.search(key, 'title', 3)).records.single.aid,
          'hm:794',
        );
        for (final type in ['author', 'articlename', '', 'unknown']) {
          expect(() => source.search(key, type, 1), throwsUnsupportedError);
        }
        expect(() => source.search('', 'title', 1), throwsFormatException);
        expect(transport.visited, hasLength(1));
      },
    );

    test(
      'pagination uses total records when present and a full page otherwise',
      () async {
        final twenty = List.generate(20, (index) => _book(index + 1));
        var envelope = _data({'list': twenty, 'maxPage': 9999});
        final transport = _Transport((_) async => envelope);
        final source = HuanmengSource(transport: transport);
        expect((await source.list()).maxPage, 2);
        envelope = _data({'list': twenty, 'total': '45'});
        expect((await source.list()).maxPage, 3);
        envelope = _data({
          'list': [_book()],
          'maxPage': 9999,
        });
        expect((await source.list()).maxPage, 1);
        envelope = _data({'list': <dynamic>[], 'total': 0});
        final empty = await source.list();
        expect(empty.records, isEmpty);
        expect(empty.maxPage, 1);
        envelope = _data({
          'list': [_book()],
          'total': 0,
        });
        await expectLater(source.list(), throwsFormatException);
      },
    );

    test(
      'unknown success conventions rely on required data while explicit failures cannot look empty',
      () async {
        var envelope = _data({'list': <dynamic>[]}, code: 0);
        final transport = _Transport((_) async => envelope);
        final source = HuanmengSource(transport: transport);
        for (final code in [0, 1, 200, 'OK']) {
          envelope = _data({'list': <dynamic>[]}, code: code);
          expect((await source.list()).records, isEmpty);
        }
        for (final failure in [
          {
            'code': -1,
            'data': {'list': []},
          },
          {
            'code': 403,
            'data': {'list': []},
          },
          {
            'code': 'FAIL',
            'data': {'list': []},
          },
          {
            'message': '接口密匙核对错误',
            'data': {'list': []},
          },
          {
            'error': 'denied',
            'data': {'list': []},
          },
          {
            'success': false,
            'data': {'list': []},
          },
        ]) {
          envelope = failure;
          await expectLater(
            source.list(),
            throwsA(isA<HuanmengSourceException>()),
          );
        }
        for (final malformed in <Map<String, dynamic>>[
          {},
          {'data': []},
          {'data': {}},
          {
            'data': {'list': null},
          },
        ]) {
          envelope = malformed;
          await expectLater(source.list(), throwsFormatException);
        }
      },
    );

    test(
      'detail reads metadata and catalog from exactly the documented endpoints',
      () async {
        final transport = _Transport(
          (uri) async => uri.path.endsWith('/detail') ? _detail() : _chapters(),
        );
        final result = await HuanmengSource(
          transport: transport,
        ).detail('hm:794');
        expect(result.info.title, 'SeaBed 794');
        expect(result.info.author, '作者甲');
        expect(result.info.introduce, '第一段简介\n第二段简介');
        expect(result.info.tags, ['奇幻', '校园']);
        expect(result.info.status, isEmpty);
        expect(result.info.heat, isEmpty);
        final chapter = result.volumes.single.chapters.single;
        expect(chapter.aid, 'hm:794');
        expect(chapter.cid, 'hm:794:763');
        expect(chapter.url, 'hm:794:763');
        expect(transport.visited.map((uri) => uri.path), [
          '/index.php/bookapi/detail',
          '/index.php/bookapi/chapters',
        ]);
        expect(transport.visited.first.queryParameters, {
          'password': 'chiyu666',
          'id': '794',
        });
        expect(transport.visited.last.queryParameters, {
          'password': 'chiyu666',
          'id': '794',
          'size': '5000',
        });
      },
    );

    test(
      'book and chapter IDs cannot select another source or another book',
      () async {
        final transport = _Transport((_) async => _detail());
        final source = HuanmengSource(transport: transport);
        for (final id in [
          '794',
          'src:old:YWJj',
          'hm:0',
          'hm:0794',
          'hm:794:763',
          'hm:9007199254740992',
        ]) {
          expect(() => source.detail(id), throwsFormatException);
        }
        for (final cid in [
          'hm:795:763',
          'hm:794',
          'hm:794:0',
          'hm:794:0763',
          'src:old:YWJj',
          'hm:794:763:extra',
        ]) {
          expect(() => source.chapter('hm:794', cid), throwsFormatException);
        }
        expect(transport.visited, isEmpty);
      },
    );

    test(
      'response identities and mandatory fields are checked before accepting a detail',
      () async {
        var detail = _detail();
        var catalog = _chapters();
        final transport = _Transport(
          (uri) async => uri.path.endsWith('/detail') ? detail : catalog,
        );
        final source = HuanmengSource(transport: transport);
        detail = _data({..._book(795)});
        await expectLater(source.detail('hm:794'), throwsFormatException);
        expect(transport.visited, hasLength(1));
        detail = _detail();
        catalog = _chapters(bid: 795);
        await expectLater(source.detail('hm:794'), throwsFormatException);
        catalog = _data({
          'list': [
            {'bid': 794, 'id': 763},
          ],
        });
        await expectLater(source.detail('hm:794'), throwsFormatException);
        catalog = _data({'list': []});
        await expectLater(
          source.detail('hm:794'),
          throwsA(isA<HuanmengSourceException>()),
        );
      },
    );

    test(
      'explicit catalog totals request following pages and preserve chapter order',
      () async {
        final transport = _Transport((uri) async {
          if (uri.path.endsWith('/detail')) return _detail();
          final page = uri.queryParameters['page'];
          expect(uri.queryParameters['size'], '5000');
          if (page == null) {
            return _data({
              'list': [
                {'bid': 794, 'id': 763, 'name': '第一章'},
              ],
              'total': 2,
            });
          }
          expect(page, '2');
          return _data({
            'list': [
              {'bid': '794', 'id': '764', 'name': '第二章'},
            ],
            'total': 2,
          });
        });
        final result = await HuanmengSource(
          transport: transport,
        ).detail('hm:794');
        expect(result.volumes.single.chapters.map((chapter) => chapter.cid), [
          'hm:794:763',
          'hm:794:764',
        ]);
        expect(transport.visited, hasLength(3));
      },
    );

    test(
      'a full catalog page without total checks the next page instead of truncating',
      () async {
        final rows = List.generate(
          5000,
          (index) => {'bid': 794, 'id': index + 1, 'name': '章节${index + 1}'},
        );
        final transport = _Transport((uri) async {
          if (uri.path.endsWith('/detail')) return _detail();
          return _data({
            'list': uri.queryParameters['page'] == null ? rows : <dynamic>[],
          });
        });
        final result = await HuanmengSource(
          transport: transport,
        ).detail('hm:794');
        expect(result.volumes.single.chapters, hasLength(5000));
        expect(transport.visited.last.queryParameters['page'], '2');
      },
    );

    test(
      'ignored catalog pagination, changing totals and chapter limits fail explicitly',
      () async {
        var catalogReads = 0;
        var changeTotal = false;
        var catalog = _data({
          'list': [
            {'bid': 794, 'id': 763, 'name': '第一章'},
          ],
          'total': 2,
        });
        final transport = _Transport((uri) async {
          if (uri.path.endsWith('/detail')) return _detail();
          catalogReads++;
          if (changeTotal && catalogReads > 1) {
            return _data({
              'list': [
                {'bid': 794, 'id': 764, 'name': '第二章'},
              ],
              'total': 3,
            });
          }
          return catalog;
        });
        await expectLater(
          HuanmengSource(transport: transport).detail('hm:794'),
          throwsFormatException,
        );
        expect(catalogReads, 2);
        await expectLater(
          HuanmengSource(
            transport: transport,
            budget: const HuanmengBudget(maxChapters: 1),
          ).detail('hm:794'),
          throwsA(isA<HuanmengSourceException>()),
        );
        catalog = _data({
          'list': [
            {'bid': 794, 'id': 763, 'name': '第一章'},
          ],
          'total': 2,
        });
        await expectLater(
          HuanmengSource(
            transport: transport,
            budget: const HuanmengBudget(maxCatalogPages: 1),
          ).detail('hm:794'),
          throwsA(isA<HuanmengSourceException>()),
        );
        catalogReads = 0;
        changeTotal = true;
        await expectLater(
          HuanmengSource(transport: transport).detail('hm:794'),
          throwsFormatException,
        );
        expect(catalogReads, 2);
      },
    );

    test(
      'chapter paragraphs and repeated text survive while only safe illustrations become markers',
      () async {
        final transport = _Transport((uri) async {
          expect(uri.path, '/index.php/bookapi/content');
          expect(uri.queryParameters, {
            'password': 'chiyu666',
            'bid': '794',
            'cid': '763',
          });
          return _data({
            'bid': 794,
            'cid': 763,
            'content': '''
          <p>第一段&lt;保留尖括号&gt;</p><p>重复段</p><p>重复段</p>
          <img src="/images/one.webp" onerror="alert(1)">
          <p>插图之后<br>换行</p><img src="https://cdn.example/two.jpg">
          <script>danger()</script><iframe src="https://bad.example">恶意嵌入</iframe>
          <style>secret</style><object>恶意对象</object>
          <img src="javascript:alert(1)"><img src="http://127.0.0.1/private">
          <p>&lt;!--image--&gt;http://10.0.0.1/injected&lt;!--image--&gt;</p>
        ''',
          });
        });
        final chapter = await HuanmengSource(
          transport: transport,
        ).chapter('hm:794', 'hm:794:763');
        expect(chapter.content, startsWith('第一段<保留尖括号>\n重复段\n重复段\n'));
        expect(
          chapter.content,
          contains(
            '<!--image-->${HuanmengSource.origin.origin}/images/one.webp<!--image-->',
          ),
        );
        expect(
          chapter.content,
          contains('<!--image-->https://cdn.example/two.jpg<!--image-->'),
        );
        expect(chapter.content, contains('插图之后\n换行'));
        expect(chapter.content, isNot(contains('danger()')));
        expect(chapter.content, isNot(contains('恶意嵌入')));
        expect(chapter.content, isNot(contains('恶意对象')));
        expect(chapter.content, isNot(contains('<!--image-->http://10.0.0.1')));
        expect(
          RegExp('<!--image-->').allMatches(chapter.content),
          hasLength(4),
        );
        expect(transport.visited, hasLength(1));
      },
    );

    test(
      'private, credential, executable and fragment image URLs never enter covers or chapters',
      () async {
        const unsafe = [
          'javascript:alert(1)',
          'data:image/png;base64,AAAA',
          'http://localhost/a',
          'http://device.local/a',
          'http://10.0.0.1/a',
          'http://127.0.0.1/a',
          'http://192.168.1.2/a',
          'http://172.16.0.1/a',
          'http://169.254.1.2/a',
          'http://100.64.1.2/a',
          'http://[::1]/a',
          'http://[::ffff:127.0.0.1]/a',
          'http://[fc00::1]/a',
          'http://2130706433/a',
          'http://0x7f000001/a',
          'https://user:pass@cdn.example/a',
          'https://cdn.example/a#fragment',
        ];
        final transport = _Transport((uri) async {
          if (uri.path.endsWith('/search')) {
            return _data({
              'list': [
                for (var i = 0; i < unsafe.length; i++)
                  {..._book(i + 1), 'pic': unsafe[i]},
              ],
            });
          }
          return _data({
            'content':
                '<p>安全正文</p>${unsafe.map((url) => '<img src="$url">').join()}',
          });
        });
        final source = HuanmengSource(transport: transport);
        expect(
          (await source.list()).records.every((book) => book.img.isEmpty),
          true,
        );
        expect((await source.chapter('hm:794', 'hm:794:763')).content, '安全正文');
      },
    );

    test(
      'empty or mismatched content cannot be accepted as a chapter',
      () async {
        var data = _data({'content': '<script>only script</script>'});
        final transport = _Transport((_) async => data);
        final source = HuanmengSource(transport: transport);
        await expectLater(
          source.chapter('hm:794', 'hm:794:763'),
          throwsA(isA<HuanmengSourceException>()),
        );
        data = _data({'content': '正文', 'bid': 795});
        await expectLater(
          source.chapter('hm:794', 'hm:794:763'),
          throwsFormatException,
        );
        data = _data({'content': '正文', 'cid': 764});
        await expectLater(
          source.chapter('hm:794', 'hm:794:763'),
          throwsFormatException,
        );
        data = _data({});
        await expectLater(
          source.chapter('hm:794', 'hm:794:763'),
          throwsFormatException,
        );
      },
    );

    test(
      'timeouts discard late detail results before a catalog request can start',
      () async {
        final pending = Completer<Map<String, dynamic>>();
        final transport = _Transport((_) => pending.future);
        final source = HuanmengSource(
          transport: transport,
          budget: const HuanmengBudget(
            requestTimeout: Duration(milliseconds: 15),
            operationTimeout: Duration(milliseconds: 40),
          ),
        );
        await expectLater(
          source.detail('hm:794'),
          throwsA(isA<HuanmengSourceException>()),
        );
        pending.complete(_detail());
        await Future<void>.delayed(Duration.zero);
        expect(transport.visited, hasLength(1));
      },
    );

    test(
      'content and DOM bounds fail without silently returning partial text',
      () async {
        var body = '字' * 101;
        final transport = _Transport((_) async => _data({'content': body}));
        final source = HuanmengSource(
          transport: transport,
          budget: const HuanmengBudget(maxContentCharacters: 100),
        );
        await expectLater(
          source.chapter('hm:794', 'hm:794:763'),
          throwsA(isA<HuanmengSourceException>()),
        );
        body = '${'<div>' * 135}正文${'</div>' * 135}';
        await expectLater(
          HuanmengSource(transport: transport).chapter('hm:794', 'hm:794:763'),
          throwsA(isA<HuanmengSourceException>()),
        );
      },
    );
  });

  group('shared current-response verification validator', () {
    test(
      'accepts valid endpoint data and an empty search without guessing a success code',
      () {
        for (final code in [0, 1, 200, 'OK']) {
          expect(
            HuanmengSource.canVerifyResponse(
              _target('search'),
              _data({'list': []}, code: code),
            ),
            true,
          );
        }
        expect(
          HuanmengSource.canVerifyResponse(
            _target('search'),
            _data({
              'list': [_book()],
            }),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            _target('detail', {'id': '794'}),
            _detail(),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            _target('chapters', {'id': '794'}),
            _chapters(),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            _target('content', {'bid': '794', 'cid': '763'}),
            _data({'content': '<p>正文</p>'}),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            _target('chapters', {'id': '794'}),
            _data({'list': []}),
          ),
          false,
        );
      },
    );

    test(
      'explicit errors and malformed envelopes return false instead of throwing or confirming',
      () {
        for (final envelope in <Map<String, dynamic>>[
          {
            'code': 1,
            'message': '接口密匙核对错误',
            'data': {'list': []},
          },
          {
            'error': 'denied',
            'data': {'list': []},
          },
          {
            'code': 'FAIL',
            'data': {'list': []},
          },
          {
            'code': false,
            'data': {'list': []},
          },
          {
            'code': -1,
            'data': {'list': []},
          },
          {
            'code': 429,
            'data': {'list': []},
          },
          {
            'success': false,
            'data': {'list': []},
          },
          {
            'msg': 'service unavailable',
            'data': {'list': []},
          },
          {},
          {'data': null},
          {'data': []},
          {'data': {}},
        ]) {
          expect(
            HuanmengSource.canVerifyResponse(_target('search'), envelope),
            false,
            reason: envelope.toString(),
          );
        }
      },
    );

    test(
      'only the fixed HTTPS origin and exact four paths can be verified',
      () {
        final detailTarget = _target('detail', {'id': '794'});
        for (final target in [
          detailTarget.replace(scheme: 'http'),
          detailTarget.replace(host: 'foreign.example'),
          detailTarget.replace(port: 444),
          detailTarget.replace(userInfo: 'user:pass'),
          detailTarget.replace(fragment: 'book'),
          detailTarget.replace(path: '/index.php/bookapi/unknown'),
          detailTarget.replace(path: '/index.php/bookapi/detail/extra'),
          Uri.parse('javascript:alert(1)'),
          Uri.parse('data:text/plain,not-api'),
          _target('detail'),
          detailTarget.replace(query: 'id=794&id=795'),
        ]) {
          expect(
            HuanmengSource.canVerifyResponse(target, _detail()),
            false,
            reason: target.toString(),
          );
        }
      },
    );

    test(
      'detail identity and all fields consumed by the adapter must be valid',
      () {
        final target = _target('detail', {'id': '794'});
        for (final fields in <Map<String, dynamic>>[
          {..._book(), 'id': 795},
          {..._book(), 'name': ' \n '},
          {..._book(), 'name': 123},
          {..._book(), 'author': []},
          {..._book(), 'intro': {}},
          {..._book(), 'kind': {}},
          {..._book(), 'pic': true},
        ]) {
          expect(
            HuanmengSource.canVerifyResponse(target, _data(fields)),
            false,
            reason: fields.toString(),
          );
        }
      },
    );

    test(
      'content checks optional response identities and requires readable text or a safe image',
      () {
        final target = _target('content', {'bid': '794', 'cid': '763'});
        expect(
          HuanmengSource.canVerifyResponse(
            target,
            _data({'bid': '794', 'cid': '763', 'content': '<p>正文</p>'}),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            target,
            _data({'content': '<img src="https://cdn.example/image.webp">'}),
          ),
          true,
        );
        for (final fields in <Map<String, dynamic>>[
          {'content': ''},
          {'content': '  \n '},
          {'content': null},
          {'content': '<script>not content</script>'},
          {'content': '<img src="http://127.0.0.1/image">'},
          {'content': '<p>正文</p>', 'bid': 795},
          {'content': '<p>正文</p>', 'cid': 764},
          {'content': '<p>正文</p>', 'bid': null},
        ]) {
          expect(
            HuanmengSource.canVerifyResponse(target, _data(fields)),
            false,
            reason: fields.toString(),
          );
        }
        expect(
          HuanmengSource.canVerifyResponse(
            _target('content', {'bid': '794'}),
            _data({'content': '正文'}),
          ),
          false,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            target,
            _data({'content': '${'<div>' * 135}正文${'</div>' * 135}'}),
          ),
          false,
        );
      },
    );

    test('list rows, duplicates and chapter book ownership are validated', () {
      for (final rows in <List<dynamic>>[
        [null],
        [123],
        [{}],
        [
          {..._book(), 'id': 0},
        ],
        [
          {..._book(), 'name': ' '},
        ],
        [
          {..._book(), 'pic': []},
        ],
        [_book(), _book()],
      ]) {
        expect(
          HuanmengSource.canVerifyResponse(
            _target('search'),
            _data({'list': rows}),
          ),
          false,
        );
      }
      final chapters = _target('chapters', {'id': '794'});
      for (final rows in <List<dynamic>>[
        [
          {'bid': 795, 'id': 763, 'name': '第一章'},
        ],
        [
          {'id': 763, 'name': '第一章'},
        ],
        [
          {'bid': 794, 'id': 763, 'name': ''},
        ],
        [
          {'bid': 794, 'id': 763, 'name': '第一章'},
          {'bid': 794, 'id': '763', 'name': '重复'},
        ],
      ]) {
        expect(
          HuanmengSource.canVerifyResponse(chapters, _data({'list': rows})),
          false,
        );
      }
      expect(
        HuanmengSource.canVerifyResponse(
          _target('search'),
          _data({
            'list': [_book()],
            'total': 0,
          }),
        ),
        false,
      );
      expect(
        HuanmengSource.canVerifyResponse(
          _target('search'),
          _data({'list': [], 'total': -1}),
        ),
        false,
      );
    });

    test(
      'per-page bounds do not mistake a current catalog page for the entire catalog',
      () {
        final twenty = List.generate(20, (index) => _book(index + 1));
        expect(
          HuanmengSource.canVerifyResponse(
            _target('search'),
            _data({'list': twenty}),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            _target('search'),
            _data({
              'list': [...twenty, _book(21)],
            }),
          ),
          false,
        );
        final rows = List.generate(
          5000,
          (index) => {'bid': 794, 'id': index + 1, 'name': '章节${index + 1}'},
        );
        final target = _target('chapters', {'id': '794'});
        expect(
          HuanmengSource.canVerifyResponse(
            target,
            _data({'list': rows, 'total': 6000}),
          ),
          true,
        );
        expect(
          HuanmengSource.canVerifyResponse(
            target,
            _data({
              'list': [
                ...rows,
                {'bid': 794, 'id': 5001, 'name': '超限'},
              ],
            }),
          ),
          false,
        );
      },
    );
  });
}

class _Transport implements HuanmengTransport {
  _Transport(this.response);
  final Future<Map<String, dynamic>> Function(Uri) response;
  final visited = <Uri>[];
  @override
  Future<Map<String, dynamic>> read(Uri uri) {
    visited.add(uri);
    return response(uri);
  }
}
