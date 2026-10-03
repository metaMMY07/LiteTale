import 'package:flutter_test/flutter_test.dart';
import 'package:wild/utils/wenku8_network_error.dart';

void main() {
  group('shouldUseWenku8WebViewFallback', () {
    test('recognizes Cloudflare and HTTP 403 failures', () {
      expect(
        shouldUseWenku8WebViewFallback(
          'Failed to get search result: 403 Forbidden',
        ),
        isTrue,
      );
      expect(
        shouldUseWenku8WebViewFallback('Cloudflare Challenge: cf_chl'),
        isTrue,
      );
    });

    test('recognizes rustls unexpected EOF failures', () {
      expect(
        shouldUseWenku8WebViewFallback(
          'peer closed connection without sending TLS close_notify: unexpected-eof',
        ),
        isTrue,
      );
      expect(
        shouldUseWenku8WebViewFallback(
          'client error (SendRequest): connection error',
        ),
        isTrue,
      );
      expect(
        shouldUseWenku8WebViewFallback(
          'error sending request for url (https://www.wenku8.net/)',
        ),
        isTrue,
      );
    });

    test('does not hide unrelated parsing failures', () {
      expect(
        shouldUseWenku8WebViewFallback('Failed to parse bookcase HTML'),
        isFalse,
      );
      expect(
        shouldOfferWenku8SiteVerification('Failed to parse bookcase HTML'),
        isFalse,
      );
    });

    test(
      'formats a 403 as an actionable message without exposing stack traces',
      () {
        final message = wenku8HomeErrorMessage(
          'AnyhowException(GET https://www.wenku8.net/index.php?charset=gbk '
          'failed: HTTP 403 Forbidden (Cloudflare challenge/block HTML))\n'
          'Stack backtrace: <unknown>',
        );

        expect(shouldOfferWenku8SiteVerification('HTTP 403 Forbidden'), isTrue);
        expect(message, contains('站点验证或登录'));
        expect(message, contains('采用网页首页并返回'));
        expect(message, contains('同一站点会话'));
        expect(message, isNot(contains('AnyhowException')));
        expect(message, isNot(contains('Stack backtrace')));
        expect(message, isNot(contains('<unknown>')));
      },
    );

    test('maps connection errors to a short retry hint', () {
      final message = wenku8HomeErrorMessage(
        'error sending request: connection reset',
      );

      expect(shouldOfferWenku8SiteVerification('connection reset'), isTrue);
      expect(message, contains('检查网络后重试'));
      expect(message, isNot(contains('connection reset')));
    });

    test('offers the home DOM entry when native home parsing has no books', () {
      expect(
        shouldOfferWenku8SiteVerification(
          'Wenku8 home contains no usable book recommendations',
        ),
        isTrue,
      );
    });
  });
}
