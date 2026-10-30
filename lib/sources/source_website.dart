import 'package:wild/services/wenku8_host.dart';
import 'book_source.dart';
import 'rule_source_registry.dart';

/// Public website only: no API route, credentials, query or app session.
/// The external browser keeps its own cookies independently of the app.
Uri? sourceWebsite(SourceId source, {String? wenku8Host, Uri? ruleBaseUrl}) {
  if (source == SourceId.localEpub) return null;
  if (source == SourceId.wenku8) {
    try {
      final host = normalizeWenku8Host(wenku8Host ?? '');
      return Uri.parse('${host.isEmpty ? defaultWenku8Host : host}/');
    } on FormatException {
      return Uri.parse('$defaultWenku8Host/');
    }
  }
  if (source.isRule) {
    final uri =
        ruleBaseUrl ??
        RuleSourceRegistry.instance[source.ruleId]?.definition.baseUrl;
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return Uri.parse('${uri.origin}/');
  }
  final url = switch (source) {
    SourceId.lightNovelShelf => 'https://www.lightnovel.app/',
    SourceId.lnovel => 'https://lnovel.tw/',
    SourceId.bili => 'https://www.bilinovel.net/',
    SourceId.huanmeng => 'https://www.huanmengacg.com/',
    SourceId.esj => 'https://www.esjzone.cc/',
    _ => null,
  };
  return url == null ? null : Uri.parse(url);
}
