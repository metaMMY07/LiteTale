/// Returns whether a native Wenku8 request should be retried through WebView.
///
/// Besides Cloudflare responses, Wenku8 occasionally closes a TLS connection
/// without sending `close_notify`. Rustls correctly reports that as an error,
/// while Chromium/WebView can still load the same page. Keep this detection in
/// one place so bookshelf reads and writes behave consistently.
bool shouldUseWenku8WebViewFallback(Object? error) {
  final message = error.toString().toLowerCase();
  const markers = <String>[
    '403',
    'cloudflare',
    'cf_',
    'tls close_notify',
    'tls close notify',
    'unexpected-eof',
    'unexpected eof',
    'peer closed connection',
    'error sending request',
    'error decoding response body',
    'connection error',
    'connection reset',
    'connection aborted',
    'connection closed',
    'sendrequest',
  ];

  return markers.any(message.contains);
}
