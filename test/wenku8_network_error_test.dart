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
    });
  });
}
