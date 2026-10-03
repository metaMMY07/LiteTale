import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/utils/wenku8_read_dom.dart';

const _apiHost = 'https://www.wenku8.net';
const _aid = '101';

Map<String, Object?> _payload({
  required String kind,
  required String url,
  Object? data,
  String aid = '',
  bool challenge = false,
}) => {
  'url': url,
  'kind': kind,
  'aid': aid,
  'challenge': challenge,
  'data': data,
};

Map<String, Object?> _detailData({
  String title = '测试小说',
  String author = '测试作者',
  String status = '连载中',
  String image = 'http://img.wenku8.com/101.jpg',
}) => {
  'title': title,
  'author': author,
  'status': status,
  'finUpdate': '2026-10-01',
  'image': image,
  'introduce': '<b>简介</b><br>正文',
  'tags': ['奇幻', '校园'],
  'isAnimated': true,
};

Map<String, Object?> _chapter({
  required String cid,
  required String title,
  String aid = _aid,
  String? url,
}) => {
  'title': title,
  'url':
      url ??
      'https://www.wenku8.net/modules/article/reader.php?aid=$_aid&cid=$cid',
  'cid': cid,
  'aid': aid,
};

String? _playwrightModulePath() {
  final configured = Platform.environment['PLAYWRIGHT_MODULE_PATH'];
  if (configured != null &&
      (File(configured).existsSync() || Directory(configured).existsSync())) {
    return configured;
  }
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return null;
  final fallback =
      '$appData\\npm\\node_modules\\@playwright\\cli\\node_modules\\playwright';
  return Directory(fallback).existsSync() ? fallback : null;
}

String? _playwrightBrowserExecutable() {
  final configured = Platform.environment['PLAYWRIGHT_EXECUTABLE_PATH'];
  if (configured != null && File(configured).existsSync()) return configured;
  if (!Platform.isWindows) return null;
  for (final path in [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
  ]) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  test('maps detail fields into NovelInfo and normalizes its cover URL', () {
    final info =
        parseWenku8ReadWebViewResult(
              _payload(
                kind: 'detail',
                aid: _aid,
                url: '$_apiHost/book/$_aid.htm',
                data: _detailData(),
              ),
              apiHost: _apiHost,
              loadedUrl: '$_apiHost/book/$_aid.htm',
              kind: 'detail',
              aid: _aid,
            )
            as NovelInfo;

    expect(info.title, '测试小说');
    expect(info.author, '测试作者');
    expect(info.status, '连载中');
    expect(info.finUpdate, '2026-10-01');
    expect(info.imgUrl, 'https://img.wenku8.com/101.jpg');
    expect(info.introduce, '<b>简介</b><br>正文');
    expect(info.tags, ['奇幻', '校园']);
    expect(info.isAnimated, isTrue);
    expect(info.heat, isEmpty);
    expect(info.trending, isEmpty);
  });

  test('keeps reader volume and chapter order and binds every chapter to aid', () {
    final reader =
        parseWenku8ReadWebViewResult(
              _payload(
                kind: 'reader',
                aid: _aid,
                url:
                    '$_apiHost/modules/article/reader.php?aid=$_aid&charset=gbk',
                data: {
                  'volumes': [
                    {
                      'id': '7',
                      'title': '第一卷',
                      'chapters': [
                        _chapter(cid: '19', title: '第一话'),
                        _chapter(cid: '5', title: '序章'),
                      ],
                    },
                    {
                      'id': '8',
                      'title': '第二卷',
                      'chapters': [_chapter(cid: '23', title: '第二卷第一话')],
                    },
                  ],
                },
              ),
              apiHost: _apiHost,
              loadedUrl:
                  '$_apiHost/modules/article/reader.php?aid=$_aid&charset=gbk',
              kind: 'reader',
              aid: _aid,
            )
            as List<Volume>;

    expect(reader.map((volume) => volume.title), ['第一卷', '第二卷']);
    expect(reader.first.chapters.map((chapter) => chapter.cid), ['19', '5']);
    expect(reader.first.chapters.map((chapter) => chapter.aid), ['101', '101']);
    expect(reader.last.chapters.single.title, '第二卷第一话');
  });

  test(
    'accepts chapter image markers with HTTPS while preserving image host',
    () {
      final content =
          parseWenku8ReadWebViewResult(
                _payload(
                  kind: 'chapter',
                  aid: _aid,
                  url: '$_apiHost/novel/0/$_aid/19.htm',
                  data: {
                    'content':
                        '第一段\n<!--image-->https://pic.example.test/a.jpg<!--image-->\n末段',
                  },
                ),
                apiHost: _apiHost,
                loadedUrl: '$_apiHost/novel/0/$_aid/19.htm',
                kind: 'chapter',
                aid: _aid,
              )
              as String;
      expect(
        content,
        contains('<!--image-->https://pic.example.test/a.jpg<!--image-->'),
      );
      expect(
        () => parseWenku8ReadWebViewResult(
          _payload(
            kind: 'chapter',
            aid: _aid,
            url: '$_apiHost/novel/0/$_aid/19.htm',
            data: {'content': '<!--image-->javascript:alert(1)<!--image-->'},
          ),
          apiHost: _apiHost,
          loadedUrl: '$_apiHost/novel/0/$_aid/19.htm',
          kind: 'chapter',
          aid: _aid,
        ),
        throwsFormatException,
      );
    },
  );

  test('maps tag groups and book listings to their existing FRB models', () {
    final tags =
        parseWenku8ReadWebViewResult(
              _payload(
                kind: 'tags',
                url: '$_apiHost/modules/article/tags.php?charset=gbk',
                data: {
                  'groups': [
                    {
                      'title': '题材',
                      'tags': ['奇幻', '校园'],
                    },
                  ],
                },
              ),
              apiHost: _apiHost,
              loadedUrl: '$_apiHost/modules/article/tags.php?charset=gbk',
              kind: 'tags',
            )
            as List<TagGroup>;
    expect(tags.single.title, '题材');
    expect(tags.single.tags, ['奇幻', '校园']);

    final books =
        parseWenku8ReadWebViewResult(
              _payload(
                kind: 'list',
                url:
                    '$_apiHost/modules/article/toplist.php?sort=lastupdate&page=2',
                data: {
                  'currentPage': 2,
                  'maxPage': 7,
                  'records': [
                    {
                      'title': '列表书',
                      'image': 'http://img.wenku8.com/102.jpg',
                      'detailUrl': '$_apiHost/book/102.htm',
                      'aid': '102',
                    },
                  ],
                },
              ),
              apiHost: _apiHost,
              loadedUrl:
                  '$_apiHost/modules/article/toplist.php?sort=lastupdate&page=2',
              kind: 'list',
            )
            as PageStatsNovelCover;
    expect(books.currentPage, 2);
    expect(books.maxPage, 7);
    expect(books.records.single.aid, '102');
    expect(books.records.single.img, 'https://img.wenku8.com/102.jpg');
  });

  test(
    'accepts legacy GBK percent bytes in tag-list URLs without UTF-8 decoding',
    () {
      final data = {
        'currentPage': 1,
        'maxPage': 1,
        'records': [
          {
            'title': 'GBK 标签结果',
            'image': 'https://img.wenku8.com/201.jpg',
            'detailUrl': '$_apiHost/book/201.htm',
            'aid': '201',
          },
        ],
      };
      final urls = [
        for (final encodedTag in ['%D0%A3%D4%B0', '%C7%E6'])
          '$_apiHost/modules/article/tags.php?t=$encodedTag&v=0&page=1&charset=gbk',
        '$_apiHost/modules/article/search.php?searchtype=articlename&searchkey=%C7%E6&page=1&charset=gbk',
      ];
      for (final url in urls) {
        final result =
            parseWenku8ReadWebViewResult(
                  _payload(kind: 'list', url: url, data: data),
                  apiHost: _apiHost,
                  loadedUrl: url,
                  kind: 'list',
                )
                as PageStatsNovelCover;
        expect(result.records.single.aid, '201');
      }
    },
  );

  test('rejects changed origin, bad route, wrong book id, and redirects', () {
    final good = _payload(
      kind: 'detail',
      aid: _aid,
      url: '$_apiHost/book/$_aid.htm',
      data: _detailData(),
    );
    void parse(Object? value, String loadedUrl, {String aid = _aid}) {
      parseWenku8ReadWebViewResult(
        value,
        apiHost: _apiHost,
        loadedUrl: loadedUrl,
        kind: 'detail',
        aid: aid,
      );
    }

    expect(
      () => parse(good, 'https://foreign.example/book/$_aid.htm'),
      throwsFormatException,
    );
    expect(
      () => parse(
        _payload(
          kind: 'detail',
          aid: _aid,
          url: '$_apiHost/book/102.htm',
          data: _detailData(),
        ),
        '$_apiHost/book/102.htm',
      ),
      throwsFormatException,
    );
    expect(() => parse(good, '$_apiHost/login.php'), throwsFormatException);
    expect(
      () => parse(good, 'https://www.wenku8.net:444/book/$_aid.htm'),
      throwsFormatException,
    );
    expect(
      () => parse(good, '$_apiHost/book/$_aid.htm', aid: '102'),
      throwsFormatException,
    );
  });

  test(
    'rejects CF/login results and does not treat empty pages as success',
    () {
      final url = '$_apiHost/book/$_aid.htm';
      expect(
        () => parseWenku8ReadWebViewResult(
          _payload(
            kind: 'detail',
            aid: _aid,
            url: url,
            data: _detailData(),
            challenge: true,
          ),
          apiHost: _apiHost,
          loadedUrl: url,
          kind: 'detail',
          aid: _aid,
        ),
        throwsFormatException,
      );
      expect(
        () => parseWenku8ReadWebViewResult(
          _payload(
            kind: 'chapter',
            aid: _aid,
            url: '$_apiHost/novel/0/$_aid/19.htm',
            data: {'content': '  '},
          ),
          apiHost: _apiHost,
          loadedUrl: '$_apiHost/novel/0/$_aid/19.htm',
          kind: 'chapter',
          aid: _aid,
        ),
        throwsFormatException,
      );
    },
  );

  test('rejects cross-book chapters, foreign images, and oversized fields', () {
    final readerUrl = '$_apiHost/modules/article/reader.php?aid=$_aid';
    expect(
      () => parseWenku8ReadWebViewResult(
        _payload(
          kind: 'reader',
          aid: _aid,
          url: readerUrl,
          data: {
            'volumes': [
              {
                'id': '1',
                'title': '第一卷',
                'chapters': [
                  _chapter(
                    cid: '1',
                    title: '越书章节',
                    url:
                        'https://evil.example/modules/article/reader.php?aid=$_aid&cid=1',
                  ),
                ],
              },
            ],
          },
        ),
        apiHost: _apiHost,
        loadedUrl: readerUrl,
        kind: 'reader',
        aid: _aid,
      ),
      throwsFormatException,
    );
    expect(
      () => parseWenku8ReadWebViewResult(
        _payload(
          kind: 'detail',
          aid: _aid,
          url: '$_apiHost/book/$_aid.htm',
          data: _detailData(image: 'https://evil.example/cover.jpg'),
        ),
        apiHost: _apiHost,
        loadedUrl: '$_apiHost/book/$_aid.htm',
        kind: 'detail',
        aid: _aid,
      ),
      throwsFormatException,
    );
    expect(
      () => parseWenku8ReadWebViewResult(
        _payload(
          kind: 'chapter',
          aid: _aid,
          url: '$_apiHost/novel/0/$_aid/1.htm',
          data: {'content': '正文' * 200000},
        ),
        apiHost: _apiHost,
        loadedUrl: '$_apiHost/novel/0/$_aid/1.htm',
        kind: 'chapter',
        aid: _aid,
      ),
      throwsFormatException,
    );
    expect(
      () => parseWenku8ReadWebViewResult(
        jsonEncode(
          _payload(
            kind: 'tags',
            url: '$_apiHost/modules/article/tags.php',
            data: {'groups': []},
          ),
        ),
        apiHost: _apiHost,
        loadedUrl: '$_apiHost/modules/article/tags.php',
        kind: 'tags',
      ),
      throwsFormatException,
    );
  });

  test('script only returns the requested compact extraction contract', () {
    final script = wenku8ReadDomExtractionScript(
      _apiHost,
      kind: 'chapter',
      aid: _aid,
    );
    expect(script, contains("document.querySelector('#content')"));
    expect(script, contains('<!--image-->'));
    expect(script, isNot(contains('document.cookie')));
    expect(script, isNot(contains('document.body.innerHTML')));
    expect(script, isNot(contains('document.forms')));
    expect(
      () => wenku8ReadDomExtractionScript(_apiHost, kind: 'account'),
      throwsFormatException,
    );
  });

  test(
    'executes every generated extractor on local Wenku8 fixtures without network access',
    () async {
      const nodeHarness = r'''
const fs = require('fs');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);
(async () => {
  const cases = JSON.parse(fs.readFileSync(0, 'utf8'));
  const browser = await chromium.launch({headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH});
  const output = [];
  try {
    for (const item of cases) {
      const page = await browser.newPage();
      await page.route('**/*', route => route.request().isNavigationRequest() && route.request().url() === item.url
        ? route.fulfill({status: 200, contentType: 'text/html; charset=utf-8', body: item.html})
        : route.abort());
      await page.goto(item.url);
      output.push(await page.evaluate(script => window.eval(script), item.script));
      await page.close();
    }
  } finally { await browser.close(); }
  process.stdout.write(JSON.stringify(output));
})().catch(error => { process.stderr.write(String(error.stack || error)); process.exit(1); });
''';
      final fixtures = {
        'detail':
            await File('test/fixtures/wenku8_read_detail.html').readAsString(),
        'detailLong':
            await File(
              'test/fixtures/wenku8_read_detail_long_tags.html',
            ).readAsString(),
        'reader':
            await File('test/fixtures/wenku8_read_reader.html').readAsString(),
        'chapter':
            await File('test/fixtures/wenku8_read_chapter.html').readAsString(),
        'tags':
            await File('test/fixtures/wenku8_read_tags.html').readAsString(),
        'list':
            await File('test/fixtures/wenku8_read_list.html').readAsString(),
        'listSearch':
            await File('test/fixtures/wenku8_read_list.html').readAsString(),
        'detailEnglishTags': (await File(
              'test/fixtures/wenku8_read_detail.html',
            ).readAsString())
            .replaceFirst('标签：', '作品Tags: '),
        'listModern':
            await File(
              'test/fixtures/wenku8_read_list_modern.html',
            ).readAsString(),
        'listEmpty':
            '<html><body><div id="content">没有符合条件的结果！</div></body></html>',
        'listEmptyGrid':
            '<html><body><div id="content"><table class="grid"><tr><td></td></tr><tr><td><em id="pagestats">1/1</em><a href="?page=1">首页</a></td></tr></table></div></body></html>',
        'listUnknownEmpty':
            '<html><body><div id="content">本页面暂未找到加载组件。</div></body></html>',
      };
      const urls = {
        'detail': '$_apiHost/book/$_aid.htm',
        'detailLong':
            '$_apiHost/modules/article/articleinfo.php?id=$_aid&charset=gbk',
        'reader': '$_apiHost/modules/article/reader.php?aid=$_aid&charset=gbk',
        'chapter': '$_apiHost/novel/0/$_aid/19.htm',
        'tags': '$_apiHost/modules/article/tags.php?charset=gbk',
        'list':
            '$_apiHost/modules/article/toplist.php?sort=lastupdate&page=2&charset=gbk',
        'listSearch':
            '$_apiHost/modules/article/search.php?searchtype=articlename&searchkey=%C7%E6&page=1&charset=gbk',
        'detailEnglishTags': '$_apiHost/book/$_aid.htm',
        'listModern':
            '$_apiHost/modules/article/search.php?searchtype=articlename&searchkey=Re&page=1&charset=gbk',
        'listEmpty':
            '$_apiHost/modules/article/search.php?searchtype=articlename&searchkey=missing&page=1&charset=gbk',
        'listEmptyGrid':
            '$_apiHost/modules/article/search.php?searchtype=articlename&searchkey=missing-grid&page=1&charset=gbk',
        'listUnknownEmpty':
            '$_apiHost/modules/article/search.php?searchtype=articlename&searchkey=unknown&page=1&charset=gbk',
      };
      final cases = <Map<String, Object?>>[];
      for (final fixture in fixtures.entries) {
        final kind = switch (fixture.key) {
          'listSearch' ||
          'listModern' ||
          'listEmpty' ||
          'listEmptyGrid' ||
          'listUnknownEmpty' => 'list',
          'detailLong' || 'detailEnglishTags' => 'detail',
          _ => fixture.key,
        };
        cases.add({
          'html': fixture.value,
          'url': urls[fixture.key],
          'script': wenku8ReadDomExtractionScript(
            _apiHost,
            kind: kind,
            aid:
                const {'detail', 'reader', 'chapter'}.contains(kind)
                    ? _aid
                    : null,
          ),
        });
      }
      final process = await Process.start(
        'node',
        ['-e', nodeHarness],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'PLAYWRIGHT_MODULE_PATH': _playwrightModulePath()!,
          'PLAYWRIGHT_EXECUTABLE_PATH': _playwrightBrowserExecutable()!,
        },
      );
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final outFuture =
          process.stdout
              .transform(utf8.decoder)
              .listen(stdout.write)
              .asFuture<void>();
      final errFuture =
          process.stderr
              .transform(utf8.decoder)
              .listen(stderr.write)
              .asFuture<void>();
      process.stdin.write(jsonEncode(cases));
      await process.stdin.close();
      final exitCode = await process.exitCode;
      await Future.wait([outFuture, errFuture]);
      expect(exitCode, 0, reason: stderr.toString());
      final results = jsonDecode(stdout.toString()) as List;
      expect(results, hasLength(12));
      final detail =
          parseWenku8ReadWebViewResult(
                results[0],
                apiHost: _apiHost,
                loadedUrl: urls['detail']!,
                kind: 'detail',
                aid: _aid,
              )
              as NovelInfo;
      expect(detail.title, 'Fixture 轻小说');
      expect(detail.author, '作者甲');
      expect(detail.tags, ['奇幻', '校园']);
      expect(detail.introduce, contains('简介正文'));
      expect(detail.introduce, isNot(contains('<script')));

      final detailLong =
          parseWenku8ReadWebViewResult(
                results[1],
                apiHost: _apiHost,
                loadedUrl: urls['detailLong']!,
                kind: 'detail',
                aid: _aid,
              )
              as NovelInfo;
      expect(detailLong.title, 'Fixture 标签前缀书');
      expect(detailLong.tags, ['科幻', '悬疑']);

      final reader =
          parseWenku8ReadWebViewResult(
                results[2],
                apiHost: _apiHost,
                loadedUrl: urls['reader']!,
                kind: 'reader',
                aid: _aid,
              )
              as List<Volume>;
      expect(reader.map((volume) => volume.title), ['第一卷 起始', '第二卷 远行']);
      expect(reader.first.chapters.map((chapter) => chapter.cid), ['5', '19']);
      expect(
        reader
            .expand((volume) => volume.chapters)
            .every((chapter) => chapter.aid == _aid),
        isTrue,
      );

      final chapter =
          parseWenku8ReadWebViewResult(
                results[3],
                apiHost: _apiHost,
                loadedUrl: urls['chapter']!,
                kind: 'chapter',
                aid: _aid,
              )
              as String;
      expect(chapter, contains('第一段 正文\n第二行'));
      expect(
        chapter,
        contains(
          '<!--image-->https://pic.example.test/novel/101/illust.jpg<!--image-->',
        ),
      );
      expect(chapter, isNot(contains('水印')));
      expect(chapter, isNot(contains('广告')));
      expect(chapter, isNot(contains('导航')));
      expect(chapter, isNot(contains('must not be copied')));

      final tags =
          parseWenku8ReadWebViewResult(
                results[4],
                apiHost: _apiHost,
                loadedUrl: urls['tags']!,
                kind: 'tags',
              )
              as List<TagGroup>;
      expect(tags.map((group) => group.title), ['题材', '情节']);
      expect(tags.first.tags, ['奇幻', '校园']);

      final list =
          parseWenku8ReadWebViewResult(
                results[5],
                apiHost: _apiHost,
                loadedUrl: urls['list']!,
                kind: 'list',
              )
              as PageStatsNovelCover;
      expect(list.currentPage, 2);
      expect(list.maxPage, 7);
      expect(list.records.single.aid, '102');

      final search =
          parseWenku8ReadWebViewResult(
                results[6],
                apiHost: _apiHost,
                loadedUrl: urls['listSearch']!,
                kind: 'list',
              )
              as PageStatsNovelCover;
      expect(search.records.single.aid, '102');
      final englishTags =
          parseWenku8ReadWebViewResult(
                results[7],
                apiHost: _apiHost,
                loadedUrl: urls['detailEnglishTags']!,
                kind: 'detail',
                aid: _aid,
              )
              as NovelInfo;
      expect(englishTags.tags, ['奇幻', '校园']);
      final modern =
          parseWenku8ReadWebViewResult(
                results[8],
                apiHost: _apiHost,
                loadedUrl: urls['listModern']!,
                kind: 'list',
              )
              as PageStatsNovelCover;
      expect(modern.records.map((book) => book.aid), ['102', '104']);
      expect(modern.records.map((book) => book.title), ['当前布局小说乙', '当前布局小说丁']);
      final empty =
          parseWenku8ReadWebViewResult(
                results[9],
                apiHost: _apiHost,
                loadedUrl: urls['listEmpty']!,
                kind: 'list',
              )
              as PageStatsNovelCover;
      expect(empty.records, isEmpty);
      final emptyGrid =
          parseWenku8ReadWebViewResult(
                results[10],
                apiHost: _apiHost,
                loadedUrl: urls['listEmptyGrid']!,
                kind: 'list',
              )
              as PageStatsNovelCover;
      expect(emptyGrid.records, isEmpty);
      expect(
        () => parseWenku8ReadWebViewResult(
          results[11],
          apiHost: _apiHost,
          loadedUrl: urls['listUnknownEmpty']!,
          kind: 'list',
        ),
        throwsFormatException,
      );
    },
    skip:
        _playwrightModulePath() == null ||
                _playwrightBrowserExecutable() == null
            ? 'Playwright and Chromium/Edge are optional; configure PLAYWRIGHT_MODULE_PATH and PLAYWRIGHT_EXECUTABLE_PATH to run fixture DOM integration.'
            : null,
  );
}
