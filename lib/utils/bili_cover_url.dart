/// Resolves cover attributes independently of the site's navigation policy.
String? biliCoverUrl(Iterable<String?> candidates, {required Uri page}) {
  for (final candidate in candidates) {
    final raw = candidate?.trim();
    if (raw == null || raw.isEmpty) continue;
    final reference = Uri.tryParse(raw);
    if (reference == null) continue;
    final uri = page.resolveUri(reference);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443) {
      continue;
    }
    final allowed =
        const {
          'www.bilinovel.net',
          'bilinovel.net',
          'www.linovelib.com',
          'linovelib.com',
        }.contains(uri.host) ||
        (uri.host == 'img2.readpai.com' && uri.path.startsWith('/image/'));
    if (!allowed || uri.path.endsWith('/book-cover-no.svg')) continue;
    return uri.removeFragment().toString();
  }
  return null;
}
