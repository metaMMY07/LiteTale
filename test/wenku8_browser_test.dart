import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/services/wenku8_rate_limit.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart' as models;

const _host = 'https://www.wenku8.net';
const _png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

Map<String, Object?> _page(String url, {bool ready = true}) => {
  'url': url,
  'ready': ready,
  'challenge': false,
  'loginForm': false,
  'authenticated': false,
  'home': false,
};

Map<String, Object?> _detailPayload(String url, String aid) => {
  'url': url,
  'kind': 'detail',
  'aid': aid,
  'challenge': false,
  'data': {
    'title': 'Fixture $aid',
    'author': 'Local fixture',
    'status': '连载中',
    'finUpdate': '2026-10-01',
    'image': 'https://img.wenku8.com/$aid.jpg',
    'introduce': 'Local-only browser service fixture.',
    'tags': <String>[],
    'isAnimated': false,
  },
};

class _Harness {
  _Harness({
    Map<String, String> properties = const {},
    bool autoFinish = true,
    int staleBlankCallbacks = 0,
    bool supportDocuments = false,
    bool supportColdDocuments = false,
    Duration pageTimeout = const Duration(milliseconds: 500),
    Duration operationTimeout = const Duration(seconds: 30),
  }) : properties = Map<String, String>.from(properties) {
    session = Wenku8BrowserSession(
      readHost: () async => host,
      readProperty: (key) async => this.properties[key] ?? '',
      writeProperty: (key, value) async => this.properties[key] = value,
      pageTimeout: pageTimeout,
      operationTimeout: operationTimeout,
      requestInterval: Duration.zero,
      pollInterval: const Duration(milliseconds: 1),
    );
    port = _FakeBrowserPort(
      onPageFinished: session.pageFinished,
      autoFinish: autoFinish,
      staleBlankCallbacks: staleBlankCallbacks,
      supportDocuments: supportDocuments,
      supportColdDocuments: supportColdDocuments,
    );
    session.attach(port);
  }

  String host = _host;
  final Map<String, String> properties;
  late final Wenku8BrowserSession session;
  late final _FakeBrowserPort port;
}

class _FakeBrowserPort implements Wenku8BrowserPort, Wenku8DocumentContextPort {
  _FakeBrowserPort({
    required this.onPageFinished,
    required this.autoFinish,
    required this.staleBlankCallbacks,
    this.supportDocuments = false,
    this.supportColdDocuments = false,
  });

  final void Function() onPageFinished;
  final bool autoFinish;
  final bool supportDocuments;
  final bool supportColdDocuments;
  int contextPreparations = 0;
  int staleBlankCallbacks;
  final List<String> loads = [];
  final List<String> scripts = [];
  final Map<String, Map<String, Object?>> states = {};
  final Map<String, Object?> readResults = {};
  final Map<String, String> redirects = {};
  String url = 'about:blank';
  Map<String, Object?> state = _page('about:blank');
  Object? captchaResult;
  Object? loginResult = true;
  void Function()? afterLoginSubmit;
  int loginSubmissions = 0;
  int readExtractions = 0;
  int persistenceCalls = 0;
  Object? persistenceError;
  bool stallExtraction = false;
  bool stallBlank = false;
  String? searchRedirect;
  String? searchPageRedirect;
  int searchSubmissions = 0;
  final List<int> searchIntervals = [];
  final Map<String, String> nextSearchUrls = {};
  int searchReloads = 0;
  final List<String> documentReads = [];
  Map<String, Object?>? documentState;
  String? _documentTarget;

  List<String> get targetLoads =>
      loads.where((value) => value != 'about:blank').toList();

  @override
  Future<void> loadUrl(String value) async {
    loads.add(value);
    url = redirects[value] ?? value;
    if (value == 'about:blank') {
      if (stallBlank) return Completer<void>().future;
      state = _page(value);
      if (staleBlankCallbacks > 0) {
        staleBlankCallbacks--;
        Timer(const Duration(milliseconds: 12), onPageFinished);
      }
      return;
    }
    state = Map<String, Object?>.from(states[value] ?? _page(url));
    if (autoFinish) {
      Timer(const Duration(milliseconds: 2), onPageFinished);
    }
  }

  @override
  Future<String> currentUrl() async => url;

  @override
  Future<bool> prepareDocumentContext(String host, String html) async {
    if (!supportColdDocuments) return false;
    contextPreparations++;
    url = '$host/';
    state = _page(url);
    return true;
  }

  @override
  Future<void> persistSession() async {
    persistenceCalls++;
    if (persistenceError case final error?) throw error;
  }

  void finish({Map<String, Object?>? pageState}) {
    if (pageState != null) state = Map<String, Object?>.from(pageState);
    onPageFinished();
  }

  @override
  Future<dynamic> executeScript(String script) async {
    scripts.add(script);
    if (script == Wenku8BrowserSession.pageStateScript) {
      return Map<String, Object?>.from(state);
    }
    if (script.contains('litetale-document-park')) return supportDocuments;
    if (script.contains('litetale-document-context-ready')) {
      return supportColdDocuments;
    }
    if (script.contains('litetale-document-start')) {
      if (!supportDocuments) return false;
      final match = RegExp(r'\}\)\([^,]+,("[^"]+"),\d+\)').firstMatch(script)!;
      _documentTarget = jsonDecode(match[1]!) as String;
      documentReads.add(_documentTarget!);
      return true;
    }
    if (script.contains('litetale-document-state')) {
      return documentState ??
          {
            'url': _documentTarget,
            'payload':
                readResults[_documentTarget] ??
                _detailPayload(_documentTarget!, '101'),
          };
    }
    if (script.contains('litetale-search-submit')) {
      searchSubmissions++;
      if (searchRedirect == null) return false;
      await loadUrl(searchRedirect!);
      return true;
    }
    if (script.contains('litetale-search-page')) {
      if (searchPageRedirect == null) return false;
      await loadUrl(searchPageRedirect!);
      return true;
    }
    if (script.contains('litetale-search-next-url')) {
      return nextSearchUrls[url] ?? '';
    }
    if (script.contains('litetale-search-interval')) {
      return searchIntervals.isEmpty ? 0 : searchIntervals.removeAt(0);
    }
    if (script.contains('location.reload()')) {
      searchReloads++;
      await loadUrl(url);
      return true;
    }
    if (script.contains('location.assign(')) {
      final value =
          RegExp(r'location\.assign\((".*?")\)').firstMatch(script)![1]!;
      await loadUrl(jsonDecode(value) as String);
      return true;
    }
    if (script.contains('HTMLFormElement.prototype.submit.call(form)')) {
      loginSubmissions++;
      afterLoginSubmit?.call();
      return loginResult;
    }
    if (script.contains("canvas.toDataURL('image/png')")) {
      return captchaResult ??
          <String, Object?>{
            'url': url,
            'ready': true,
            'data': 'data:image/png;base64,${base64Encode(_png)}',
          };
    }
    if (script.contains("url.searchParams.set('random'")) return true;
    if (script.contains('expectedKind')) {
      if (stallExtraction) return Completer<dynamic>().future;
      readExtractions++;
      return readResults[url] ?? _detailPayload(url, '101');
    }
    throw StateError('Unexpected fake browser script');
  }
}

void main() {
  test('shelf list and first group share one browser response', () async {
    final h = _Harness(supportDocuments: true, supportColdDocuments: true);
    const target = '$_host/modules/article/bookcase.php?classid=0';
    h.port.readResults[target] = {
      'url': target,
      'caseId': '0',
      'groups': [
        {'id': '0', 'title': '全部'},
        {'id': '1', 'title': '一'},
      ],
      'tip': '',
      'items': [
        {
          'aid': '101',
          'bid': '20',
          'title': 'fixture',
          'author': '',
          'cid': '19',
          'chapterName': '',
        },
      ],
    };
    expect((await h.session.bookcaseList()).length, 2);
    expect((await h.session.bookInCase('0')).items.single.aid, '101');
    expect(h.port.documentReads, [target]);
    expect(h.port.targetLoads, isEmpty);
    await h.session
        .bookcaseList(); // An unconsumed response belongs to account A.
    h.session.invalidateBookshelfSnapshot();
    final changed = Map<String, Object?>.from(
      h.port.readResults[target]! as Map,
    );
    changed['items'] = [
      {
        'aid': '102',
        'bid': '21',
        'title': 'account B fixture',
        'author': '',
        'cid': '20',
        'chapterName': '',
      },
    ];
    h.port.readResults[target] = changed;
    expect((await h.session.bookInCase('0')).items.single.aid, '102');
    expect(h.port.documentReads, [target, target, target]);
    h.session.dispose();
  });
  test(
    'native 429 preserves login and never invokes the browser fallback',
    () async {
      final h = _Harness(
        properties: {'litetale.wenku8.browser_login_host': _host},
      );
      var calls = 0, browser = 0;
      Future<String> read() => h.session.nativeOrBrowser(
        () async {
          calls++;
          throw Exception('HTTP 429 retry_after_seconds=60 Cloudflare');
        },
        () async {
          browser++;
          return 'unexpected';
        },
      );
      await expectLater(read(), throwsA(isA<Wenku8RateLimited>()));
      await expectLater(read(), throwsA(isA<Wenku8RateLimited>()));
      expect(calls, 1);
      expect(browser, 0);
      expect(await h.session.hasSavedLogin(), isTrue);
      h.session.dispose();
    },
  );
  test(
    'inert document 429 stops before navigation and rejects queued/preload reads',
    () async {
      final h = _Harness(supportDocuments: true, supportColdDocuments: true);
      h.port.documentState = {'status': 429, 'retryAfterSeconds': 60};
      final target = Uri.parse('$_host/book/101.htm');
      await expectLater(
        h.session.read('detail', target, aid: '101'),
        throwsA(isA<Wenku8RateLimited>()),
      );
      await expectLater(
        h.session.read('detail', target, aid: '101'),
        throwsA(isA<Wenku8RateLimited>()),
      );
      expect(h.port.documentReads, [target.toString()]);
      expect(h.port.targetLoads, isEmpty);
      expect(
        await h.session.prefetchChapter(
          Uri.parse('$_host/novel/0/101/19.htm'),
          aid: '101',
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(h.port.documentReads.length, 1);
      h.session.dispose();
    },
  );
  test(
    'an expired queued request never navigates after the blocked owner',
    () async {
      final h = _Harness(operationTimeout: const Duration(milliseconds: 50));
      h.port.stallExtraction = true;
      final first = expectLater(
        h.session.read('detail', Uri.parse('$_host/book/101.htm'), aid: '101'),
        throwsA(isA<Wenku8BrowserException>()),
      );
      final second = expectLater(
        h.session.read('detail', Uri.parse('$_host/book/102.htm'), aid: '102'),
        throwsA(isA<Wenku8BrowserException>()),
      );
      await Future.wait([first, second]);
      await Future<void>.delayed(const Duration(milliseconds: 65));
      expect(h.port.targetLoads, ['$_host/book/101.htm']);
      h.session.dispose();
    },
  );
  group('Wenku8BrowserSession', () {
    test(
      'visible session adoption synchronously changes reading cache identity',
      () async {
        final h = _Harness();
        final before = h.session.readingSessionRevision;
        await h.session.adoptVisiblePage(_host, {
          ..._page('$_host/'),
          'authenticated': true,
          'home': true,
        });
        expect(h.session.readingSessionRevision, greaterThan(before));
        final after = h.session.readingSessionRevision;
        await expectLater(
          h.session.adoptVisiblePage(_host, {
            ..._page('$_host/'),
            'challenge': true,
          }),
          throwsA(isA<Wenku8SiteVerificationRequired>()),
        );
        expect(h.session.readingSessionRevision, after);
        h.session.dispose();
      },
    );
    test('prefetch never starts a renderer or loads a whole page', () async {
      final h = _Harness(supportDocuments: true, supportColdDocuments: true);
      final value = await h.session.prefetchChapter(
        Uri.parse('$_host/novel/0/101/19.htm'),
        aid: '101',
        isCurrent: () => true,
      );
      expect(value, null);
      expect(h.port.loads, isEmpty);
      expect(h.port.documentReads, isEmpty);
      expect(h.port.contextPreparations, 0);
      h.session.dispose();
    });

    test(
      'renderer detached after prefetch admission is never restarted by background work',
      () async {
        final h = _Harness(supportDocuments: true, supportColdDocuments: true);
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse('$_host/book/101.htm'),
          aid: '101',
        );
        final background = h.session.prefetchChapter(
          Uri.parse('$_host/novel/0/101/19.htm'),
          aid: '101',
          isCurrent: () => true,
        );
        h.session.detach(h.port);
        expect(await background, null);
        expect(h.session.requested, false);
        expect(h.port.documentReads, ['$_host/book/101.htm']);
        h.session.dispose();
      },
    );

    test(
      'foreground read interrupts a pending prefetch without navigation fallback',
      () async {
        final h = _Harness(supportDocuments: true, supportColdDocuments: true);
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse('$_host/book/101.htm'),
          aid: '101',
        );
        h.port.documentState = {'pending': true};
        final background = h.session.prefetchChapter(
          Uri.parse('$_host/novel/0/101/19.htm'),
          aid: '101',
          isCurrent: () => true,
        );
        for (var i = 0; i < 100 && h.port.documentReads.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(h.port.documentReads.length, 2);
        const next = '$_host/book/202.htm';
        h.port.readResults[next] = _detailPayload(next, '202');
        h.port.documentState = null;
        final foreground = h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(next),
          aid: '202',
        );
        expect(await background, null);
        expect((await foreground).title, 'Fixture 202');
        expect(h.port.loads, isEmpty);
        expect(h.port.documentReads, [
          '$_host/book/101.htm',
          '$_host/novel/0/101/19.htm',
          next,
        ]);
        h.session.dispose();
      },
    );

    test(
      'prefetch uses strict chapter parsing, never returns a challenge as text',
      () async {
        final h = _Harness(supportDocuments: true, supportColdDocuments: true);
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse('$_host/book/101.htm'),
          aid: '101',
        );
        const url = '$_host/novel/0/101/19.htm';
        h.port.readResults[url] = {
          'url': url,
          'kind': 'chapter',
          'aid': '101',
          'challenge': false,
          'data': {'content': '真实正文'},
        };
        expect(
          await h.session.prefetchChapter(
            Uri.parse(url),
            aid: '101',
            isCurrent: () => true,
          ),
          '真实正文',
        );
        h.port.readResults[url] = {
          'url': url,
          'kind': 'chapter',
          'aid': '101',
          'challenge': true,
          'data': {'content': 'challenge page'},
        };
        expect(
          await h.session.prefetchChapter(
            Uri.parse(url),
            aid: '101',
            isCurrent: () => true,
          ),
          null,
        );
        expect(h.port.loads, isEmpty);
        expect(h.port.loginSubmissions, 0);
        h.session.dispose();
      },
    );

    test(
      'leaving reader cancels speculative polling and another prefetch is admitted',
      () async {
        final h = _Harness(supportDocuments: true, supportColdDocuments: true);
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse('$_host/book/101.htm'),
          aid: '101',
        );
        var current = true;
        h.port.documentState = {'pending': true};
        final background = h.session.prefetchChapter(
          Uri.parse('$_host/novel/0/101/19.htm'),
          aid: '101',
          isCurrent: () => current,
        );
        for (var i = 0; i < 100 && h.port.documentReads.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        current = false;
        expect(await background, null);
        h.port.documentState = null;
        const url = '$_host/novel/0/101/20.htm';
        h.port.readResults[url] = {
          'url': url,
          'kind': 'chapter',
          'aid': '101',
          'challenge': false,
          'data': {'content': '另一个正文'},
        };
        expect(
          await h.session.prefetchChapter(
            Uri.parse(url),
            aid: '101',
            isCurrent: () => true,
          ),
          '另一个正文',
        );
        h.session.dispose();
      },
    );
    Map<String, Object?> listing(String url, int page) => {
      'url': url,
      'kind': 'list',
      'aid': '',
      'challenge': false,
      'data': {
        'currentPage': page,
        'maxPage': 2,
        'records': [
          {
            'aid': '$page',
            'title': 'Result $page',
            'image': 'https://img.wenku8.com/$page.jpg',
            'detailUrl': '$_host/book/$page.htm',
          },
        ],
      },
    };

    test(
      'complete search results need not wait for trailing page scripts',
      () async {
        final h = _Harness(autoFinish: false);
        const url =
            '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
        h.port.searchRedirect = url;
        h.port.states[url] = {
          ..._page(url, ready: false),
          'domReady': false,
          'searchReady': true,
        };
        h.port.readResults[url] = listing(url, 1);
        final result = await h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(url),
          searchKey: 'Re',
        );
        expect(result.records.single.title, 'Result 1');
        expect(h.port.searchSubmissions, 1);
        h.session.dispose();
      },
    );

    test(
      'cold supported engine reads data without first rendering the site',
      () async {
        final h = _Harness(supportDocuments: true, supportColdDocuments: true);
        const url = '$_host/book/101.htm';
        final info = await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        expect(h.port.contextPreparations, 1);
        expect(h.port.documentReads, [url]);
        expect(h.port.targetLoads, isEmpty);
        h.session.dispose();
      },
    );

    test(
      'first cold fetch denied by the site still uses normal navigation',
      () async {
        final h = _Harness(supportDocuments: true, supportColdDocuments: true);
        const url = '$_host/book/101.htm';
        h.port.documentState = {'status': 403};
        final info = await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        expect(h.port.contextPreparations, 1);
        expect(h.port.documentReads, [url]);
        expect(h.port.targetLoads, [url]);
        h.session.dispose();
      },
    );

    test(
      'warm reads use inert documents without loading book assets again',
      () async {
        final h = _Harness(supportDocuments: true);
        const first = '$_host/book/101.htm', second = '$_host/book/102.htm';
        h.port.readResults[second] = _detailPayload(second, '102');
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(first),
          aid: '101',
        );
        final info = await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(second),
          aid: '102',
        );
        expect(info.title, 'Fixture 102');
        expect(h.port.targetLoads, [first]);
        expect(h.port.documentReads, [second]);
        expect(h.port.url, first); // payload validation uses the fetched URL.
        h.session.dispose();
      },
    );

    test('retained real search form avoids another home navigation', () async {
      final h = _Harness(supportDocuments: true);
      const first = '$_host/book/101.htm';
      const search =
          '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
      h.port.searchRedirect = search;
      h.port.readResults[search] = listing(search, 1);
      await h.session.read<models.NovelInfo>(
        'detail',
        Uri.parse(first),
        aid: '101',
      );
      await h.session.read<PageStatsNovelCover>(
        'list',
        Uri.parse(search),
        searchKey: 'Re',
      );
      expect(h.port.targetLoads, [first, search]);
      expect(h.port.searchSubmissions, 1);
      expect(h.port.documentReads, isEmpty); // Search still uses the site form.
      h.session.dispose();
    });

    test(
      'denied document read falls back and invalidates a real login redirect',
      () async {
        final h = _Harness(
          supportDocuments: true,
          properties: {'litetale.wenku8.browser_login_host': _host},
        );
        const url = '$_host/book/101.htm';
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        h.port.documentState = {'status': 403};
        h.port.redirects[url] = '$_host/login.php';
        var invalidated = false;
        final subscription = h.session.sessionInvalidations.listen(
          (_) => invalidated = true,
        );
        await expectLater(
          h.session.read<models.NovelInfo>(
            'detail',
            Uri.parse(url),
            aid: '101',
          ),
          throwsA(isA<Wenku8BrowserException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(invalidated, isTrue);
        expect(h.properties['litetale.wenku8.browser_login_host'], isEmpty);
        expect(h.port.targetLoads, [url, url]);
        expect(h.port.url, 'about:blank');
        await subscription.cancel();
        h.session.dispose();
      },
    );

    test(
      'server failure does not issue a second request or poison the queue',
      () async {
        final h = _Harness(supportDocuments: true);
        const url = '$_host/book/101.htm';
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        h.port.documentState = {'status': 502};
        await expectLater(
          h.session.read<models.NovelInfo>(
            'detail',
            Uri.parse(url),
            aid: '101',
          ),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(h.port.targetLoads, [url]);
        expect(h.port.url, 'about:blank');
        final info = await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        expect(h.port.targetLoads, [url, url]);
        h.session.dispose();
      },
    );

    test(
      'malformed fast payload retries once using normal DOM extraction',
      () async {
        final h = _Harness(supportDocuments: true);
        const url = '$_host/book/101.htm';
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        h.port.documentState = {
          'url': url,
          'payload': {'data': 'changed'},
        };
        final info = await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        expect(h.port.targetLoads, [url, url]);
        expect(h.port.documentReads, [url]);
        h.session.dispose();
      },
    );

    test('a changed host never reuses the previous origin document', () async {
      final h = _Harness(supportDocuments: true);
      const first = '$_host/book/101.htm',
          second = 'https://wenku8.net/book/101.htm';
      await h.session.read<models.NovelInfo>(
        'detail',
        Uri.parse(first),
        aid: '101',
      );
      h.host = 'https://wenku8.net';
      h.port.readResults[second] = _detailPayload(second, '101');
      await h.session.read<models.NovelInfo>(
        'detail',
        Uri.parse(second),
        aid: '101',
      );
      expect(h.port.documentReads, isEmpty);
      expect(h.port.targetLoads, [first, second]);
      h.session.dispose();
    });

    test(
      'a stalled fetch finishes finitely and the next read can navigate',
      () async {
        final h = _Harness(
          supportDocuments: true,
          pageTimeout: const Duration(milliseconds: 40),
        );
        const url = '$_host/book/101.htm';
        await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        h.port.documentState = {'pending': true};
        await expectLater(
          h.session.read<models.NovelInfo>(
            'detail',
            Uri.parse(url),
            aid: '101',
          ),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(h.port.url, 'about:blank');
        final info = await h.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        h.session.dispose();
      },
    );

    test(
      'pagination reuses the real link without resubmitting its form',
      () async {
        final h = _Harness();
        const first =
            '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
        const second = '$first&page=2';
        h.port.searchRedirect = first;
        h.port.nextSearchUrls[first] = second;
        h.port.readResults[first] = listing(first, 1);
        h.port.readResults[second] = listing(second, 2);
        await h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(first),
          searchKey: 'Re',
        );
        final result = await h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(second),
          searchKey: 'Re',
        );
        expect(result.currentPage, 2);
        expect(result.records.single.aid, '2');
        expect(h.port.searchSubmissions, 1);
        expect(h.port.url, 'about:blank');
        h.session.dispose();
      },
    );

    test(
      'an explicit interval retries the search GET once, never its POST',
      () async {
        final h = _Harness();
        const first =
            '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
        h.port
          ..searchRedirect = first
          ..searchIntervals.addAll([1, 0]);
        h.port.readResults[first] = listing(first, 1);
        final started = DateTime.now();
        await h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(first),
          searchKey: 'Re',
        );
        expect(
          DateTime.now().difference(started),
          greaterThanOrEqualTo(const Duration(seconds: 1)),
        );
        expect(h.port.searchSubmissions, 1);
        expect(h.port.searchReloads, 1);
        expect(h.port.url, 'about:blank');
        h.session.dispose();
      },
    );

    test('cached pagination cannot replace a different search query', () async {
      final h = _Harness();
      const first =
          '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
      const other =
          '$_host/modules/article/search.php?searchtype=author&searchkey=Z';
      h.port.searchRedirect = first;
      h.port.nextSearchUrls[first] = '$first&page=2';
      h.port.readResults[first] = listing(first, 1);
      h.port.readResults['$other&page=2'] = listing('$other&page=2', 2);
      await h.session.read<PageStatsNovelCover>(
        'list',
        Uri.parse(first),
        searchKey: 'Re',
      );
      h.port
        ..searchRedirect = other
        ..searchPageRedirect = '$other&page=2';
      final result = await h.session.read<PageStatsNovelCover>(
        'list',
        Uri.parse('$other&page=2'),
        searchKey: 'Z',
      );
      expect(result.currentPage, 2);
      expect(h.port.searchSubmissions, 2);
      expect(h.port.targetLoads, isNot(contains('$first&page=2')));
      h.session.dispose();
    });

    test('a repeated interval notice stops after one GET retry', () async {
      final h = _Harness();
      const first =
          '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
      h.port
        ..searchRedirect = first
        ..searchIntervals.addAll([1, 1]);
      await expectLater(
        h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(first),
          searchKey: 'Re',
        ),
        throwsA(isA<Wenku8BrowserException>()),
      );
      expect(h.port.searchSubmissions, 1);
      expect(h.port.searchReloads, 1);
      expect(h.port.url, 'about:blank');
      h.session.dispose();
    });

    test('reads the form redirect with an implicit first results page', () async {
      final h = _Harness();
      const first =
          '$_host/modules/article/search.php?searchtype=articlename&searchkey=Re';
      h.port.searchRedirect = first;
      h.port.readResults[first] = {
        'url': first,
        'kind': 'list',
        'aid': '',
        'challenge': false,
        'data': {
          'currentPage': 1,
          'maxPage': 2,
          'records': [
            {
              'aid': '101',
              'title': '志乃与恋 Future',
              'image': 'https://img.wenku8.com/101.jpg',
              'detailUrl': '$_host/book/101.htm',
            },
          ],
        },
      };
      final result = await h.session.read<PageStatsNovelCover>(
        'list',
        Uri.parse(first),
        searchKey: 'Re',
      );
      expect(result.records.single.title, '志乃与恋 Future');
      expect(h.port.searchSubmissions, 1);
      expect(h.port.loginSubmissions, 0);
      expect(h.port.url, 'about:blank');
      h.session.dispose();
    });

    test(
      'Chinese search uses the site form and follows its real second page',
      () async {
        final h = _Harness();
        const first =
            '$_host/modules/article/search.php?searchtype=articlename&searchkey=%C4%A7%B7%A8';
        const second =
            '$_host/modules/article/search.php?searchtype=articlename&searchkey=%C4%A7%B7%A8&page=2';
        h.port
          ..searchRedirect = first
          ..searchPageRedirect = second;
        h.port.readResults[second] = {
          'url': second,
          'kind': 'list',
          'aid': '',
          'challenge': false,
          'data': {
            'currentPage': 2,
            'maxPage': 2,
            'records': [
              {
                'aid': '101',
                'title': '魔法',
                'image': 'https://img.wenku8.com/101.jpg',
                'detailUrl': '$_host/book/101.htm',
              },
            ],
          },
        };
        final result = await h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse('$second&charset=gbk'),
          searchKey: '魔法',
        );
        expect(result.currentPage, 2);
        expect(h.port.searchSubmissions, 1);
        expect(h.port.loginSubmissions, 0);
        expect(h.port.targetLoads, ['$_host/', first, second]);
        expect(h.port.url, 'about:blank');
        h.session.dispose();
      },
    );

    test('search form changes fail finitely without a login POST', () async {
      final h = _Harness();
      await expectLater(
        h.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(
            '$_host/modules/article/search.php?searchtype=author&searchkey=Re&page=1',
          ),
          searchKey: 'Re',
        ),
        throwsA(isA<Wenku8BrowserException>()),
      );
      expect(h.port.searchSubmissions, 1);
      expect(h.port.loginSubmissions, 0);
      expect(h.port.url, 'about:blank');
      h.session.dispose();
    });

    test(
      'reads interactive DOM without waiting for stalled images or load event',
      () async {
        final harness = _Harness(autoFinish: false);
        const url = '$_host/book/101.htm';
        harness.port.states[url] = {
          ..._page(url, ready: false),
          'domReady': true,
        };
        final info = await harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(url),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        expect(harness.port.url, 'about:blank');
        harness.session.dispose();
      },
    );

    test(
      'stalled script releases queue and replaces controller before another read',
      () async {
        final harness = _Harness(pageTimeout: const Duration(milliseconds: 40));
        harness.port.stallExtraction = true;
        await expectLater(
          harness.session.read<models.NovelInfo>(
            'detail',
            Uri.parse('$_host/book/101.htm'),
            aid: '101',
          ),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(harness.session.rendererGeneration, 1);
        final replacement = _FakeBrowserPort(
          onPageFinished: harness.session.pageFinished,
          autoFinish: true,
          staleBlankCallbacks: 0,
        );
        harness.session.attach(replacement);
        final info = await harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse('$_host/book/101.htm'),
          aid: '101',
        );
        expect(info.title, 'Fixture 101');
        expect(harness.port.targetLoads.length, 1);
        harness.session.dispose();
      },
    );

    test('stalled idle command cannot keep loading forever', () async {
      final harness = _Harness(pageTimeout: const Duration(milliseconds: 30));
      harness.port.stallBlank = true;
      await expectLater(
        harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse('$_host/book/101.htm'),
          aid: '101',
        ),
        throwsA(isA<Wenku8BrowserException>()),
      );
      expect(harness.session.rendererGeneration, 1);
      harness.session.dispose();
    });

    test(
      'stalled native read falls back without waiting indefinitely',
      () async {
        final harness = _Harness(pageTimeout: const Duration(milliseconds: 30));
        final value = await harness.session.nativeOrBrowser(
          () => Completer<String>().future,
          () async => 'browser',
        );
        expect(value, 'browser');
        harness.session.dispose();
      },
    );
    test(
      'rejects an exact-search redirect with unknown or duplicate query parameters',
      () async {
        for (final extra in ['&searchkey=other', '&other=1', '&aid=101']) {
          final harness = _Harness();
          final searchUrl =
              '$_host/modules/article/search.php?searchtype=articlename&searchkey=fixture&page=1&charset=gbk$extra';
          harness.port.redirects[searchUrl] = '$_host/book/101.htm';
          await expectLater(
            harness.session.read<PageStatsNovelCover>(
              'list',
              Uri.parse(searchUrl),
            ),
            throwsFormatException,
          );
          harness.session.dispose();
        }
      },
    );
    test(
      'accepts a single exact-search redirect only as a validated detail',
      () async {
        final harness = _Harness();
        const searchUrl =
            '$_host/modules/article/search.php?searchtype=articlename&searchkey=fixture&page=1&charset=gbk';
        const detailUrl = '$_host/book/101.htm';
        harness.port.redirects[searchUrl] = detailUrl;
        harness.port.readResults[detailUrl] = _detailPayload(detailUrl, '101');
        final result = await harness.session.read<PageStatsNovelCover>(
          'list',
          Uri.parse(searchUrl),
        );
        expect(result.records.single.aid, '101');
        expect(result.records.single.detailUrl, detailUrl);
        expect(result.currentPage, 1);
        expect(harness.port.url, 'about:blank');
        harness.session.dispose();
      },
    );

    test(
      'does not accept a ranking redirect as an exact-search result',
      () async {
        final harness = _Harness();
        const rankUrl =
            '$_host/modules/article/toplist.php?sort=lastupdate&page=1&charset=gbk';
        harness.port.redirects[rankUrl] = '$_host/book/101.htm';
        await expectLater(
          harness.session.read<PageStatsNovelCover>('list', Uri.parse(rankUrl)),
          throwsFormatException,
        );
        harness.session.dispose();
      },
    );

    test(
      'confirmed login redirect clears its saved marker and emits one invalidation',
      () async {
        final harness = _Harness(
          properties: {'litetale.wenku8.browser_login_host': _host},
        );
        var invalidations = 0;
        final subscription = harness.session.sessionInvalidations.listen(
          (_) => invalidations++,
        );
        harness.port.redirects['$_host/'] = '$_host/login.php';
        await expectLater(
          harness.session.home(),
          throwsA(isA<Wenku8BrowserException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(await harness.session.hasSavedLogin(), false);
        expect(invalidations, 1);
        await subscription.cancel();
        harness.session.dispose();
      },
    );

    test(
      'a login redirect replaces legacy native auth, while a challenge keeps the session',
      () async {
        final harness = _Harness();
        var invalidations = 0;
        final subscription = harness.session.sessionInvalidations.listen(
          (_) => invalidations++,
        );
        harness.port.redirects['$_host/'] = '$_host/login.php';
        await expectLater(
          harness.session.home(),
          throwsA(isA<Wenku8BrowserException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(await harness.session.enabled(), true);
        expect(invalidations, 1);
        harness.port.redirects.clear();
        harness.properties['litetale.wenku8.browser_login_host'] = _host;
        harness.port.states['$_host/'] = {
          ..._page('$_host/'),
          'challenge': true,
        };
        await expectLater(
          harness.session.home(),
          throwsA(isA<Wenku8SiteVerificationRequired>()),
        );
        expect(await harness.session.hasSavedLogin(), true);
        expect(invalidations, 1);
        await subscription.cancel();
        harness.session.dispose();
      },
    );

    test(
      'does not persist authenticated DOM until its document is ready',
      () async {
        final harness = _Harness(pageTimeout: const Duration(milliseconds: 60));
        const loginUrl = '$_host/login.php';
        harness.port.states[loginUrl] = {..._page(loginUrl), 'loginForm': true};
        await harness.session.captcha();
        harness.port.afterLoginSubmit =
            () => harness.port.finish(
              pageState: {
                ..._page('$_host/', ready: false),
                'authenticated': true,
              },
            );
        await expectLater(
          harness.session.login('fixture-user', 'fixture-password', '0000'),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(harness.port.loginSubmissions, 1);
        expect(harness.port.persistenceCalls, 0);
        expect(await harness.session.hasSavedLogin(), false);
        harness.session.dispose();
      },
    );
    test(
      'does not save a login flag when platform persistence fails',
      () async {
        final harness = _Harness();
        const loginUrl = '$_host/login.php';
        harness.port.states[loginUrl] = {..._page(loginUrl), 'loginForm': true};
        await harness.session.captcha();
        harness.port.persistenceError = StateError('fixture disk error');
        harness.port.afterLoginSubmit = () {
          harness.port.finish(
            pageState: {
              ..._page('$_host/'),
              'authenticated': true,
              'home': true,
            },
          );
        };
        await expectLater(
          harness.session.login('fixture-user', 'fixture-password', '0000'),
          throwsStateError,
        );
        expect(harness.port.loginSubmissions, 1);
        expect(harness.port.persistenceCalls, 1);
        expect(await harness.session.hasSavedLogin(), false);
      },
    );

    test(
      'visible session is validated and persisted before saving login',
      () async {
        final harness = _Harness();
        var persistenceCalls = 0;
        Future<void> persist() async {
          expect(await harness.session.hasSavedLogin(), false);
          persistenceCalls++;
        }

        await expectLater(
          harness.session.adoptVisiblePage(_host, {
            ..._page('https://unrelated.invalid/'),
            'authenticated': true,
          }, persistSession: persist),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(persistenceCalls, 0);
        expect(
          await harness.session.adoptVisiblePage(_host, {
            ..._page('$_host/'),
            'authenticated': true,
          }, persistSession: persist),
          true,
        );
        expect(persistenceCalls, 1);
        expect(await harness.session.hasSavedLogin(), true);
      },
    );

    test(
      'serializes concurrent reads and opens the next request after completion',
      () async {
        final harness = _Harness(autoFinish: false);
        const firstUrl = '$_host/book/101.htm';
        const secondUrl = '$_host/book/202.htm';
        harness.port
          ..states[firstUrl] = _page(firstUrl, ready: false)
          ..states[secondUrl] = _page(secondUrl, ready: false)
          ..readResults[firstUrl] = _detailPayload(firstUrl, '101')
          ..readResults[secondUrl] = _detailPayload(secondUrl, '202');

        final first = harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(firstUrl),
          aid: '101',
        );
        final second = harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(secondUrl),
          aid: '202',
        );
        await Future<void>.delayed(const Duration(milliseconds: 8));

        expect(harness.port.targetLoads, [firstUrl]);
        harness.port.finish(pageState: _page(firstUrl));
        expect((await first).title, 'Fixture 101');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        expect(harness.port.targetLoads, [firstUrl, secondUrl]);

        harness.port.finish(pageState: _page(secondUrl));
        expect((await second).title, 'Fixture 202');
        expect(harness.port.readExtractions, 2);
      },
    );

    test('a failed read does not poison the serialized queue', () async {
      final harness = _Harness();
      const firstUrl = '$_host/book/101.htm';
      const secondUrl = '$_host/book/202.htm';
      harness.port.states[firstUrl] = {
        ..._page('https://evil.example/book/101.htm'),
      };
      harness.port.readResults[secondUrl] = _detailPayload(secondUrl, '202');

      final failed = harness.session.read<models.NovelInfo>(
        'detail',
        Uri.parse(firstUrl),
        aid: '101',
      );
      final next = harness.session.read<models.NovelInfo>(
        'detail',
        Uri.parse(secondUrl),
        aid: '202',
      );

      await expectLater(failed, throwsA(isA<Wenku8BrowserException>()));
      expect((await next).title, 'Fixture 202');
      expect(harness.port.targetLoads, [firstUrl, secondUrl]);
    });

    test('a late about:blank callback cannot finish a new document', () async {
      final harness = _Harness(
        autoFinish: false,
        staleBlankCallbacks: 1,
        pageTimeout: const Duration(milliseconds: 400),
      );
      const url = '$_host/book/101.htm';
      harness.port
        ..states[url] = _page(url, ready: false)
        ..readResults[url] = _detailPayload(url, '101');

      var completed = false;
      final read = harness.session
          .read<models.NovelInfo>('detail', Uri.parse(url), aid: '101')
          .then((value) {
            completed = true;
            return value;
          });
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(completed, isFalse);
      expect(harness.port.readExtractions, 0);
      harness.port.finish(pageState: _page(url));
      expect((await read).title, 'Fixture 101');
    });

    test(
      'same-origin checks reject lookalike hosts, insecure URLs, credentials, and ports',
      () {
        expect(
          Wenku8BrowserSession.sameOrigin('$_host/book/1.htm', _host),
          isTrue,
        );
        expect(
          Wenku8BrowserSession.sameOrigin(
            'https://www.wenku8.net.evil.test/',
            _host,
          ),
          isFalse,
        );
        expect(
          Wenku8BrowserSession.sameOrigin('http://www.wenku8.net/', _host),
          isFalse,
        );
        expect(
          Wenku8BrowserSession.sameOrigin(
            'https://user@www.wenku8.net/',
            _host,
          ),
          isFalse,
        );
        expect(
          Wenku8BrowserSession.sameOrigin('https://www.wenku8.net:444/', _host),
          isFalse,
        );
      },
    );

    test(
      'read refuses a different host before loading it and navigation policy remains bound',
      () async {
        final harness = _Harness();
        const external = 'https://wenku8.net.evil.test/book/101.htm';
        await expectLater(
          harness.session.read<models.NovelInfo>(
            'detail',
            Uri.parse(external),
            aid: '101',
          ),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(harness.port.targetLoads, isEmpty);

        const local = '$_host/book/101.htm';
        harness.port.readResults[local] = _detailPayload(local, '101');
        await harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(local),
          aid: '101',
        );
        expect(harness.session.allowsNavigation('about:blank'), isTrue);
        expect(harness.session.allowsNavigation('$_host/login.php'), isTrue);
        expect(
          harness.session.allowsNavigation('https://wenku8.net/'),
          isFalse,
        );
      },
    );

    test(
      'browser mode and saved login are bound to the configured host',
      () async {
        final harness = _Harness(
          properties: {
            'litetale.wenku8.browser_host': _host,
            'litetale.wenku8.browser_login_host': _host,
          },
        );
        expect(await harness.session.enabled(), isTrue);
        expect(await harness.session.hasSavedLogin(), isTrue);

        harness.host = 'https://wenku8.net';
        expect(await harness.session.enabled(), isFalse);
        expect(await harness.session.hasSavedLogin(), isFalse);
        await expectLater(
          harness.session.enable(_host),
          throwsA(isA<Wenku8BrowserException>()),
        );
        await harness.session.enable(harness.host);
        expect(
          harness.properties['litetale.wenku8.browser_host'],
          harness.host,
        );
      },
    );

    test(
      'captcha can be submitted in the same document, but failed login consumes it once',
      () async {
        final harness = _Harness();
        final loginUrl = '$_host/login.php';
        harness.port.states[loginUrl] = {..._page(loginUrl), 'loginForm': true};
        expect(await harness.session.captcha(), _png);
        expect(await harness.session.enabled(), isTrue);

        harness.port.afterLoginSubmit = () {
          harness.port.finish(
            pageState: {
              ..._page(loginUrl),
              'ready': true,
              'loginForm': true,
              'loginError': '验证码错误',
            },
          );
        };
        await expectLater(
          harness.session.login('fixture-user', 'fixture-password', '0000'),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(harness.port.loginSubmissions, 1);
        await expectLater(
          harness.session.login('fixture-user', 'fixture-password', '0000'),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(harness.port.loginSubmissions, 1);
        expect(await harness.session.hasSavedLogin(), isFalse);
      },
    );

    test(
      'a subsequent document invalidates a previously captured captcha epoch',
      () async {
        final harness = _Harness();
        final loginUrl = '$_host/login.php';
        const detailUrl = '$_host/book/101.htm';
        harness.port.states[loginUrl] = {..._page(loginUrl), 'loginForm': true};
        harness.port.readResults[detailUrl] = _detailPayload(detailUrl, '101');

        await harness.session.captcha();
        await harness.session.read<models.NovelInfo>(
          'detail',
          Uri.parse(detailUrl),
          aid: '101',
        );
        await expectLater(
          harness.session.login('fixture-user', 'fixture-password', '0000'),
          throwsA(isA<Wenku8BrowserException>()),
        );
        expect(harness.port.loginSubmissions, 0);
      },
    );

    test(
      'a challenge document is never accepted as a successful read',
      () async {
        final harness = _Harness();
        const url = '$_host/book/101.htm';
        harness.port.states[url] = {..._page(url), 'challenge': true};

        await expectLater(
          harness.session.read<models.NovelInfo>(
            'detail',
            Uri.parse(url),
            aid: '101',
          ),
          throwsA(isA<Wenku8SiteVerificationRequired>()),
        );
        expect(harness.port.readExtractions, 0);
        expect(harness.properties['litetale.wenku8.browser_host'], isNull);
      },
    );

    test(
      'a challenge after login submission is not saved as authentication',
      () async {
        final harness = _Harness();
        final loginUrl = '$_host/login.php';
        harness.port.states[loginUrl] = {..._page(loginUrl), 'loginForm': true};
        await harness.session.captcha();
        harness.port.afterLoginSubmit = () {
          harness.port.finish(
            pageState: {..._page(loginUrl), 'challenge': true},
          );
        };

        await expectLater(
          harness.session.login('fixture-user', 'fixture-password', '0000'),
          throwsA(isA<Wenku8SiteVerificationRequired>()),
        );
        expect(harness.port.loginSubmissions, 1);
        expect(await harness.session.hasSavedLogin(), isFalse);
      },
    );

    test(
      'adoptVisiblePage accepts only same-origin ready verified page states',
      () async {
        final harness = _Harness();
        await expectLater(
          harness.session.adoptVisiblePage(_host, {
            ..._page('https://wenku8.net/'),
            'home': true,
          }),
          throwsA(isA<Wenku8BrowserException>()),
        );
        await expectLater(
          harness.session.adoptVisiblePage(_host, {
            ..._page('$_host/', ready: false),
            'home': true,
          }),
          throwsA(isA<Wenku8SiteVerificationRequired>()),
        );
        await expectLater(
          harness.session.adoptVisiblePage(_host, {
            ..._page('$_host/', ready: true),
            'challenge': true,
            'home': true,
          }),
          throwsA(isA<Wenku8SiteVerificationRequired>()),
        );
        await expectLater(
          harness.session.adoptVisiblePage(_host, _page('$_host/random.php')),
          throwsA(isA<Wenku8BrowserException>()),
        );

        final adopted = await harness.session.adoptVisiblePage(_host, {
          ..._page('$_host/'),
          'home': true,
        });
        expect(adopted, isFalse);
        expect(await harness.session.enabled(), isTrue);
        expect(await harness.session.hasSavedLogin(), isFalse);

        final authenticated = await harness.session.adoptVisiblePage(_host, {
          ..._page('$_host/account.php'),
          'authenticated': true,
        });
        expect(authenticated, isTrue);
        expect(await harness.session.hasSavedLogin(), isTrue);
      },
    );

    test(
      'nativeOrBrowser falls back only for classified network or verification errors',
      () async {
        final harness = _Harness();
        var nativeCalls = 0;
        var browserCalls = 0;

        final recovered = await harness.session.nativeOrBrowser<String>(
          () async {
            nativeCalls++;
            throw StateError('peer closed connection without TLS close_notify');
          },
          () async {
            browserCalls++;
            return 'browser fixture';
          },
        );
        expect(recovered, 'browser fixture');
        expect(nativeCalls, 1);
        expect(browserCalls, 1);

        await expectLater(
          harness.session.nativeOrBrowser<String>(
            () async {
              nativeCalls++;
              throw FormatException('bad parsed book data');
            },
            () async {
              browserCalls++;
              return 'must not run';
            },
          ),
          throwsA(isA<FormatException>()),
        );
        expect(nativeCalls, 2);
        expect(browserCalls, 1);

        harness.properties['litetale.wenku8.browser_host'] = _host;
        final enabledResult = await harness.session.nativeOrBrowser<String>(
          () async {
            nativeCalls++;
            return 'native must not run';
          },
          () async {
            browserCalls++;
            return 'configured browser';
          },
        );
        expect(enabledResult, 'configured browser');
        expect(nativeCalls, 2);
        expect(browserCalls, 2);
      },
    );
  });
}
