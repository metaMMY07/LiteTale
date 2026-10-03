import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/src/rust/api/database.dart' as db;
import 'package:wild/src/rust/api/wenku8.dart' as native;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/utils/wenku8_home_dom.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'package:wild/utils/wenku8_read_dom.dart';

/// The browser owns its cookies. Only bounded, typed page data leaves it.
abstract interface class Wenku8BrowserPort {
  Future<void> loadUrl(String url);
  Future<String> currentUrl();
  Future<dynamic> executeScript(String script);
  Future<void> persistSession();
}

class Wenku8BrowserException implements Exception {
  const Wenku8BrowserException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Wenku8SiteVerificationRequired extends Wenku8BrowserException {
  const Wenku8SiteVerificationRequired()
    : super('文库8要求站点验证。请打开站点完成验证或登录，再返回重试。');
}

class Wenku8BrowserSession extends ChangeNotifier {
  Wenku8BrowserSession({
    Future<String> Function()? readHost,
    Future<String> Function(String)? readProperty,
    Future<void> Function(String, String)? writeProperty,
    this.pageTimeout = const Duration(seconds: 18),
    this.pollInterval = const Duration(milliseconds: 150),
  }) : _readHost = readHost ?? native.getApiHost,
       _readProperty = readProperty ?? ((key) => db.loadProperty(key: key)),
       _writeProperty =
           writeProperty ??
           ((key, value) => db.saveProperty(key: key, value: value));

  static final instance = Wenku8BrowserSession();
  static const _modeKey = 'litetale.wenku8.browser_host';
  static const _loginKey = 'litetale.wenku8.browser_login_host';
  final Future<String> Function() _readHost;
  final Future<String> Function(String) _readProperty;
  final Future<void> Function(String, String) _writeProperty;
  final Duration pageTimeout;
  final Duration pollInterval;
  Wenku8BrowserPort? _port;
  Completer<Wenku8BrowserPort>? _attachment;
  Future<void> _queue = Future.value();
  bool _requested = false;
  int _finished = 0;
  int _epoch = 0;
  int? _captchaEpoch;
  String? _captchaHost;
  Object? _navigationError;
  String? _navigationHost;
  ({String host, bool browser})? _loginTransport;
  int _captchaRequest = 0;
  final _sessionInvalidations = StreamController<void>.broadcast();

  /// Only a confirmed login redirect invalidates authentication. Ordinary
  /// transport or challenge failures do not sign the user out.
  Stream<void> get sessionInvalidations => _sessionInvalidations.stream;

  bool get requested => _requested;

  bool allowsNavigation(String url) =>
      url == 'about:blank' ||
      (_navigationHost != null && sameOrigin(url, _navigationHost!));

  Future<String> apiHost() async {
    final value = normalizeWenku8Host(await _readHost());
    return value.isEmpty ? defaultWenku8Host : value;
  }

  Future<bool> enabled() async =>
      await _readProperty(_modeKey) == await apiHost();

  Future<bool> hasSavedLogin() async =>
      await _readProperty(_loginKey) == await apiHost();

  Future<void> enable(String host) async {
    final normalized = normalizeWenku8Host(host);
    if (normalized.isEmpty || normalized != await apiHost()) {
      throw const Wenku8BrowserException('文库8地址已更改，请在当前站点重新验证。');
    }
    await _writeProperty(_modeKey, normalized);
  }

  @override
  void dispose() {
    unawaited(_sessionInvalidations.close());
    super.dispose();
  }

  void attach(Wenku8BrowserPort port) {
    _port = port;
    final waiting = _attachment;
    if (waiting != null && !waiting.isCompleted) waiting.complete(port);
  }

  void detach(Wenku8BrowserPort port) {
    if (identical(port, _port)) {
      _port = null;
      _attachment = null;
      _captchaEpoch = null;
      _epoch++;
    }
  }

  void pageFinished() => _finished++;

  void pageError() {
    _navigationError = const Wenku8BrowserException('文库8网页连接中断，请重试。');
  }

  void attachmentFailed() {
    final waiting = _attachment;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(
        const Wenku8BrowserException('文库8网页组件未能启动，请返回后重试。'),
      );
    }
  }

  Future<Wenku8BrowserPort> _renderer() async {
    if (_port case final ready?) return ready;
    _attachment ??= Completer<Wenku8BrowserPort>();
    if (!_requested) {
      _requested = true;
      notifyListeners();
    }
    final attachment = _attachment!;
    try {
      return await attachment.future.timeout(
        pageTimeout,
        onTimeout: () => throw const Wenku8BrowserException('文库8网页组件启动超时。'),
      );
    } catch (_) {
      if (identical(attachment, _attachment)) _attachment = null;
      _requested = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<T> nativeOrBrowser<T>(
    Future<T> Function() nativeRequest,
    Future<T> Function() browserRequest,
  ) async {
    if (await enabled()) return browserRequest();
    try {
      return await nativeRequest();
    } catch (error) {
      if (!shouldUseWenku8WebViewFallback(error)) rethrow;
      return browserRequest();
    }
  }

  /// Keep the login POST on the transport that produced the displayed image,
  /// even if another request enables browser reading in the meantime.
  Future<Uint8List> downloadCheckcode(
    Future<Uint8List> Function() nativeRequest,
  ) async {
    final request = ++_captchaRequest;
    _loginTransport = null;
    final host = await apiHost();
    var browser = await enabled();
    late final Uint8List image;
    if (browser) {
      image = await captcha();
    } else {
      try {
        image = await nativeRequest();
      } catch (error) {
        if (!shouldUseWenku8WebViewFallback(error)) rethrow;
        browser = true;
        image = await captcha();
      }
    }
    if (host != await apiHost()) {
      throw const Wenku8BrowserException('文库8地址已更改，请刷新验证码。');
    }
    if (request == _captchaRequest) {
      _loginTransport = (host: host, browser: browser);
    }
    return image;
  }

  Future<void> submitLogin({
    required String username,
    required String password,
    required String checkcode,
    required Future<void> Function() nativeRequest,
  }) async {
    final transport = _loginTransport;
    _loginTransport = null;
    ++_captchaRequest;
    if (transport == null || transport.host != await apiHost()) {
      throw const Wenku8BrowserException('验证码已过期，请刷新验证码后登录。');
    }
    if (transport.browser) {
      await login(username, password, checkcode);
    } else {
      await nativeRequest();
    }
  }

  Future<Map<String, dynamic>> _pageState(Wenku8BrowserPort port) async {
    final raw = await port.executeScript(_pageStateScript);
    final value = raw is String ? jsonDecode(raw) : raw;
    if (value is! Map) {
      throw const Wenku8BrowserException('文库8网页状态无法读取，请重试。');
    }
    return Map<String, dynamic>.from(value);
  }

  static bool sameOrigin(String loadedUrl, String apiHost) {
    final loaded = Uri.tryParse(loadedUrl);
    String normalized;
    try {
      normalized = normalizeWenku8Host(apiHost);
    } on FormatException {
      return false;
    }
    if (normalized.isEmpty) return false;
    final host = Uri.parse(normalized);
    return loaded != null &&
        loaded.scheme == 'https' &&
        loaded.host == host.host &&
        loaded.port == 443 &&
        loaded.userInfo.isEmpty;
  }

  Future<void> _navigate(
    Wenku8BrowserPort port,
    String host,
    Uri target,
  ) async {
    if (!sameOrigin(target.toString(), host)) {
      throw const Wenku8BrowserException('文库8请求地址不属于当前站点。');
    }
    // Drain the old document before a new request. A late blank-page callback
    // or a previously loaded login page cannot complete this request.
    await _idle(port);
    _navigationHost = host;
    _epoch++;
    _captchaEpoch = null;
    _navigationError = null;
    final before = _finished;
    await port.loadUrl(target.toString());
    final deadline = DateTime.now().add(pageTimeout);
    var verification = false;
    while (DateTime.now().isBefore(deadline)) {
      if (_navigationError case final error?) throw error;
      if (_finished > before) {
        final state = await _pageState(port);
        final url = state['url'] as String? ?? '';
        if (url == 'about:blank' || url.isEmpty) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        if (!sameOrigin(url, host)) {
          throw const Wenku8BrowserException('文库8网页离开了当前站点，已停止读取。');
        }
        if (state['challenge'] == true) {
          verification = true;
        } else if (state['ready'] == true) {
          final loaded = Uri.parse(url);
          if (loaded.path == '/login.php' && target.path != '/login.php') {
            if (host == await apiHost()) {
              // A legacy native cookie can still report "signed in" even when
              // the browser has no session. Pin this verified login redirect
              // to browser mode before AuthCubit rechecks the current marker.
              await enable(host);
              await _writeProperty(_loginKey, '');
              _sessionInvalidations.add(null);
            }
            throw const Wenku8BrowserException('文库8登录已失效，请重新登录。');
          }
          return;
        }
      }
      await Future<void>.delayed(pollInterval);
    }
    if (verification) throw const Wenku8SiteVerificationRequired();
    throw const Wenku8BrowserException('文库8网页加载超时，请重试。');
  }

  Future<List<HomeBlock>> home() => _serial(() async {
    final host = await apiHost();
    final port = await _renderer();
    try {
      await _navigate(port, host, Uri.parse('$host/'));
      final loaded = await port.currentUrl();
      final raw = await port.executeScript(wenku8HomeDomExtractionScript(host));
      final blocks = parseWenku8HomeWebViewResult(
        raw,
        apiHost: host,
        loadedUrl: loaded,
      );
      await enable(host);
      return blocks;
    } finally {
      await _idle(port);
    }
  });

  Future<T> read<T>(String kind, Uri target, {String? aid}) => _serial(
    () async {
      final host = await apiHost();
      final port = await _renderer();
      try {
        await _navigate(port, host, target);
        final loaded = await port.currentUrl();
        // Wenku8 redirects an exact, single search hit to its detail page.
        // Accept this only for a search GET and parse the strict detail model.
        final redirect = Uri.parse(loaded);
        final matchedBook = RegExp(
          r'^/book/([1-9][0-9]{0,11})\.htm$',
        ).firstMatch(redirect.path);
        if (kind == 'list' &&
            isWenku8SearchRequest(target, host) &&
            matchedBook != null &&
            sameOrigin(loaded, host) &&
            !redirect.hasQuery &&
            !redirect.hasFragment) {
          final bookId = matchedBook[1]!;
          final raw = await port.executeScript(
            wenku8ReadDomExtractionScript(host, kind: 'detail', aid: bookId),
          );
          final info =
              parseWenku8ReadWebViewResult(
                    raw,
                    apiHost: host,
                    loadedUrl: loaded,
                    kind: 'detail',
                    aid: bookId,
                  )
                  as NovelInfo;
          await enable(host);
          return PageStatsNovelCover(
                currentPage: 1,
                maxPage: 1,
                records: [
                  NovelCover(
                    title: info.title,
                    img: info.imgUrl,
                    detailUrl: loaded,
                    aid: bookId,
                  ),
                ],
              )
              as T;
        }
        final raw = await port.executeScript(
          wenku8ReadDomExtractionScript(host, kind: kind, aid: aid),
        );
        final value = parseWenku8ReadWebViewResult(
          raw,
          apiHost: host,
          loadedUrl: loaded,
          kind: kind,
          aid: aid,
        );
        await enable(host);
        return value as T;
      } finally {
        await _idle(port);
      }
    },
  );

  Future<Uint8List> captcha() => _serial(() async {
    final host = await apiHost();
    final port = await _renderer();
    try {
      await _navigate(port, host, Uri.parse('$host/login.php'));
      await port.executeScript(_refreshCaptchaScript);
      final deadline = DateTime.now().add(pageTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final raw = await port.executeScript(_captchaScript);
        final parsed = raw is String ? jsonDecode(raw) : raw;
        if (parsed is Map && parsed['ready'] == true) {
          if (!sameOrigin(parsed['url'] as String? ?? '', host)) {
            throw const Wenku8BrowserException('验证码不属于当前文库8站点。');
          }
          final data = parsed['data'] as String? ?? '';
          if (!data.startsWith('data:image/png;base64,') ||
              data.length > 512 * 1024) {
            throw const Wenku8BrowserException('文库8验证码图片无效，请重试。');
          }
          final bytes = base64Decode(
            data.substring('data:image/png;base64,'.length),
          );
          if (bytes.length < 8 || bytes[0] != 0x89 || bytes[1] != 0x50) {
            throw const Wenku8BrowserException('文库8验证码图片无效，请重试。');
          }
          _captchaHost = host;
          _captchaEpoch = _epoch;
          await enable(host);
          return bytes;
        }
        if (parsed is Map && parsed['failed'] == true) {
          throw const Wenku8BrowserException('文库8没有返回可用验证码，请刷新或打开站点登录。');
        }
        await Future<void>.delayed(pollInterval);
      }
      throw const Wenku8BrowserException('文库8验证码加载超时，请刷新或打开站点登录。');
    } catch (_) {
      await _idle(port);
      rethrow;
    }
  });

  Future<void> login(String username, String password, String checkcode) =>
      _serial(() async {
        final host = await apiHost();
        final port = await _renderer();
        if (_captchaHost != host || _captchaEpoch != _epoch) {
          throw const Wenku8BrowserException('验证码已过期，请刷新验证码后登录。');
        }
        if (!sameOrigin(await port.currentUrl(), host)) {
          throw const Wenku8BrowserException('文库8登录地址已改变，请刷新验证码。');
        }
        final before = _finished;
        _navigationError = null;
        final submitted = await port.executeScript(
          _loginScript(host, username, password, checkcode),
        );
        if (submitted != true) {
          throw const Wenku8BrowserException('文库8登录表单已改变，请刷新验证码。');
        }
        _captchaEpoch = null;
        final deadline = DateTime.now().add(pageTimeout);
        while (DateTime.now().isBefore(deadline)) {
          if (_navigationError != null) {
            throw const Wenku8BrowserException('文库8登录结果未能确认，请打开站点查看。');
          }
          if (_finished > before) {
            final state = await _pageState(port);
            if (!sameOrigin(state['url'] as String? ?? '', host)) {
              throw const Wenku8BrowserException('文库8登录离开了当前站点。');
            }
            if (state['challenge'] == true) {
              throw const Wenku8SiteVerificationRequired();
            }
            if (state['ready'] == true && state['authenticated'] == true) {
              await port.persistSession();
              await _writeProperty(_loginKey, host);
              await enable(host);
              await _idle(port);
              return;
            }
            if (state['loginError'] case final String message) {
              throw Wenku8BrowserException(message);
            }
          }
          await Future<void>.delayed(pollInterval);
        }
        throw const Wenku8BrowserException('文库8登录结果未能确认，请打开站点查看。');
      });

  Future<bool> adoptVisiblePage(
    String host,
    Object? snapshot, {
    Future<void> Function()? persistSession,
  }) async {
    final data = snapshot is String ? jsonDecode(snapshot) : snapshot;
    if (data is! Map || !sameOrigin(data['url'] as String? ?? '', host)) {
      throw const Wenku8BrowserException('当前网页不是配置的文库8站点。');
    }
    if (data['challenge'] == true || data['ready'] != true) {
      throw const Wenku8SiteVerificationRequired();
    }
    if (data['loginForm'] != true &&
        data['authenticated'] != true &&
        data['home'] != true) {
      throw const Wenku8BrowserException('请在文库8登录页或首页完成验证后返回。');
    }
    await persistSession?.call();
    await enable(host);
    _loginTransport = null;
    _captchaEpoch = null;
    ++_captchaRequest;
    final authenticated = data['authenticated'] == true;
    await _writeProperty(_loginKey, authenticated ? host : '');
    return authenticated;
  }

  static String get pageStateScript => _pageStateScript;

  Future<void> signOut() => _serial(() async {
    await _writeProperty(_loginKey, '');
    _loginTransport = null;
    ++_captchaRequest;
    _captchaEpoch = null;
    if (!await enabled()) return;
    final host = await apiHost();
    final port = await _renderer();
    try {
      await _navigate(port, host, Uri.parse('$host/logout.php'));
      await port.persistSession();
    } finally {
      await _idle(port);
    }
  });

  Future<void> _idle(Wenku8BrowserPort port) async {
    _captchaEpoch = null;
    _epoch++;
    try {
      // Stop page scripts and image decoding while the reader is active.
      await port.loadUrl('about:blank');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (await port.currentUrl() == 'about:blank') return;
        await Future<void>.delayed(pollInterval);
      }
    } catch (_) {}
  }

  static const _pageStateScript = r'''
(function() {
  var title = (document.title || '').toLowerCase();
  var text = document.body ? document.body.innerText : '';
  var challenge = !!document.querySelector('#challenge-form,#cf-challenge-running,.cf-browser-verification,#cf-wrapper') ||
    /just a moment|attention required|sorry, you have been blocked/.test(title);
  var error = null;
  if (/用户不存在|用戶不存在/.test(text)) error = '用户不存在';
  else if (/密码错误|密碼錯誤/.test(text)) error = '密码错误';
  else if (/校验码错误|校驗碼錯誤|验证码错误|驗證碼錯誤/.test(text)) error = '验证码错误';
  else if (/验证码过期|驗證碼過期/.test(text)) error = '验证码过期';
  var loginForm = !!document.querySelector('form input[name="username"]') &&
    !!document.querySelector('form input[name="password"]');
  var signedIn = !!document.querySelector('a[href*="logout.php"]') && !loginForm;
  return JSON.stringify({url:location.href,ready:document.readyState === 'complete',
    challenge:challenge,loginForm:loginForm,authenticated:!challenge && signedIn,
    home:!!document.querySelector('#centers,div.main'),loginError:error});
})()
''';

  static const _captchaScript = r'''
(function() {
  var result={url:location.href,ready:false};
  var form=document.querySelector('input[name="username"]');
  if(!form) {result.failed=true;return JSON.stringify(result);}
  var image=Array.from(document.images).find(function(i){
    try {var u=new URL(i.getAttribute('src')||'',location.href);
      return u.origin===location.origin && u.pathname==='/checkcode.php';}
    catch(_){return false;}
  });
  if(!image) {result.failed=true;return JSON.stringify(result);}
  if(!image.complete) return JSON.stringify(result);
  if(image.naturalWidth<1 || image.naturalHeight<1 || image.naturalWidth>1024 || image.naturalHeight>512) {
    result.failed=true;return JSON.stringify(result);
  }
  try {
    var canvas=document.createElement('canvas');
    canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
    canvas.getContext('2d').drawImage(image,0,0);
    result.data=canvas.toDataURL('image/png');result.ready=true;
  }catch(_){result.failed=true;}
  return JSON.stringify(result);
})()
''';

  static const _refreshCaptchaScript = r'''
(function() {
  if(location.pathname!=='/login.php') return false;
  var user=document.querySelector('input[name="username"]');
  var pass=document.querySelector('input[name="password"]');
  var form=user && user.form;
  if(!form || !pass || pass.form!==form || form.method.toLowerCase()!=='post') return false;
  var action=new URL(form.getAttribute('action')||location.href,location.href);
  if(action.origin!==location.origin || action.pathname!=='/login.php') return false;
  var image=Array.from(document.images).find(function(i){
    try {var u=new URL(i.getAttribute('src')||'',location.href);
      return u.origin===location.origin && u.pathname==='/checkcode.php';}
    catch(_){return false;}
  });
  // Some normal login forms omit the CAPTCHA controls. Request the official
  // image within this document so its session still owns the eventual POST.
  if(!image) {
    image=document.createElement('img');
    image.style.display='none';
    form.appendChild(image);
  }
  var url=new URL('/checkcode.php',location.href);
  url.searchParams.set('random',String(Date.now()));
  image.src=url.href;
  return true;
})()
''';

  static String _loginScript(
    String host,
    String username,
    String password,
    String code,
  ) => '''
(function(host,username,password,code) {
  if(location.origin!==host || location.pathname!=='/login.php') return false;
  var user=document.querySelector('input[name="username"]');
  var pass=document.querySelector('input[name="password"]');
  var captcha=document.querySelector('input[name="checkcode"]');
  var form=user && user.form;
  if(!form || !pass || pass.form!==form || (captcha && captcha.form!==form)) return false;
  var action=new URL(form.getAttribute('action')||location.href,location.href);
  if(action.origin!==host || action.pathname!=='/login.php' || form.method.toLowerCase()!=='post') return false;
  if(!captcha) {
    captcha=document.createElement('input');
    captcha.type='hidden';captcha.name='checkcode';
    form.appendChild(captcha);
  }
  user.value=username;pass.value=password;captcha.value=code;
  var actionInput=form.querySelector('input[name="action"]');
  if(actionInput) actionInput.value='login';
  var persistent=form.querySelector('[name="usecookie"]');
  if(persistent && persistent.tagName==='SELECT') {
    // Assigning a value absent from a select clears it and silently creates a
    // process-only session. Use the longest persistence option the site offers.
    var longest=0, selected=null;
    Array.from(persistent.options).forEach(function(option) {
      var seconds=Number(option.value);
      if(!option.disabled && Number.isFinite(seconds) && seconds>longest && seconds<=315360000) {
        longest=seconds;selected=option.value;
      }
    });
    if(selected!==null) persistent.value=selected;
  } else if(persistent && persistent.tagName==='INPUT') {
    persistent.value='315360000';
  }
  HTMLFormElement.prototype.submit.call(form);
  return true;
})(${jsonEncode(host)},${jsonEncode(username)},${jsonEncode(password)},${jsonEncode(code)})
''';
}
