/// A 429 is a request to wait, not an expired login or a browser challenge.
class Wenku8RateLimited implements Exception {
  const Wenku8RateLimited(this.retryAt);
  final DateTime retryAt;

  int secondsRemaining(DateTime now) {
    final ms = retryAt.difference(now).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  @override
  String toString() {
    final seconds = secondsRemaining(DateTime.now());
    return seconds > 0
        ? '文库8暂时限制了请求（HTTP 429），请在 $seconds 秒后重试。已有书架和已缓存章节仍可使用。'
        : '文库8暂时限制了请求（HTTP 429），请稍后重试。';
  }
}

bool isWenku8RateLimited(Object? error) =>
    error is Wenku8RateLimited ||
    RegExp(
      r'\bhttp\s*[:\[(]?\s*429\b|\b(?:status|statuscode)\s*[:=(]?\s*429\b|too many requests|wenku8_rate_limited',
      caseSensitive: false,
    ).hasMatch(error.toString());

/// Only stores deadlines, never an error response, account data or cookies.
class Wenku8RateLimits {
  Wenku8RateLimits({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _until = <String, DateTime>{};

  void check(String host) {
    final until = _until[host];
    if (until == null) return;
    if (until.isAfter(_now())) throw Wenku8RateLimited(until);
    _until.remove(host);
  }

  Wenku8RateLimited record(String host, {int? retryAfterSeconds}) {
    // A missing/malformed header gets a short cooldown, never an instant retry.
    final seconds = (retryAfterSeconds ?? 30).clamp(1, 604800);
    final until = _now().add(Duration(seconds: seconds));
    final previous = _until[host];
    _until[host] =
        previous != null && previous.isAfter(until) ? previous : until;
    while (_until.length > 4) {
      _until.remove(_until.keys.first);
    }
    return Wenku8RateLimited(_until[host]!);
  }

  Wenku8RateLimited recordError(String host, Object error) {
    if (error is Wenku8RateLimited) {
      return record(host, retryAfterSeconds: error.secondsRemaining(_now()));
    }
    final match = RegExp(
      r'retry_after_seconds=(\d+)',
    ).firstMatch(error.toString());
    return record(host, retryAfterSeconds: int.tryParse(match?.group(1) ?? ''));
  }
}
