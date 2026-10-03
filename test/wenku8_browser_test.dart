import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_browser.dart';
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
    Duration pageTimeout = const Duration(milliseconds: 500),
  }) : properties = Map<String, String>.from(properties) {
    session = Wenku8BrowserSession(
      readHost: () async => host,
      readProperty: (key) async => this.properties[key] ?? '',
      writeProperty: (key, value) async => this.properties[key] = value,
      pageTimeout: pageTimeout,
      pollInterval: const Duration(milliseconds: 1),
    );
    port = _FakeBrowserPort(
      onPageFinished: session.pageFinished,
      autoFinish: autoFinish,
      staleBlankCallbacks: staleBlankCallbacks,
    );
    session.attach(port);
  }

  String host = _host;
  final Map<String, String> properties;
  late final Wenku8BrowserSession session;
  late final _FakeBrowserPort port;
}

class _FakeBrowserPort implements Wenku8BrowserPort {
  _FakeBrowserPort({
    required this.onPageFinished,
    required this.autoFinish,
    required this.staleBlankCallbacks,
  });

  final void Function() onPageFinished;
  final bool autoFinish;
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

  List<String> get targetLoads =>
      loads.where((value) => value != 'about:blank').toList();

  @override
  Future<void> loadUrl(String value) async {
    loads.add(value);
    url = redirects[value] ?? value;
    if (value == 'about:blank') {
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
      readExtractions++;
      return readResults[url] ?? _detailPayload(url, '101');
    }
    throw StateError('Unexpected fake browser script');
  }
}

void main() {
  group('Wenku8BrowserSession', () {
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
