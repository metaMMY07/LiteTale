import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_browser.dart';

const _host = 'https://www.wenku8.net';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
);

class _AuthHarness {
  String host = _host;
  final properties = <String, String>{};
  late final session = Wenku8BrowserSession(
    readHost: () async => host,
    readProperty: (key) async => properties[key] ?? '',
    writeProperty: (key, value) async => properties[key] = value,
    pageTimeout: const Duration(seconds: 2),
    pollInterval: const Duration(milliseconds: 1),
  );
}

class _ScriptCapture implements Wenku8BrowserPort {
  _ScriptCapture(this.session);
  final Wenku8BrowserSession session;
  String url = 'about:blank';
  String refreshScript = '', imageScript = '', loginScript = '';
  bool signedIn = false;
  int submissions = 0;
  int persistenceCalls = 0;

  @override
  Future<String> currentUrl() async => url;
  @override
  Future<void> persistSession() async {
    persistenceCalls++;
    expect(await session.hasSavedLogin(), false);
  }

  @override
  Future<void> loadUrl(String value) async {
    url = value;
    session.pageFinished();
  }

  @override
  Future<dynamic> executeScript(String script) async {
    if (script.contains('(function(host,username,password,code)')) {
      loginScript = script;
      submissions++;
      signedIn = true;
      session.pageFinished();
      return true;
    }
    if (script.contains('var result={url:location.href,ready:false}')) {
      imageScript = script;
      return jsonEncode({
        'url': url,
        'ready': true,
        'data': 'data:image/png;base64,${base64Encode(_png)}',
      });
    }
    if (script.contains("url.searchParams.set('random'")) {
      refreshScript = script;
      return true;
    }
    return jsonEncode({
      'url': url,
      'ready': true,
      'challenge': false,
      'loginForm': !signedIn,
      'authenticated': signedIn,
      'home': signedIn,
    });
  }
}

void main() {
  test(
    'a reading-mode change cannot switch the CAPTCHA login transport',
    () async {
      final h = _AuthHarness();
      final nativeImage = Completer<Uint8List>();
      final image = h.session.downloadCheckcode(() => nativeImage.future);
      await Future<void>.delayed(Duration.zero);
      await h.session.enable(_host);
      nativeImage.complete(_png);
      await image;
      var posts = 0;
      Future<void> submit() => h.session.submitLogin(
        username: 'fixture',
        password: 'fixture',
        checkcode: '0000',
        nativeRequest: () async {
          posts++;
        },
      );
      await submit();
      expect(posts, 1);
      await expectLater(submit(), throwsA(isA<Wenku8BrowserException>()));
      expect(posts, 1);
    },
  );

  test(
    'a failed refresh invalidates the previously displayed CAPTCHA',
    () async {
      final h = _AuthHarness();
      await h.session.downloadCheckcode(() async => _png);
      await expectLater(
        h.session.downloadCheckcode(
          () async => throw StateError('invalid image'),
        ),
        throwsStateError,
      );
      var posts = 0;
      await expectLater(
        h.session.submitLogin(
          username: 'fixture',
          password: 'fixture',
          checkcode: '0000',
          nativeRequest: () async {
            posts++;
          },
        ),
        throwsA(isA<Wenku8BrowserException>()),
      );
      expect(posts, 0);
    },
  );

  test('a host change blocks submitting the old host CAPTCHA', () async {
    final h = _AuthHarness();
    await h.session.downloadCheckcode(() async => _png);
    h.host = 'https://wenku8.net';
    var posts = 0;
    await expectLater(
      h.session.submitLogin(
        username: 'fixture',
        password: 'fixture',
        checkcode: '0000',
        nativeRequest: () async {
          posts++;
        },
      ),
      throwsA(isA<Wenku8BrowserException>()),
    );
    expect(posts, 0);
  });

  test(
    'a native POST failure never triggers an automatic browser POST',
    () async {
      final h = _AuthHarness();
      await h.session.downloadCheckcode(() async => _png);
      var posts = 0;
      await expectLater(
        h.session.submitLogin(
          username: 'fixture',
          password: 'fixture',
          checkcode: '0000',
          nativeRequest: () async {
            posts++;
            throw StateError('HTTP 403');
          },
        ),
        throwsStateError,
      );
      expect(posts, 1);
      expect(h.session.requested, false);
    },
  );

  test(
    'browser CAPTCHA fallback and submit use one document and one POST',
    () async {
      final h = _AuthHarness();
      final port = _ScriptCapture(h.session);
      h.session.attach(port);
      await h.session.downloadCheckcode(
        () async => throw StateError('HTTP 403'),
      );
      var nativePosts = 0;
      await h.session.submitLogin(
        username: 'fixture',
        password: 'fixture',
        checkcode: '0000',
        nativeRequest: () async {
          nativePosts++;
        },
      );
      expect(nativePosts, 0);
      expect(port.submissions, 1);
      expect(port.persistenceCalls, 1);
      expect(await h.session.hasSavedLogin(), true);
    },
  );

  final module = Platform.environment['PLAYWRIGHT_MODULE_PATH'];
  final executable = Platform.environment['PLAYWRIGHT_EXECUTABLE_PATH'];
  test(
    'real browser executes CAPTCHA canvas and same-session form scripts',
    () async {
      final h = _AuthHarness();
      final port = _ScriptCapture(h.session);
      h.session.attach(port);
      await h.session.downloadCheckcode(
        () async => throw StateError('HTTP 403'),
      );
      await h.session.submitLogin(
        username: 'qa-local',
        password: 'qa-local-only',
        checkcode: '1234',
        nativeRequest: () async => fail('unexpected native POST'),
      );
      final process = await Process.start('node', [
        'test/scripts/wenku8_auth_playwright_harness.cjs',
      ]);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.write(
        jsonEncode({
          'host': _host,
          'refreshScript': port.refreshScript,
          'imageScript': port.imageScript,
          'loginScript': port.loginScript,
          'stateScript': Wenku8BrowserSession.pageStateScript,
        }),
      );
      await process.stdin.close();
      expect(await process.exitCode, 0, reason: await stderr);
      final result = jsonDecode(await stdout) as Map;
      expect(result['canvasPng'], true);
      expect(result['sameSessionCookie'], true);
      expect(result['posts'], 2);
      expect(result['authenticated'], true);
      expect(result['optionalFormImage'], true);
      expect(result['optionalFormAuthenticated'], true);
      expect(result['persistentSelectUsed'], true);
      expect(result['foreignActionRejected'], true);
      expect(result['foreignRefreshRejected'], true);
      expect(result['challengeRejected'], true);
    },
    skip:
        module == null || executable == null
            ? 'Set Playwright module and Chromium/Edge executable for fixture scripts.'
            : null,
  );
}
