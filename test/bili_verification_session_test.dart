import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/utils/bili_site_dom.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSource = activeSource.value;
  final originalRevision = sourceRevision.value;
  setUp(() {
    activeSource.value = SourceId.bili;
    sourceRevision.value = 900;
  });
  tearDown(() {
    activeSource.value = originalSource;
    sourceRevision.value = originalRevision;
  });

  BiliBrowserSession session(_Port port, {Duration? ttl}) {
    final result = BiliBrowserSession(
      operationTimeout: const Duration(seconds: 1),
      startupGrace: Duration.zero,
      pollInterval: const Duration(milliseconds: 1),
      verificationGrace: const Duration(milliseconds: 5),
      verifiedPageTtl: ttl ?? const Duration(minutes: 2),
    );
    result.attach(port, result.rendererGeneration);
    addTearDown(result.dispose);
    return result;
  }

  BiliSiteVerificationRequired request({
    String path = '/novel/1/2.html',
    BiliProbeKind kind = BiliProbeKind.chapter,
  }) => BiliSiteVerificationRequired(
    target: Uri.parse(
      'https://${kind == BiliProbeKind.chapter ? 'www.bilinovel.net' : 'www.linovelib.com'}$path',
    ),
    kind: kind,
    revision: sourceRevision.value,
    desktopSite: kind != BiliProbeKind.chapter,
  );

  Map<String, dynamic> visible(BiliSiteVerificationRequired r) => {
    'url': '${r.target}',
    'ready': true,
    'content': '用户验证后已加载的正文',
    'next': null,
    'html': '<div id="volume-list">已验证目录</div>',
  };

  test(
    'interactive challenge keeps the requested chapter and mobile mode',
    () async {
      final p = _Port();
      try {
        await session(p).chapter('bili:1', 'bili:1:2');
        fail('expected verification');
      } on BiliSiteVerificationRequired catch (e) {
        expect(e.target.path, '/novel/1/2.html');
        expect(e.target.host, 'www.bilinovel.net');
        expect(e.kind, BiliProbeKind.chapter);
        expect(e.desktopSite, false);
        expect(e.revision, 900);
        expect('$e', isNot(contains('Cookie')));
      }
      expect(p.urls.last, 'about:blank');
    },
  );

  test('ordinary automatic verification can settle before prompting', () async {
    final p =
        _Port()
          ..responses.addAll([
            {
              'ready': false,
              'verificationRequired': true,
              'verificationPending': true,
              'error': '原站要求浏览器验证',
            },
            {'ready': true, 'content': '正常验证完成', 'next': null},
          ]);
    final result = await session(p).chapter('bili:1', 'bili:1:2');
    expect(result.content, '正常验证完成');
    expect(p.chapterProbes, 2);
  });

  test(
    'hard denial fails immediately without offering a completed challenge',
    () async {
      final p = _Port()..denied = true;
      await expectLater(
        session(p).chapter('bili:1', 'bili:1:2'),
        throwsA(isA<BiliSiteAccessDenied>()),
      );
      expect(p.chapterProbes, 1);
      expect(p.urls, [
        'https://www.bilinovel.net/novel/1/2.html',
        'about:blank',
      ]);
    },
  );
  test('a temporary partial notice waits for the full original text', () async {
    final p =
        _Port()
          ..responses.addAll([
            {'ready': true, 'content': '残缺正文', 'contentIncomplete': true},
            {'ready': true, 'content': '完整正文', 'next': null},
          ]);
    expect((await session(p).chapter('bili:1', 'bili:1:2')).content, '完整正文');
    expect(p.chapterProbes, 2);
  });
  test(
    'persistent partial text offers the ordinary site reading flow',
    () async {
      final p = _Port()..incomplete = true;
      await expectLater(
        session(p).chapter('bili:1', 'bili:1:2'),
        throwsA(
          isA<BiliSiteVerificationRequired>()
              .having((e) => e.contentRequired, 'content flow', true)
              .having((e) => e.desktopSite, 'mobile mode', false)
              .having(
                (e) => e.target.host,
                'original host',
                'www.bilinovel.net',
              ),
        ),
      );
      expect(p.chapterProbes, greaterThan(1));
    },
  );
  test(
    'a still blank previous document is ignored during mobile navigation',
    () async {
      final p =
          _Port()
            ..responses.addAll([
              {'url': 'about:blank', 'ready': true, 'content': '旧文档'},
              {'ready': true, 'content': '目标正文', 'next': null},
            ]);
      expect((await session(p).chapter('bili:1', 'bili:1:2')).content, '目标正文');
    },
  );
  for (final flag in ['accessDenied', 'contentIncomplete']) {
    test(
      '$flag cannot be adopted, even if it includes ready and text',
      () async {
        var flushes = 0;
        final r = request();
        await expectLater(
          session(_Port()).adoptVisiblePage(
            r,
            visible(r)..[flag] = true,
            persistSession: () async {
              flushes++;
            },
            isCurrent: () => true,
          ),
          throwsA(isA<BiliBrowserException>()),
        );
        expect(flushes, 0);
      },
    );
  }
  test(
    'a verified mobile snapshot cannot include a desktop next page',
    () async {
      var flushes = 0;
      final r = request();
      await expectLater(
        session(_Port()).adoptVisiblePage(
          r,
          visible(r)..['next'] = 'https://www.linovelib.com/novel/1/2_2.html',
          persistSession: () async {
            flushes++;
          },
          isCurrent: () => true,
        ),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(flushes, 0);
    },
  );

  test(
    'persistent automatic challenge becomes a bounded visible request',
    () async {
      final p = _Port()..pending = true;
      await expectLater(
        session(p).chapter('bili:1', 'bili:1:2'),
        throwsA(isA<BiliSiteVerificationRequired>()),
      );
      expect(p.chapterProbes, greaterThan(1));
      expect(p.chapterProbes, lessThan(1000));
    },
  );

  test('verified chapter is handed back without requesting it again', () async {
    final p = _Port();
    final s = session(p), r = request();
    var flushes = 0;
    expect(
      await s.adoptVisiblePage(
        r,
        visible(r),
        persistSession: () async {
          flushes++;
        },
        isCurrent: () => true,
      ),
      true,
    );
    final result = await s.chapter('bili:1', 'bili:1:2');
    expect(result.content, '用户验证后已加载的正文');
    expect(flushes, 1);
    expect(p.chapterProbes, 0);
    expect(p.urls, ['about:blank']);
  });

  test(
    'verified same-chapter subpage can complete an existing first page',
    () async {
      final p =
          _Port()
            ..responses.add({
              'ready': true,
              'content': '第一页',
              'next': 'https://www.bilinovel.net/novel/1/2_2.html',
            });
      final s = session(p), r = request(path: '/novel/1/2_2.html');
      await s.adoptVisiblePage(
        r,
        visible(r),
        persistSession: () async {},
        isCurrent: () => true,
      );
      final chapter = await s.chapter('bili:1', 'bili:1:2');
      expect(chapter.content, '第一页\n用户验证后已加载的正文');
      expect(p.chapterProbes, 1);
      expect(p.urls, isNot(contains('${r.target}')));
    },
  );

  for (final bad in [
    'https://evil.example/novel/1/2.html',
    'https://www.bilinovel.net/novel/8/2.html',
    'https://www.bilinovel.net/novel/1/3.html',
    'https://www.bilinovel.net/novel/1/2.html?unexpected=1',
  ]) {
    test('visible verification rejects mismatched page $bad', () async {
      final s = session(_Port()), r = request();
      var flushes = 0;
      await expectLater(
        s.adoptVisiblePage(
          r,
          visible(r)..['url'] = bad,
          persistSession: () async {
            flushes++;
          },
          isCurrent: () => true,
        ),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(flushes, 0);
    });
  }

  test(
    'an unfinished challenge cannot be adopted even if ready is true',
    () async {
      final s = session(_Port()), r = request();
      await expectLater(
        s.adoptVisiblePage(
          r,
          visible(r)..['verificationRequired'] = true,
          persistSession: () async => fail('must not persist'),
          isCurrent: () => true,
        ),
        throwsA(isA<BiliBrowserException>()),
      );
    },
  );

  test('next chapter is not accepted as a same-chapter continuation', () async {
    final s = session(_Port()), r = request();
    await expectLater(
      s.adoptVisiblePage(
        r,
        visible(r)..['next'] = 'https://www.bilinovel.net/novel/1/3.html',
        persistSession: () async => fail('must not persist'),
        isCurrent: () => true,
      ),
      throwsA(isA<BiliBrowserException>()),
    );
  });

  for (final change in ['cancel', 'revision', 'source']) {
    test('$change during cookie flush never adopts a late page', () async {
      final p = _Port(), gate = Completer<void>();
      final s = session(p), r = request();
      var current = true;
      final adoption = s.adoptVisiblePage(
        r,
        visible(r),
        persistSession: () => gate.future,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      if (change == 'cancel') current = false;
      if (change == 'revision') sourceRevision.value++;
      if (change == 'source') activeSource.value = SourceId.wenku8;
      gate.complete();
      expect(await adoption, false);
      await expectLater(
        s.chapter('bili:1', 'bili:1:2'),
        throwsA(isA<BiliSiteVerificationRequired>()),
      );
    });
  }

  test(
    'failed persistence does not leave a successful chapter snapshot',
    () async {
      final s = session(_Port()), r = request();
      await expectLater(
        s.adoptVisiblePage(
          r,
          visible(r),
          persistSession: () async => throw StateError('flush failed'),
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await expectLater(
        s.chapter('bili:1', 'bili:1:2'),
        throwsA(isA<BiliSiteVerificationRequired>()),
      );
    },
  );

  test('expired snapshots go back to bounded ordinary loading', () async {
    final s = session(_Port(), ttl: Duration.zero), r = request();
    await s.adoptVisiblePage(
      r,
      visible(r),
      persistSession: () async {},
      isCurrent: () => true,
    );
    await expectLater(
      s.chapter('bili:1', 'bili:1:2'),
      throwsA(isA<BiliSiteVerificationRequired>()),
    );
  });

  test(
    'desktop verified catalogue is usable at the known mobile entry only',
    () async {
      final p = _Port();
      final s = session(p),
          r = request(path: '/novel/1/catalog', kind: BiliProbeKind.document);
      await s.adoptVisiblePage(
        r,
        visible(r),
        persistSession: () async {},
        isCurrent: () => true,
      );
      expect(
        await s.document(
          Uri.parse('https://www.bilinovel.net/novel/1/catalog'),
        ),
        contains('已验证目录'),
      );
      expect(p.documentProbes, 0);
      await expectLater(
        s.document(Uri.parse('https://evil.example/novel/1/catalog')),
        throwsA(isA<BiliBrowserException>()),
      );
      expect(p.urls.every(BiliBrowserSession.allowsNavigation), true);
    },
  );

  test(
    'verified non-catalogue documents stay on their original host',
    () async {
      final p = _Port();
      final s = session(p);
      final r = request(path: '/novel/1.html', kind: BiliProbeKind.document);
      await s.adoptVisiblePage(
        r,
        visible(r),
        persistSession: () async {},
        isCurrent: () => true,
      );
      expect(await s.document(r.target), contains('已验证目录'));
      expect(p.documentProbes, 0);
      await expectLater(
        s.document(Uri.parse('https://www.bilinovel.net/novel/1.html')),
        throwsA(isA<BiliSiteVerificationRequired>()),
      );
      expect(p.documentProbes, greaterThan(0));
    },
  );

  test(
    'verified search form never supplies stale recommended books as results',
    () async {
      final p = _Port();
      final s = session(p),
          r = request(path: '/search.html', kind: BiliProbeKind.searchForm);
      await s.adoptVisiblePage(
        r,
        visible(r),
        persistSession: () async {},
        isCurrent: () => true,
      );
      expect((await s.search('seabed', 1)).records.single.title, 'SeaBed');
      expect(p.submitted, true);
    },
  );

  test(
    'visible navigation permits same-origin challenge paths, not other origins',
    () {
      final r = request();
      expect(
        BiliBrowserSession.allowsVerificationNavigation(
          'https://www.bilinovel.net/cdn-cgi/challenge-platform/step',
          r,
        ),
        true,
      );
      for (final url in [
        'http://www.linovelib.com/novel/1/2.html',
        'https://www.linovelib.com:444/novel/1/2.html',
        'https://other.example/novel/1/2.html',
        'https://user:example@www.linovelib.com/novel/1/2.html',
      ]) {
        expect(BiliBrowserSession.allowsVerificationNavigation(url, r), false);
      }
    },
  );
}

class _Port implements BiliBrowserPort {
  String current = 'about:blank';
  final urls = <String>[];
  final responses = <Map<String, dynamic>>[];
  int chapterProbes = 0, documentProbes = 0;
  bool pending = false, submitted = false;
  bool denied = false, incomplete = false;
  @override
  Future<void> loadUrl(String url) async {
    current = url;
    urls.add(url);
  }

  @override
  Future<void> setDesktopSite(bool enabled) async {}
  @override
  Future<dynamic> executeScript(String script) async {
    if (script == biliHomeReadyScript) return {'url': current, 'ready': true};
    if (script == biliSearchProbeScript) {
      return {
        'url': current,
        'ready': true,
        'books': [
          {'nid': '2844', 'title': 'SeaBed'},
        ],
        'next': null,
      };
    }
    if (script == biliChapterProbeScript || script == biliDocumentProbeScript) {
      if (script == biliChapterProbeScript) {
        chapterProbes++;
      } else {
        documentProbes++;
      }
      if (responses.isNotEmpty) {
        return {'url': current, ...responses.removeAt(0)};
      }
      if (denied) return {'url': current, 'ready': false, 'accessDenied': true};
      if (incomplete) {
        return {
          'url': current,
          'ready': true,
          'content': '残缺正文',
          'contentIncomplete': true,
        };
      }
      return {
        'url': current,
        'ready': false,
        'verificationRequired': true,
        'verificationPending': pending,
        'error': '原站要求浏览器验证',
      };
    }
    submitted = true;
    current = 'https://www.linovelib.com/novel/2844.html';
    return true;
  }
}
