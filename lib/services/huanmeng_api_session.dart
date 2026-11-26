import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/huanmeng_source.dart';

abstract interface class HuanmengBrowserPort {
  Future<void> loadUrl(String url);
  Future<dynamic> executeScript(String script);
}

class HuanmengVerificationRequired implements Exception {
  HuanmengVerificationRequired(this.target, this.revision);
  final Uri target;
  final int revision;
  @override
  String toString() => '幻梦原站需要浏览器验证，请完成验证后继续。';
}

class HuanmengApiException implements Exception {
  const HuanmengApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uses the ordinary website session owned by WebKit. No cookie values or
/// imported scripts leave the browser, and a challenge never means success.
class HuanmengApiSession extends ChangeNotifier implements HuanmengTransport {
  HuanmengApiSession({
    this.operationTimeout = const Duration(seconds: 9),
    this.pollInterval = const Duration(milliseconds: 120),
    this.challengeGrace = const Duration(seconds: 3),
    this.requestSpacing = const Duration(milliseconds: 100),
  });
  static final instance = HuanmengApiSession();
  static final origin = Uri.parse('https://www.huanmengacg.com');
  static const maxBytes = 2 * 1024 * 1024;
  final Duration operationTimeout, pollInterval, challengeGrace, requestSpacing;
  bool requested = false, _disposed = false;
  int rendererGeneration = 0, _sequence = 0;
  HuanmengBrowserPort? _port;
  Completer<HuanmengBrowserPort>? _attachment;
  Future<void> _queue = Future.value();
  final _inflight = <String, Future<Map<String, dynamic>>>{};
  DateTime? _cooldown;
  DateTime? _lastRequest;
  int? _requestRevision;
  DateTime? get retryAt => _cooldown;
  final _verified = <String, (DateTime, int, Map<String, dynamic>)>{};

  static bool allowsNavigation(String raw) {
    if (raw == 'about:blank') return true;
    final uri = Uri.tryParse(raw);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == origin.host &&
        uri.port == 443 &&
        uri.userInfo.isEmpty;
  }

  static bool isApiTarget(Uri uri) =>
      allowsNavigation(uri.toString()) &&
      !uri.hasFragment &&
      const {
        'search',
        'detail',
        'chapters',
        'content',
      }.any((operation) => uri.path == '/index.php/bookapi/$operation');

  void attach(HuanmengBrowserPort port, int generation) {
    if (_disposed || generation != rendererGeneration) return;
    _port = port;
    if (_attachment?.isCompleted == false) _attachment!.complete(port);
  }

  void detach(HuanmengBrowserPort port) {
    if (identical(_port, port)) _port = null;
  }

  void _check(DateTime deadline, int generation) {
    if (_disposed || generation != rendererGeneration) {
      throw const HuanmengApiException('幻梦网页请求已过期，请重试。');
    }
    if (!DateTime.now().isBefore(deadline)) {
      _invalidate(generation);
      throw const HuanmengApiException('幻梦请求超时，请稍后重试。');
    }
    if (_requestRevision != sourceRevision.value) {
      _invalidate(generation);
      throw const HuanmengApiException('书源已切换，请重新打开书籍。');
    }
  }

  void _invalidate(int generation) {
    if (_disposed || generation != rendererGeneration) return;
    rendererGeneration++;
    _port = null;
    _attachment = null;
    notifyListeners();
  }

  Future<T> _bounded<T>(
    Future<T> Function() work,
    DateTime deadline,
    int generation, {
    bool startup = false,
  }) async {
    _check(deadline, generation);
    final remaining = deadline.difference(DateTime.now());
    final cap =
        startup ? const Duration(seconds: 12) : const Duration(seconds: 5);
    final result = await work().timeout(
      remaining < cap ? remaining : cap,
      onTimeout: () {
        _invalidate(generation);
        throw const HuanmengApiException('幻梦网页组件响应超时，请重试。');
      },
    );
    _check(deadline, generation);
    return result;
  }

  @override
  Future<Map<String, dynamic>> read(Uri uri) {
    if (!isApiTarget(uri)) {
      return Future.error(const HuanmengApiException('拒绝访问幻梦 API 以外的地址。'));
    }
    final deadline = DateTime.now().add(operationTimeout);
    final revision = sourceRevision.value;
    final key = '$revision|$uri';
    final pending = _inflight[key];
    if (pending != null) {
      return pending;
    }
    final next = _queue.then((_) => _read(uri, deadline, revision));
    _inflight[key] = next;
    void clear() {
      if (identical(_inflight[key], next)) _inflight.remove(key);
    }

    unawaited(next.then<void>((_) => clear(), onError: (Object _) => clear()));
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Map<String, dynamic>> _read(
    Uri uri,
    DateTime deadline,
    int revision,
  ) async {
    if (_disposed ||
        revision != sourceRevision.value ||
        !DateTime.now().isBefore(deadline)) {
      throw const HuanmengApiException('幻梦请求已过期，请重试。');
    }
    _requestRevision = revision;
    final generation = rendererGeneration;
    _check(deadline, generation);
    if (_cooldown?.isAfter(DateTime.now()) == true) {
      throw const HuanmengApiException('原站正在限流，请稍后再试。');
    }
    _verified.removeWhere((_, entry) => entry.$1.isBefore(DateTime.now()));
    final accepted = _verified.remove(uri.toString());
    if (accepted != null && accepted.$2 == revision) return accepted.$3;
    var port = _port;
    if (port == null) {
      _attachment ??= Completer<HuanmengBrowserPort>();
      requested = true;
      notifyListeners();
      port = await _bounded(
        () => _attachment!.future,
        deadline,
        generation,
        startup: true,
      );
    }
    final document = decodeProbe(
      await _bounded(
        () => port!.executeScript(documentProbe),
        deadline,
        generation,
      ),
    );
    if (document['rateLimited'] == true) {
      _invalidate(generation);
      _rateLimit(null);
    }
    if (allowsNavigation('${document['url']}') &&
        document['url'] != 'about:blank' &&
        document['ready'] == true &&
        document['challenge'] != true &&
        document['rateLimited'] != true) {
      return _fetch(port!, uri, deadline, generation);
    }
    return _navigate(port!, uri, deadline, generation);
  }

  Future<Map<String, dynamic>> _navigate(
    HuanmengBrowserPort port,
    Uri uri,
    DateTime deadline,
    int generation,
  ) async {
    await _networkSlot(deadline, generation);
    await _bounded(() => port.loadUrl(uri.toString()), deadline, generation);
    final started = DateTime.now();
    while (true) {
      _check(deadline, generation);
      final probe = decodeProbe(
        await _bounded(
          () => port.executeScript(documentProbe),
          deadline,
          generation,
        ),
      );
      if (probe['url'] == uri.toString() && probe['ready'] == true) {
        if (probe['tooLarge'] == true) {
          throw const HuanmengApiException('幻梦响应超过大小上限。');
        }
        if (probe['rateLimited'] == true) {
          _invalidate(generation);
          _rateLimit(null);
        }
        if (probe['challenge'] == true) {
          if (DateTime.now().difference(started) >= challengeGrace) {
            _invalidate(generation);
            throw HuanmengVerificationRequired(uri, _requestRevision!);
          }
        } else {
          try {
            return _decodeResponse(probe['text']);
          } on HuanmengApiException {
            _invalidate(generation);
            rethrow;
          }
        }
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<Map<String, dynamic>> _fetch(
    HuanmengBrowserPort port,
    Uri uri,
    DateTime deadline,
    int generation,
  ) async {
    await _networkSlot(deadline, generation);
    final token = '${generation}_${++_sequence}';
    await _bounded(
      () => port.executeScript(fetchScript(uri, token)),
      deadline,
      generation,
    );
    while (true) {
      _check(deadline, generation);
      final result = decodeProbe(
        await _bounded(
          () => port.executeScript(fetchProbe),
          deadline,
          generation,
        ),
      );
      if (result['token'] == token && result['status'] == 429) {
        _rateLimit(result['retryAfter'] as String?);
      }
      if (result['token'] == token && result['done'] == true) {
        if (result['status'] == 429) {
          _rateLimit(result['retryAfter'] as String?);
        }
        if (result['tooLarge'] == true) {
          throw const HuanmengApiException('幻梦响应超过大小上限。');
        }
        if (result['challenge'] == true ||
            result['status'] == 403 && result['html'] == true) {
          _invalidate(generation);
          throw HuanmengVerificationRequired(uri, _requestRevision!);
        }
        if (result['status'] != 200) {
          throw const HuanmengApiException('幻梦 API 暂时不可用，请稍后再试。');
        }
        return _decodeResponse(
          result['text'],
          retryAfter: result['retryAfter'] as String?,
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<void> _networkSlot(DateTime deadline, int generation) async {
    final next = _lastRequest?.add(requestSpacing);
    if (next != null && next.isAfter(DateTime.now())) {
      await Future<void>.delayed(next.difference(DateTime.now()));
    }
    _check(deadline, generation);
    _lastRequest = DateTime.now();
  }

  Map<String, dynamic> _decodeResponse(dynamic text, {String? retryAfter}) {
    final envelope = decodeEnvelope(text, requireData: false);
    if (envelope['code'] == 429 || envelope['code'] == '429') {
      _rateLimit(retryAfter);
    }
    if (envelope['data'] is! Map) {
      throw const HuanmengApiException('幻梦 API 返回错误或接口密钥已更新，请稍后重试。');
    }
    return envelope;
  }

  Never _rateLimit(String? retryAfter) {
    final seconds = int.tryParse(retryAfter ?? '');
    DateTime? until;
    if (seconds != null) {
      until = DateTime.now().add(Duration(seconds: seconds.clamp(1, 604800)));
    } else {
      try {
        until = HttpDate.parse(retryAfter ?? '');
      } on HttpException {
        /* Use a conservative fallback. */
      }
    }
    final now = DateTime.now(),
        maximum = DateTime.now().add(const Duration(days: 7));
    _cooldown =
        until?.isAfter(now) == true
            ? (until!.isAfter(maximum) ? maximum : until)
            : now.add(const Duration(seconds: 60));
    throw const HuanmengApiException('幻梦原站正在限流，请稍后再试。');
  }

  static Map<String, dynamic> decodeProbe(dynamic raw) {
    for (var i = 0; i < 2 && raw is String; i++) {
      if (raw.length > maxBytes * 8) {
        throw const HuanmengApiException('幻梦网页返回数据过大。');
      }
      try {
        raw = jsonDecode(raw);
      } on FormatException {
        throw const HuanmengApiException('幻梦网页返回数据无效。');
      }
    }
    if (raw is! Map) throw const HuanmengApiException('幻梦网页返回数据无效。');
    return Map<String, dynamic>.from(raw);
  }

  static Map<String, dynamic> decodeEnvelope(
    dynamic text, {
    bool requireData = true,
  }) {
    if (text is! String || utf8.encode(text).length > maxBytes) {
      throw const HuanmengApiException('幻梦 API 响应无效或过大。');
    }
    dynamic data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      throw const HuanmengApiException('幻梦 API 没有返回有效书籍数据。');
    }
    if (data is! Map || requireData && data['data'] is! Map) {
      throw const HuanmengApiException('幻梦 API 返回错误或接口密钥已更新，请稍后重试。');
    }
    return Map<String, dynamic>.from(data);
  }

  static Map<String, dynamic>? verifiedEnvelope(
    HuanmengVerificationRequired request,
    dynamic probe,
  ) {
    if (request.revision != sourceRevision.value ||
        !isApiTarget(request.target)) {
      return null;
    }
    final data = decodeProbe(probe);
    if (data['url'] != request.target.toString() ||
        data['ready'] != true ||
        data['challenge'] == true ||
        data['tooLarge'] == true ||
        data['rateLimited'] == true) {
      return null;
    }
    final json = decodeEnvelope(data['text']);
    if (!HuanmengSource.canVerifyResponse(request.target, json)) {
      return null;
    }
    return json;
  }

  bool acceptVerification(HuanmengVerificationRequired request, dynamic probe) {
    final json = verifiedEnvelope(request, probe);
    if (json == null || _disposed) return false;
    while (_verified.length >= 4) {
      _verified.remove(_verified.keys.first);
    }
    _verified[request.target.toString()] = (
      DateTime.now().add(const Duration(minutes: 1)),
      request.revision,
      json,
    );
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _port = null;
    _verified.clear();
    _inflight.clear();
    super.dispose();
  }

  static const documentProbe = r'''(() => {
    const text = document.body ? document.body.innerText : '';
    const title = document.title || '', size=new TextEncoder().encode(text).byteLength;
    const jsonLike=/^[{\[]/.test(text.trim());
    return JSON.stringify({url:location.href,ready:document.readyState==='complete' || document.readyState==='interactive',
      text:size<=2097152?text:null,tooLarge:size>2097152,
      challenge:!jsonLike && (/Just a moment|Attention Required/i.test(title) || /Sorry, you have been blocked|Checking your browser|Verify you are human/i.test(text)),
      rateLimited:!jsonLike && (/429|Too Many Requests|Rate Limited/i.test(title) || /429.{0,60}Too Many Requests|Too Many Requests.{0,60}429|you are being rate limited/i.test(text))});
  })()''';
  static const fetchProbe =
      "JSON.stringify(window.__litetaleHuanmengApi_v1 || {})";
  static String fetchScript(Uri uri, String token) => '''(() => {
    const token=${jsonEncode(token)}, url=${jsonEncode(uri.toString())};
    const state={token,done:false}; window.__litetaleHuanmengApi_v1=state;
    const controller=new AbortController(); const timer=setTimeout(()=>controller.abort(),12000);
    (async()=>{try {
      const response=await fetch(url,{credentials:'same-origin',redirect:'error',signal:controller.signal,headers:{Accept:'application/json'}});
      state.status=response.status; state.retryAfter=response.headers.get('Retry-After');
      if(response.status===429){controller.abort();return;}
      state.html=(response.headers.get('Content-Type')||'').toLowerCase().includes('text/html');
      state.challenge=response.headers.get('cf-mitigated')==='challenge';
      const reader=response.body.getReader(); const chunks=[];let length=0;
      while(true){const part=await reader.read();if(part.done)break;length+=part.value.byteLength;
        if(length>2097152){state.tooLarge=true;controller.abort();break;}chunks.push(part.value);}
      if(!state.tooLarge){const all=new Uint8Array(length);let offset=0;
        for(const chunk of chunks){all.set(chunk,offset);offset+=chunk.byteLength;}
        state.text=new TextDecoder().decode(all);state.challenge=state.challenge || state.html && /Just a moment|Sorry, you have been blocked/i.test(state.text);}
    }catch(_){state.status=state.status||0;}finally{clearTimeout(timer);state.done=true;}})();
    return true;
  })()''';
}
