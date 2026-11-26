const defaultWenku8Host = 'https://www.wenku8.net';
const wenku8HostHint = '仅支持 HTTPS 的 wenku8.net 或其子域名根地址；端口仅支持443，不含登录信息。';

/// These hosts share the login cookie domain used by the native and WebView
/// adapters. Independent mirror domains require a separate account adapter.
String normalizeWenku8Host(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  final uri = Uri.tryParse(text);
  final host = uri?.host.toLowerCase() ?? '';
  if (uri == null ||
      uri.scheme != 'https' ||
      !(host == 'wenku8.net' || host.endsWith('.wenku8.net')) ||
      host
          .split('.')
          .any(
            (part) =>
                part.isEmpty ||
                !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(part),
          ) ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(wenku8HostHint);
  }
  return 'https://$host';
}
