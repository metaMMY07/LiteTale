import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_rate_limit.dart';
import 'package:wild/utils/wenku8_network_error.dart';

void main() {
  test('book and chapter numbers are not HTTP status codes', () {
    expect(
      isWenku8RateLimited(
        Exception('GET https://www.wenku8.net/book/429.htm failed: HTTP 404'),
      ),
      isFalse,
    );
    expect(isWenku8RateLimited(Exception('章节 429 解析失败')), isFalse);
    expect(
      isWenku8RateLimited(Exception('HTTP 429 Too Many Requests')),
      isTrue,
    );
  });
  test('cooldown respects server duration, expiry and host isolation', () {
    var now = DateTime.utc(2026, 10, 21);
    final gate = Wenku8RateLimits(now: () => now);
    gate.record('https://www.wenku8.net', retryAfterSeconds: 60);
    now = now.add(const Duration(seconds: 30));
    gate.record('https://www.wenku8.net', retryAfterSeconds: 2);
    expect(
      () => gate.check('https://www.wenku8.net'),
      throwsA(isA<Wenku8RateLimited>()),
    );
    expect(() => gate.check('https://other.wenku8.net'), returnsNormally);
    now = now.add(const Duration(seconds: 31));
    expect(() => gate.check('https://www.wenku8.net'), returnsNormally);
  });
  test('native 429 never falls through to verification or leaks its trace', () {
    const native =
        'AnyhowException(wenku8_rate_limited HTTP 429 retry_after_seconds=55 Cloudflare)\nStack backtrace: secret';
    final now = DateTime.utc(2026);
    final error = Wenku8RateLimits(now: () => now).recordError('host', native);
    expect(error.secondsRemaining(now), 55);
    expect(shouldUseWenku8WebViewFallback(native), isFalse);
    expect(shouldOfferWenku8SiteVerification(native), isFalse);
    expect(wenku8ReadErrorMessage(native), contains('429'));
    expect(wenku8ReadErrorMessage(native), isNot(contains('Stack')));
    expect(wenku8HomeErrorMessage(native), contains('429'));
  });
}
