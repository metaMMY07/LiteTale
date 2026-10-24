import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/utils/bili_site_dom.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  BiliBrowserSession session(
    _Port port, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    final s = BiliBrowserSession(
      startupGrace: Duration.zero,
      operationTimeout: timeout,
      pollInterval: const Duration(milliseconds: 1),
    );
    s.attach(port, s.rendererGeneration);
    addTearDown(s.dispose);
    return s;
  }

  test('uses ordinary form and handles a single-book site redirect', () async {
    final p = _Port();
    final s = session(p);
    final result = await s.search('seabed', 1);
    expect(result.records.single.aid, 'bili:2844');
    expect(result.records.single.title, 'SeaBed');
    expect(p.urls, ['https://www.bilinovel.net/search.html', 'about:blank']);
    expect(p.submitted, true);
  });
  test(
    'cold renderer attachment uses the remaining operation budget',
    () async {
      final s = BiliBrowserSession(
        startupGrace: Duration.zero,
        operationTimeout: const Duration(seconds: 8),
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(s.dispose);
      final attachment = Timer(
        const Duration(milliseconds: 5100),
        () => s.attach(_Port(), s.rendererGeneration),
      );
      addTearDown(attachment.cancel);
      final result = await s.search('seabed', 1);
      expect(result.records.single.title, 'SeaBed');
      expect(s.rendererGeneration, 0);
    },
  );
  test(
    'an unattached renderer still expires within the operation budget',
    () async {
      final s = BiliBrowserSession(
        operationTimeout: const Duration(milliseconds: 40),
        startupGrace: Duration.zero,
      );
      addTearDown(s.dispose);
      await expectLater(
        s.search('seabed', 1),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(s.rendererGeneration, greaterThan(0));
    },
  );
  test('reads selected public document data without API calls', () async {
    final p = _Port();
    final markup = await session(
      p,
    ).document(Uri.parse('https://www.linovelib.com/novel/2844/catalog'));
    expect(markup, contains('volume-list'));
    expect(p.urls, [
      'https://www.linovelib.com/novel/2844/catalog',
      'about:blank',
    ]);
  });
  test('real next search link is associated with its query', () async {
    final p =
        _Port()..next = 'https://www.linovelib.com/S6/?page=2&searchkey=sea';
    final s = session(p);
    expect((await s.search('sea', 1)).maxPage, 2);
    p.next = null;
    expect((await s.search('sea', 2)).currentPage, 2);
    expect(
      p.urls,
      contains('https://www.linovelib.com/S6/?page=2&searchkey=sea'),
    );
    await expectLater(
      s.search('different', 2),
      throwsA(isA<BiliBrowserException>()),
    );
  });
  test('rejects foreign search pagination instead of following it', () async {
    final p = _Port()..next = 'https://other.example/S6/?page=2';
    await expectLater(
      session(p).search('sea', 1),
      throwsA(isA<BiliBrowserException>()),
    );
    expect(p.urls.every(BiliBrowserSession.allowsNavigation), true);
  });
  test('search pagination waits for its committed URL and next link', () async {
    final p =
        _Port()
          ..next = 'https://www.bilinovel.net/search.html?searchkey=sea&page=2';
    final s = session(p);
    await s.search('sea', 1);
    p.next = null;
    p.searchResponses.addAll([
      {
        'url': 'https://www.bilinovel.net/search.html?searchkey=sea&page=1',
        'ready': true,
        'books': [
          {'nid': '1', 'title': 'Old page'},
        ],
        'next': 'https://www.bilinovel.net/search.html?searchkey=sea&page=2',
      },
      {
        'url': 'https://www.bilinovel.net/search.html?searchkey=sea&page=1',
        'ready': false,
        'error': 'Stale page error',
      },
      {
        'url': 'https://www.bilinovel.net/search.html?page=2&searchkey=sea',
        'ready': true,
        'books': [
          {'nid': '2', 'title': 'New page'},
        ],
        'next': 'https://www.bilinovel.net/search.html?searchkey=sea&page=3',
      },
    ]);
    final second = await s.search('sea', 2);
    expect(second.records.single.title, 'New page');
    expect(second.maxPage, 3);
    expect(p.searchProbes, 4);
    expect((await s.search('sea', 3)).currentPage, 3);
    expect(
      p.urls,
      contains('https://www.bilinovel.net/search.html?searchkey=sea&page=3'),
    );
  });
  test('mobile search pagination retains the real next link', () async {
    final p =
        _Port()
          ..next = 'https://www.bilinovel.net/search.html?searchkey=sea&page=2';
    final s = session(p);
    expect((await s.search('sea', 1)).maxPage, 2);
    p.next = null;
    await s.search('sea', 2);
    expect(
      p.urls,
      contains('https://www.bilinovel.net/search.html?searchkey=sea&page=2'),
    );
    p.next = 'https://www.bilinovel.net/search.html?searchkey=different&page=2';
    await expectLater(s.search('sea', 1), throwsA(isA<BiliBrowserException>()));
  });
  test(
    'waits for navigation instead of accepting the previous document',
    () async {
      final p = _Port()..staleDocumentUrl = 'https://www.bilinovel.net/';
      final result = await session(
        p,
      ).document(Uri.parse('https://www.bilinovel.net/novel/2844/catalog'));
      expect(result, contains('volume-list'));
      expect(p.documentProbes, 2);
    },
  );
  test(
    'expiring a queued request does not replace the active renderer',
    () async {
      final p = _Port()..documentGate = Completer<void>();
      final s = session(p, timeout: const Duration(milliseconds: 300));
      final document = s.document(
        Uri.parse('https://www.bilinovel.net/novel/2844/catalog'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(
        s.search('sea', 1),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(s.rendererGeneration, 0);
      p.documentGate!.complete();
      expect(await document, contains('volume-list'));
    },
  );
  test(
    'reads same-chapter pages and never advances to another chapter',
    () async {
      final p =
          _Port()..chapterNext = 'https://www.bilinovel.net/novel/1/2_2.html';
      final chapter = await session(p).chapter('bili:1', 'bili:1:2');
      expect(chapter.content, '第一页\n第二页');
      expect(p.urls, contains('https://www.bilinovel.net/novel/1/2_2.html'));
      final bad =
          _Port()..chapterNext = 'https://www.bilinovel.net/novel/1/3.html';
      await expectLater(
        session(bad).chapter('bili:1', 'bili:1:2'),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(
        bad.urls,
        isNot(contains('https://www.bilinovel.net/novel/1/3.html')),
      );
    },
  );
  test('reads twelve pages beyond the old eight-page ceiling', () async {
    final p = _Port()..chapterPages = 12;
    final chapter = await session(p).chapter('bili:1', 'bili:1:2');
    expect(chapter.content, List.generate(12, (i) => '第${i + 1}页').join('\n'));
    expect(p.urls.where((url) => url.startsWith('https:')), hasLength(12));
  });

  test(
    'unbounded chapter navigation retains a finite safety ceiling',
    () async {
      final p = _Port()..chapterPages = BiliBrowserSession.maxChapterPages + 1;
      await expectLater(
        session(p).chapter('bili:1', 'bili:1:2'),
        throwsA(
          isA<BiliBrowserException>().having(
            (error) => error.message,
            'message',
            contains('64页安全上限'),
          ),
        ),
      );
      expect(
        p.urls.where((url) => url.startsWith('https:')),
        hasLength(BiliBrowserSession.maxChapterPages),
      );
    },
  );

  test('rejects wrong book before navigation', () async {
    final p = _Port();
    await expectLater(
      session(p).chapter('bili:1', 'bili:8:2'),
      throwsFormatException,
    );
    expect(p.urls, ['about:blank']);
  });
  test(
    'uses the original mobile reader without a desktop mode switch',
    () async {
      final p = _Port();
      final s = session(p);
      await s.chapter('bili:1', 'bili:1:2');
      await s.document(
        Uri.parse('https://www.bilinovel.net/novel/2844/catalog'),
      );
      expect(p.urls, contains('https://www.bilinovel.net/novel/1/2.html'));
      expect(p.modes, [false, false]);
    },
  );
  test('blocked mobile catalogue has one same-site desktop fallback', () async {
    final p = _Port()..blockMobileCatalog = true;
    final s = session(p);
    await s.document(Uri.parse('https://www.bilinovel.net/novel/2844/catalog'));
    expect(p.urls, [
      'https://www.bilinovel.net/novel/2844/catalog',
      'https://www.linovelib.com/novel/2844/catalog',
      'about:blank',
    ]);
    expect(p.modes, [false, true]);
  });
  test(
    'denied catalogue is not a challenge and does not try another host',
    () async {
      final p = _Port()..denyMobileCatalog = true;
      await expectLater(
        session(
          p,
        ).document(Uri.parse('https://www.bilinovel.net/novel/2844/catalog')),
        throwsA(isA<BiliSiteAccessDenied>()),
      );
      expect(p.urls, [
        'https://www.bilinovel.net/novel/2844/catalog',
        'about:blank',
      ]);
    },
  );
  test('mobile chapter pagination cannot cross to the desktop host', () async {
    final p =
        _Port()..chapterNext = 'https://www.linovelib.com/novel/1/2_2.html';
    await expectLater(
      session(p).chapter('bili:1', 'bili:1:2'),
      throwsA(isA<BiliBrowserException>()),
    );
    expect(p.urls, ['https://www.bilinovel.net/novel/1/2.html', 'about:blank']);
  });
  test(
    'blank search response is a bounded failure, never empty success',
    () async {
      final p = _Port()..blank = true;
      await expectLater(
        session(p, timeout: const Duration(milliseconds: 40)).search('sea', 1),
        throwsA(isA<BiliBrowserException>()),
      );
    },
  );
  test(
    'stalled platform command is bounded and renderer is replaced',
    () async {
      final p = _Port()..stall = true;
      final s = session(p, timeout: const Duration(milliseconds: 300));
      await expectLater(
        s.search('sea', 1),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(s.rendererGeneration, greaterThan(0));
    },
  );
  test('allows only ordinary read/search pages on the known sites', () {
    expect(
      BiliBrowserSession.allowsNavigation(
        'https://www.bilinovel.net/search.html',
      ),
      true,
    );
    expect(
      BiliBrowserSession.allowsNavigation(
        'https://www.bilinovel.net/wenku/lastupdate_0_0_0_0_0_0_0_2_0.html',
      ),
      true,
    );
    expect(
      BiliBrowserSession.allowsNavigation(
        'https://www.bilinovel.net/novel/1/2.html',
      ),
      true,
    );
    expect(
      BiliBrowserSession.allowsNavigation(
        'https://www.linovelib.com/S6/?page=2',
      ),
      true,
    );
    for (final url in [
      'https://evil.example/novel/1.html',
      'file:///tmp/test',
      'https://user:password@www.linovelib.com/',
      'https://www.linovelib.com/login.php',
    ]) {
      expect(BiliBrowserSession.allowsNavigation(url), false);
    }
  });
}

class _Port implements BiliBrowserPort {
  final urls = <String>[];
  String current = 'about:blank';
  String? next, chapterNext;
  int? chapterPages;
  bool submitted = false, blank = false, stall = false;
  String? staleDocumentUrl;
  int documentProbes = 0;
  int searchProbes = 0;
  final searchResponses = <Map<String, dynamic>>[];
  Completer<void>? documentGate;
  final modes = <bool>[];
  bool blockMobileCatalog = false;
  bool denyMobileCatalog = false;
  @override
  Future<void> setDesktopSite(bool enabled) async {
    modes.add(enabled);
  }

  @override
  Future<void> loadUrl(String url) async {
    urls.add(url);
    current = url;
  }

  @override
  Future<dynamic> executeScript(String script) async {
    if (stall) return Completer<dynamic>().future;
    if (script == biliDocumentProbeScript) {
      if (denyMobileCatalog) {
        return {'url': current, 'accessDenied': true, 'ready': false};
      }
      if (blockMobileCatalog &&
          current.startsWith('https://www.bilinovel.net/')) {
        return {
          'url': current,
          'error': '原站要求验证',
          'ready': false,
          'verificationRequired': true,
        };
      }
      documentProbes++;
      await documentGate?.future;
      final url = staleDocumentUrl ?? current;
      staleDocumentUrl = null;
      return {
        'url': url,
        'ready': true,
        'html': '<div id="volume-list"></div>',
      };
    }
    if (script == biliHomeReadyScript) return {'url': current, 'ready': true};
    if (script == biliSearchProbeScript) {
      searchProbes++;
      if (searchResponses.isNotEmpty) return searchResponses.removeAt(0);
      return {
        'url': current,
        'ready': !blank,
        'books': [
          {
            'nid': '2844',
            'title': 'SeaBed',
            'image': 'https://www.linovelib.com/cover.jpg',
          },
        ],
        'next': next,
      };
    }
    if (script == biliChapterProbeScript) {
      final pages = chapterPages;
      if (pages != null) {
        final page = int.parse(
          RegExp(r'_(\d+)\.html$').firstMatch(current)?.group(1) ?? '1',
        );
        return {
          'url': current,
          'ready': true,
          'content': '第$page页',
          'next':
              page < pages
                  ? 'https://www.bilinovel.net/novel/1/2_${page + 1}.html'
                  : null,
        };
      }
      return {
        'url': current,
        'ready': true,
        'content': current.endsWith('_2.html') ? '第二页' : '第一页',
        'next': current.endsWith('_2.html') ? null : chapterNext,
      };
    }
    submitted = true;
    current = 'https://www.linovelib.com/novel/2844.html';
    return true;
  }
}
