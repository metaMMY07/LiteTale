import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:wild/sources/huanmeng_source.dart';
import 'package:wild/sources/rules/rule_source_engine.dart';
import 'package:wild/sources/rules/scoped_rule_transport.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/read_diagnostics.dart';

/// Anonymous, fixed-origin public API. No account cookies, automatic retries
/// or alternate hosts. Queue time counts towards the caller's request budget.
class HuanmengHttpTransport implements HuanmengTransport {
  HuanmengHttpTransport({
    RuleSourceTransport? transport,
    String? userAgent,
    this.requestBudget = const Duration(seconds: 9),
    this.spacing = const Duration(milliseconds: 350),
  }) : _transport =
           transport ??
           ScopedRuleSourceTransport(
             origin: HuanmengSource.origin,
             userAgent: userAgent ?? androidUserAgent,
             diagnosticSource: 'huanmeng',
           );

  static const androidUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  static const iosUserAgent = 'LiteTale/1.1.0 (iOS; Huanmeng public API)';

  final RuleSourceTransport _transport;
  final Duration requestBudget, spacing;
  final _pending = SharedReadPool<Uri, Map<String, dynamic>>();
  final _queue = Queue<_HuanmengRead>();
  final _clock = Stopwatch()..start();
  Duration _next = Duration.zero;
  Duration _retryAt = Duration.zero;
  bool _draining = false;

  @override
  Future<Map<String, dynamic>> read(Uri uri) {
    if (uri.origin != HuanmengSource.origin.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !const {
          'search',
          'detail',
          'chapters',
          'content',
        }.any((operation) => uri.path == '/index.php/bookapi/$operation')) {
      return Future.error(const FormatException('幻梦只能请求原站公开接口'));
    }
    if (!_pending.contains(uri) && _pending.length >= 16) {
      return Future.error(const HuanmengSourceException('幻梦请求排队已满，请稍后重试'));
    }
    return _pending.run(uri, () => _enqueue(uri));
  }

  Future<Map<String, dynamic>> _enqueue(Uri uri) {
    final scope = ReadRequest.current!;
    scope.check();
    final work = _HuanmengRead(uri, scope);
    work.timer = Timer(requestBudget, () {
      scope.cancel(TimeoutException('幻梦请求超时', requestBudget));
    });
    work.removeCancel = scope.onCancel((error) {
      _queue.remove(work);
      if (!work.result.isCompleted) work.result.completeError(error);
      work.timer?.cancel();
    });
    _queue.add(work);
    if (!_draining) unawaited(_drain());
    return work.result.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final work = _queue.removeFirst();
        try {
          work.scope.check();
          ReadDiagnostics.record('huanmeng', 'queue', work.clock.elapsed);
          final wait = _next - _clock.elapsed;
          if (wait > Duration.zero) {
            if (wait >= requestBudget - work.clock.elapsed) {
              throw TimeoutException('幻梦请求排队超时');
            }
            await ReadDiagnostics.measure(
              'huanmeng',
              'spacing',
              () => work.scope.wait(Future<void>.delayed(wait)),
            );
          }
          work.scope.check();
          final remaining = requestBudget - work.clock.elapsed;
          if (remaining <= Duration.zero) throw TimeoutException('幻梦请求排队超时');
          if (_retryAt > _clock.elapsed) {
            throw const HuanmengSourceException('幻梦原站正在限流，请稍后重试');
          }
          _next = _clock.elapsed + spacing;
          final response = await ReadRequest.run(
            work.scope,
            () => _transport.get(
              work.uri,
              timeout: remaining,
              maxBytes: 2 * 1024 * 1024,
            ),
          ).timeout(
            remaining,
            onTimeout: () {
              final error = TimeoutException('幻梦请求超时', requestBudget);
              work.scope.cancel(error);
              throw error;
            },
          );
          // Retain a received Retry-After even if the caller just left.
          if (response.statusCode == 429) {
            _rememberCooldown(response.headers['retry-after']);
            throw const HuanmengSourceException('幻梦原站正在限流，请稍后重试');
          }
          work.scope.check();
          if (response.statusCode != 200) {
            throw HuanmengSourceException(
              '幻梦接口暂不可用（HTTP ${response.statusCode}）',
            );
          }
          if (response.bytes.length > 2 * 1024 * 1024) {
            throw const FormatException('幻梦响应超过大小上限');
          }
          Map<String, dynamic>? result;
          try {
            final text = ReadDiagnostics.measureSync(
              'huanmeng',
              'utf8_decode',
              () => utf8.decode(response.bytes),
            );
            final data = ReadDiagnostics.measureSync(
              'huanmeng',
              'json_decode',
              () => jsonDecode(text),
            );
            if (data is Map<String, dynamic>) result = data;
          } on FormatException {
            throw const HuanmengSourceException('幻梦返回了验证或非 JSON 页面，请稍后重试');
          }
          if (result == null) throw const HuanmengSourceException('幻梦接口返回格式异常');
          if (!work.result.isCompleted) work.result.complete(result);
        } catch (error, stack) {
          if (!work.result.isCompleted) work.result.completeError(error, stack);
        } finally {
          work.timer?.cancel();
          work.removeCancel();
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _rememberCooldown(String? retry) {
    final seconds = int.tryParse(retry ?? '');
    var delay = const Duration(seconds: 30);
    if (seconds != null) {
      delay = Duration(seconds: seconds.clamp(1, 604800));
    } else if (retry != null) {
      try {
        final candidate = HttpDate.parse(retry).difference(DateTime.now());
        if (candidate > Duration.zero) {
          delay =
              candidate > const Duration(days: 7)
                  ? const Duration(days: 7)
                  : candidate;
        }
      } on HttpException {
        /* bounded default */
      }
    }
    final until = _clock.elapsed + delay;
    if (until > _retryAt) _retryAt = until;
  }
}

class _HuanmengRead {
  _HuanmengRead(this.uri, this.scope);
  final Uri uri;
  final ReadRequest scope;
  final clock = Stopwatch()..start();
  final result = Completer<Map<String, dynamic>>();
  Timer? timer;
  void Function() removeCancel = () {};
}
