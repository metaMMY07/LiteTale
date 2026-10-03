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
    'no usable book recommendations',
    'failed to decode utf-8 wenku8 home',
    'failed to decode gbk',
    'captcha_fetch_failed',
    '站点验证',
    '请重新登录',
    '网页加载超时',
    '网页连接中断',
    '没有返回可用验证码',
  ];

  return markers.any(message.contains);
}

bool shouldOfferWenku8SiteVerification(Object? error) {
  return shouldUseWenku8WebViewFallback(error);
}

String wenku8HomeErrorMessage(Object? error) {
  final message = error.toString().toLowerCase();
  if (message.contains('403') ||
      message.contains('cloudflare') ||
      message.contains('cf_') ||
      message.contains('just a moment') ||
      message.contains('attention required') ||
      message.contains('blocked')) {
    return '文库8要求站点验证或登录。请打开文库8网页，完成后点“采用网页首页并返回”。随后应用会使用同一站点会话读取首页和小说。';
  }
  if (message.contains('站点验证') || message.contains('请重新登录')) {
    return '文库8站点会话需要验证或重新登录。请打开文库8网页，完成后返回重试。';
  }
  if (message.contains('timeout') ||
      message.contains('timed out') ||
      message.contains('connection') ||
      message.contains('unexpected-eof') ||
      message.contains('unexpected eof')) {
    return '文库8连接暂时中断。请检查网络后重试；仍无法打开时，可进入文库8站点查看。';
  }
  return '文库8推荐暂时无法加载，请稍后重试。';
}
