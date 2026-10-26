import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wild/sources/huanmeng_source.dart';
import 'package:wild/sources/rules/rule_source_engine.dart';
import 'package:wild/sources/rules/scoped_rule_transport.dart';

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
           );

  static const androidUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  static const iosUserAgent = 'LiteTale/1.1.0 (iOS; Huanmeng public API)';

  final RuleSourceTransport _transport;
  final Duration requestBudget, spacing;
  Future<void> _tail = Future.value();
  final _pending = <Uri, Future<Map<String, dynamic>>>{};
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _retryAt;

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
    final existing = _pending[uri];
    if (existing != null) return existing;
    if (_pending.length >= 16) {
      return Future.error(const HuanmengSourceException('幻梦请求排队已满，请稍后重试'));
    }
    final deadline = DateTime.now().add(requestBudget);
    final task = _tail
        .then((_) async {
          var remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) throw TimeoutException('幻梦请求排队超时');
          final wait = _next.difference(DateTime.now());
          if (wait > Duration.zero) {
            if (wait >= remaining) throw TimeoutException('幻梦请求排队超时');
            await Future<void>.delayed(wait);
          }
          remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) throw TimeoutException('幻梦请求排队超时');
          if (_retryAt?.isAfter(DateTime.now()) == true) {
            throw const HuanmengSourceException('幻梦原站正在限流，请稍后重试');
          }
          _next = DateTime.now().add(spacing);
          final response = await _transport
              .get(uri, timeout: remaining, maxBytes: 2 * 1024 * 1024)
              .timeout(remaining);
          if (response.statusCode == 429) {
            final now = DateTime.now();
            final retry = response.headers['retry-after'];
            final seconds = int.tryParse(retry ?? '');
            DateTime? until;
            if (seconds != null) {
              until = now.add(Duration(seconds: seconds.clamp(1, 604800)));
            } else if (retry != null) {
              try {
                until = HttpDate.parse(retry);
              } on HttpException {
                /* default below */
              }
            }
            final cap = now.add(const Duration(days: 7));
            _retryAt =
                until == null || !until.isAfter(now)
                    ? now.add(const Duration(seconds: 30))
                    : (until.isAfter(cap) ? cap : until);
            throw const HuanmengSourceException('幻梦原站正在限流，请稍后重试');
          }
          if (response.statusCode != 200) {
            throw HuanmengSourceException(
              '幻梦接口暂不可用（HTTP ${response.statusCode}）',
            );
          }
          if (response.bytes.length > 2 * 1024 * 1024) {
            throw const FormatException('幻梦响应超过大小上限');
          }
          try {
            final data = jsonDecode(utf8.decode(response.bytes));
            if (data is Map<String, dynamic>) return data;
          } on FormatException {
            throw const HuanmengSourceException('幻梦返回了验证或非 JSON 页面，请稍后重试');
          }
          throw const HuanmengSourceException('幻梦接口返回格式异常');
        })
        .timeout(requestBudget);
    _pending[uri] = task;
    void clear() {
      if (identical(_pending[uri], task)) _pending.remove(uri);
    }

    _tail = task.then<void>((_) => clear(), onError: (Object _) => clear());
    return task;
  }
}
