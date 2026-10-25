import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'rule_source_engine.dart';

/// An imported iOS source owns its public website session. Cookies never leave
/// this origin or share storage with a built-in source/account. Replacing the
/// adapter discards this small, memory-only session and any pending results.
class ScopedRuleSourceTransport implements RuleSourceTransport {
  ScopedRuleSourceTransport({
    required this.origin,
    this.userAgent,
    this.cookiesEnabled = false,
  });
  final Uri origin;
  final String? userAgent;
  final bool cookiesEnabled;
  final _cookies = <(String, String), _SessionCookie>{};
  DateTime? _cooldown;

  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    if (uri.origin != origin.origin || uri.userInfo.isNotEmpty) {
      throw const FormatException('书源请求必须与来源站点同源');
    }
    final cooldown = _cooldown;
    if (cooldown != null && cooldown.isAfter(DateTime.now())) {
      throw StateError('原站请求过于频繁，请稍后重试');
    }
    final client = HttpClient()..connectionTimeout = timeout;
    Future<RuleSourceHttpResponse> read() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/json;q=0.9,*/*;q=0.5',
      );
      if (userAgent != null) {
        request.headers.set(HttpHeaders.userAgentHeader, userAgent!);
      }
      if (cookiesEnabled) {
        final now = DateTime.now();
        _cookies.removeWhere(
          (_, value) => value.expires?.isBefore(now) == true,
        );
        final values =
            _cookies.values.where((c) => c.matches(uri)).toList()
              ..sort((a, b) => b.path.length.compareTo(a.path.length));
        request.cookies.addAll(values.map((c) => Cookie(c.name, c.value)));
      }
      final response = await request.close();
      if (cookiesEnabled) _remember(response.cookies, uri);
      final headers = <String, String>{};
      response.headers.forEach(
        (key, values) => headers[key.toLowerCase()] = values.join(', '),
      );
      if (response.statusCode == 429) {
        final retry = headers[HttpHeaders.retryAfterHeader];
        final seconds = int.tryParse(retry ?? '');
        DateTime? until;
        if (seconds != null) {
          until = DateTime.now().add(
            Duration(seconds: seconds.clamp(1, 604800)),
          );
        } else if (retry != null) {
          try {
            until = HttpDate.parse(retry);
          } on HttpException {
            /* default below */
          }
        }
        final now = DateTime.now();
        final latest = now.add(const Duration(days: 7));
        _cooldown =
            until == null || !until.isAfter(now)
                ? now.add(const Duration(seconds: 30))
                : until.isAfter(latest)
                ? latest
                : until;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.listen(null).cancel();
        return RuleSourceHttpResponse(
          statusCode: response.statusCode,
          headers: headers,
          bytes: Uint8List(0),
        );
      }
      final body = BytesBuilder(copy: false);
      var size = 0;
      await for (final chunk in response) {
        size += chunk.length;
        if (size > maxBytes) throw const FormatException('书源响应超过大小上限');
        body.add(chunk);
      }
      return RuleSourceHttpResponse(
        statusCode: response.statusCode,
        headers: headers,
        bytes: body.takeBytes(),
      );
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('书源请求超时', timeout);
        },
      );
    } finally {
      client.close(force: true);
    }
  }

  void _remember(List<Cookie> cookies, Uri uri) {
    for (final cookie in cookies.take(64)) {
      final domain = cookie.domain?.toLowerCase().replaceFirst(
        RegExp(r'^\.'),
        '',
      );
      if (domain != null &&
          domain.isNotEmpty &&
          uri.host != domain &&
          !uri.host.endsWith('.$domain')) {
        continue;
      }
      final specifiedPath = cookie.path;
      final path =
          specifiedPath != null && specifiedPath.startsWith('/')
              ? specifiedPath
              : uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
      final key = (cookie.name, path);
      final expires =
          cookie.maxAge != null
              ? DateTime.now().add(
                Duration(seconds: cookie.maxAge!.clamp(0, 604800)),
              )
              : cookie.expires;
      if (cookie.name.length + cookie.value.length > 4096 ||
          expires?.isAfter(DateTime.now()) == false) {
        _cookies.remove(key);
        continue;
      }
      _cookies.remove(key);
      _cookies[key] = _SessionCookie(
        cookie.name,
        cookie.value,
        path,
        cookie.secure,
        expires,
      );
      while (_cookies.length > 64) {
        _cookies.remove(_cookies.keys.first);
      }
    }
  }
}

class _SessionCookie {
  const _SessionCookie(
    this.name,
    this.value,
    this.path,
    this.secure,
    this.expires,
  );
  final String name, value, path;
  final bool secure;
  final DateTime? expires;
  bool matches(Uri uri) =>
      (!secure || uri.scheme == 'https') &&
      (uri.path == path ||
          (uri.path.startsWith(path) &&
              (path.endsWith('/') ||
                  uri.path.substring(path.length).startsWith('/'))));
}
