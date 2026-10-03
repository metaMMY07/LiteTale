import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/utils/wenku8_home_dom.dart';

const _apiHost = 'https://www.wenku8.net';

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
  late String fixture;
  late String modernFixture;

  setUpAll(() async {
    fixture = await File('test/fixtures/wenku8_home_index.html').readAsString();
    modernFixture =
        await File('test/fixtures/wenku8_home_modern.html').readAsString();
  });

  test(
    'keeps the fixture parser and maps usable books without fixed positions',
    () {
      final blocks = parseWenku8HomeIndexHtml(fixture);

      expect(blocks.map((block) => block.title), ['中心推荐', '新书推荐', '人气榜']);
      expect(blocks[0].list, hasLength(2));
      expect(blocks[0].list[0].title, '中心小说甲');
      expect(
        blocks[0].list[0].img,
        'https://img.wenku8.com/files/article/image/101/101s.jpg',
      );
      expect(
        blocks[0].list[0].detailUrl,
        'https://www.wenku8.net/book/101.htm',
      );
      expect(blocks[0].list[0].aid, '101');
      expect(blocks[0].list[1].title, '中心小说丁');
      expect(
        blocks[0].list[1].detailUrl,
        'https://www.wenku8.net/book/104.htm',
      );
      expect(blocks[0].list[1].aid, '104');
      expect(blocks[1].list.single.title, '新书小说乙');
      expect(
        blocks[1].list.single.detailUrl,
        'https://www.wenku8.net/book/102.htm',
      );
      expect(blocks[2].list.single.title, '热门书丙');
      expect(
        blocks[2].list.single.img,
        'https://img.wenku8.com/files/article/image/203/203s.jpg',
      );
      expect(
        blocks[2].list.single.detailUrl,
        'https://www.wenku8.net/book/203.htm',
      );
      expect(blocks[2].list.single.aid, '203');
    },
  );

  test(
    'supports modern tables, nested cards, lazy images and sparse book fields',
    () {
      final blocks = parseWenku8HomeIndexHtml(modernFixture);

      expect(blocks.map((block) => block.title), ['10月新番', '新书风云榜', '本周推荐']);
      expect(blocks[0].list.map((book) => book.aid), [
        '31001',
        '31002',
        '31006',
      ]);
      expect(blocks[0].list[0].title, '十月新番第一册');
      expect(
        blocks[0].list[0].img,
        'https://img.wenku8.com/files/article/image/310/31001s.jpg',
      );
      expect(
        blocks[0].list[1].detailUrl,
        'https://www.wenku8.net/book/31002.htm',
      );
      expect(
        blocks[0].list[2].detailUrl,
        'https://www.wenku8.net/book/31006.htm',
      );
      expect(blocks[0].list[2].title, '同源 HTTP 书');
      expect(blocks[1].list.map((book) => book.aid), ['41001', '41002']);
      expect(blocks[1].list[1].title, '榜单亚军');
      expect(blocks[2].list.single.title, '周推荐唯一书名');
      expect(blocks[2].list.single.aid, '51001');
    },
  );

  test('accepts the compact same-host homepage contract', () {
    final blocks = parseWenku8HomeWebViewResult(
      jsonEncode({
        'url': '$_apiHost/',
        'challenge': false,
        'blocks': [
          {
            'title': '推荐',
            'covers': [
              {
                'title': '中心小说甲',
                'image': 'http://img.wenku8.com/101.jpg',
                'detailUrl': 'http://www.wenku8.net/book/101.htm',
                'aid': '101',
              },
            ],
          },
        ],
      }),
      apiHost: _apiHost,
      loadedUrl: '$_apiHost/',
    );

    expect(blocks.first.list.first.aid, '101');
    expect(blocks.first.list.first.detailUrl, '$_apiHost/book/101.htm');
    expect(blocks.first.list.first.img, 'https://img.wenku8.com/101.jpg');
  });

  test(
    'executes the actual WebView JavaScript against the modern fixture DOM',
    () async {
      final modulePath = _playwrightModulePath()!;
      final browserExecutable = _playwrightBrowserExecutable()!;
      final harness = File(
        'test/scripts/wenku8_home_dom_playwright_harness.cjs',
      );
      final process = await Process.start(
        'node',
        [harness.absolute.path],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'PLAYWRIGHT_MODULE_PATH': modulePath,
          'PLAYWRIGHT_EXECUTABLE_PATH': browserExecutable,
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
      process.stdin.write(
        jsonEncode({
          'script': wenku8HomeDomExtractionScript(_apiHost),
          'cases': [
            {'html': modernFixture, 'url': '$_apiHost/'},
            {'html': fixture, 'url': '$_apiHost/'},
            {
              'html':
                  '<!doctype html><title>Just a moment</title><div id="challenge-form"><input name="username"></div>',
              'url': '$_apiHost/',
            },
            {'html': modernFixture, 'url': 'https://foreign.example/'},
          ],
        }),
      );
      await process.stdin.close();
      final exitCode = await process.exitCode;
      await Future.wait([outFuture, errFuture]);
      expect(exitCode, 0, reason: stderr.toString());
      final results = jsonDecode(stdout.toString()) as List;
      final modernBlocks = parseWenku8HomeWebViewResult(
        results[0],
        apiHost: _apiHost,
        loadedUrl: '$_apiHost/',
      );
      expect(modernBlocks.map((block) => block.title), [
        '10月新番',
        '新书风云榜',
        '本周推荐',
      ]);
      expect(
        modernBlocks
            .expand((block) => block.list)
            .map((book) => book.aid)
            .toList(),
        ['31001', '31002', '31006', '41001', '41002', '51001'],
      );
      final oldBlocks = parseWenku8HomeWebViewResult(
        results[1],
        apiHost: _apiHost,
        loadedUrl: '$_apiHost/',
      );
      expect(oldBlocks.first.list.first.title, '中心小说甲');
      expect(oldBlocks.last.list.single.title, '热门书丙');
      expect(jsonDecode(results[2] as String)['challenge'], isTrue);
      expect(
        () => parseWenku8HomeWebViewResult(results[2], apiHost: _apiHost),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult(results[3], apiHost: _apiHost),
        throwsFormatException,
      );
    },
    skip:
        _playwrightModulePath() == null ||
                _playwrightBrowserExecutable() == null
            ? 'Playwright and a Chromium-compatible browser are optional; set PLAYWRIGHT_MODULE_PATH and PLAYWRIGHT_EXECUTABLE_PATH to run DOM integration cases.'
            : null,
  );

  test(
    'keeps extraction limited to fields and excludes unrelated page reads',
    () {
      final script = wenku8HomeDomExtractionScript(_apiHost);

      expect(script, contains('blocks: []'));
      expect(script, contains('detailUrl: card.book.url'));
      expect(script, isNot(contains('document.forms')));
      expect(script, isNot(contains('document.body.innerHTML')));
      expect(script, isNot(contains('document.cookie')));
    },
  );

  test('filters bad cards and empty sections without losing valid books', () {
    final blocks = parseWenku8HomeWebViewResult({
      'url': '$_apiHost/?charset=GBK',
      'challenge': false,
      'blocks': [
        {'title': '', 'covers': []},
        {
          'title': '有效组',
          'covers': [
            {
              'title': '有效书',
              'image': 'https://img.wenku8.com/101.jpg',
              'detailUrl': '/book/101.htm',
              'aid': '101',
            },
            {
              'title': '广告',
              'image': 'https://ads.example/ad.jpg',
              'detailUrl': 'https://ads.example/book/999.htm',
              'aid': '999',
            },
            {
              'title': '缺 aid',
              'image': 'https://img.wenku8.com/102.jpg',
              'detailUrl': '/book/102.htm',
            },
            {
              'title': '错误 aid',
              'image': 'https://img.wenku8.com/103.jpg',
              'detailUrl': '/book/103.htm',
              'aid': 'x103',
            },
            {
              'title': '查询链接',
              'image': 'https://img.wenku8.com/104.jpg',
              'detailUrl': '/book/104.htm?from=ad',
              'aid': '104',
            },
          ],
        },
      ],
    }, apiHost: _apiHost);
    expect(blocks, hasLength(1));
    expect(blocks.single.list.map((book) => book.aid), ['101']);
  });

  test(
    'rejects challenge, login, foreign origin, changed port, redirect and empty result',
    () {
      final base = <String, Object?>{
        'url': '$_apiHost/',
        'challenge': false,
        'blocks': [
          {
            'title': '中心推荐',
            'covers': [
              {
                'title': '中心小说甲',
                'image': 'https://img.wenku8.com/101.jpg',
                'detailUrl': '/book/101.htm',
                'aid': '101',
              },
            ],
          },
        ],
      };

      expect(
        () => parseWenku8HomeWebViewResult({
          ...base,
          'challenge': true,
        }, apiHost: _apiHost),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult({
          ...base,
          'url': '$_apiHost/login.php',
        }, apiHost: _apiHost),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult({
          ...base,
          'url': 'https://example.com/',
        }, apiHost: _apiHost),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult({
          ...base,
          'url': 'https://www.wenku8.net:8443/',
        }, apiHost: _apiHost),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult(
          base,
          apiHost: _apiHost,
          loadedUrl: '$_apiHost/index.php',
        ),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult({
          ...base,
          'blocks': [],
        }, apiHost: _apiHost),
        throwsFormatException,
      );
      expect(
        () => parseWenku8HomeWebViewResult({
          ...base,
          'url': '$_apiHost/login.php',
        }, apiHost: _apiHost),
        throwsFormatException,
      );
    },
  );
}
