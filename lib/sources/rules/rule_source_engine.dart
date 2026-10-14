import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'rule_source_definition.dart';
import 'rule_source_models.dart';

class RuleSourceLimits {
  const RuleSourceLimits({
    this.requestTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 30),
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.maxPages = 12,
    this.maxRedirects = 4,
  });

  final Duration requestTimeout;
  final Duration operationTimeout;
  final int maxResponseBytes;
  final int maxPages;
  final int maxRedirects;

  void validate(String sourceId) {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(minutes: 1) ||
        operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(minutes: 2)) {
      throw RuleSourceLimitException(sourceId, '请求时限必须在 1 毫秒至 2 分钟内。');
    }
    if (maxResponseBytes < 1 || maxResponseBytes > 20 * 1024 * 1024) {
      throw RuleSourceLimitException(sourceId, '响应上限必须在 1 字节至 20 MiB 内。');
    }
    if (maxPages < 1 || maxPages > 50) {
      throw RuleSourceLimitException(sourceId, '分页上限必须在 1 至 50 页内。');
    }
    if (maxRedirects < 0 || maxRedirects > 8) {
      throw RuleSourceLimitException(sourceId, '跳转上限必须在 0 至 8 次内。');
    }
  }
}

class RuleSourceHttpResponse {
  const RuleSourceHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bytes;
}

/// A deliberately small transport seam for deterministic, offline tests.
/// Implementations receive only an HTTP(S) URI and never receive credentials.
abstract interface class RuleSourceTransport {
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  });
}

/// Default transport disables automatic redirects and reads the body as a
/// bounded stream. One client per request means a timeout closes that socket.
class IoRuleSourceTransport implements RuleSourceTransport {
  const IoRuleSourceTransport();

  @override
  Future<RuleSourceHttpResponse> get(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    final client = http.Client();
    Future<RuleSourceHttpResponse> read() async {
      final request =
          http.Request('GET', uri)
            ..followRedirects = false
            ..headers['accept'] = 'text/html,application/json;q=0.9,*/*;q=0.5'
            ..headers['accept-encoding'] = 'gzip';
      final response = await client.send(request);
      final headers = <String, String>{
        for (final entry in response.headers.entries)
          entry.key.toLowerCase(): entry.value,
      };
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.stream.listen(null).cancel();
        return RuleSourceHttpResponse(
          statusCode: response.statusCode,
          headers: headers,
          bytes: Uint8List(0),
        );
      }
      final builder = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.stream) {
        length += chunk.length;
        if (length > maxBytes) {
          client.close();
          throw const _ResponseTooLarge();
        }
        builder.add(chunk);
      }
      return RuleSourceHttpResponse(
        statusCode: response.statusCode,
        headers: headers,
        bytes: builder.takeBytes(),
      );
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          client.close();
          throw TimeoutException('HTTP request timed out', timeout);
        },
      );
    } finally {
      client.close();
    }
  }
}

class RuleSourceEngine {
  RuleSourceEngine(
    this.definition, {
    RuleSourceTransport? transport,
    this.limits = const RuleSourceLimits(),
  }) : transport = transport ?? const IoRuleSourceTransport() {
    limits.validate(definition.id);
  }

  final RuleSourceDefinition definition;
  final RuleSourceTransport transport;
  final RuleSourceLimits limits;

  Future<List<RuleSourceBook>> discover() async => (await discoverPage()).items;

  Future<RulePage<RuleSourceBook>> discoverPage({
    int page = 1,
    String? nextPageUrl,
  }) async {
    final rule = _requiredOperation(definition.discoverRule, '发现');
    if (page < 1) {
      throw RuleSourceSchemaException(definition.id, '发现页码必须大于 0。');
    }
    return _withinOperation((deadline) async {
      return _loadItemsPage(
        rule,
        {'page': '$page'},
        deadline,
        (root, item) => _book(rule, root, item, 'discover'),
        initialUrl:
            nextPageUrl == null
                ? null
                : _resolveSourceUrl(nextPageUrl, sameOrigin: true),
      );
    });
  }

  Future<RulePage<RuleSourceBook>> search(
    String query, {
    int page = 1,
    String? nextPageUrl,
  }) async {
    final rule = _requiredOperation(definition.searchRule, '搜索');
    if (page < 1) {
      throw RuleSourceSchemaException(definition.id, '搜索页码必须大于 0。');
    }
    return _withinOperation((deadline) async {
      return _loadItemsPage(
        rule,
        {'query': query, 'key': query, 'page': '$page'},
        deadline,
        (root, item) => _book(rule, root, item, 'search'),
        initialUrl:
            nextPageUrl == null
                ? null
                : _resolveSourceUrl(nextPageUrl, sameOrigin: true),
      );
    });
  }

  Future<RuleSourceDetail> detail(String bookUrl) async {
    final rule = _requiredOperation(definition.detailRule, '详情');
    return _withinOperation((deadline) async {
      final page = await _loadPage(rule, {
        'bookUrl': bookUrl,
        'id': bookUrl,
      }, deadline);
      return RuleSourceDetail(
        title: _fieldValue(
          rule.field('title'),
          _FieldContext(page, page.root),
          sourceId: definition.id,
        ),
        author: _fieldValue(
          rule.field('author'),
          _FieldContext(page, page.root),
          sourceId: definition.id,
        ),
        detailUrl: _checkedResultUrl(bookUrl),
        coverUrl: _optionalUrlField(
          rule.field('coverUrl'),
          _FieldContext(page, page.root),
        ),
        description: _fieldValue(
          rule.field('description'),
          _FieldContext(page, page.root),
          sourceId: definition.id,
        ),
        latestChapter: _fieldValue(
          rule.field('latestChapter'),
          _FieldContext(page, page.root),
          sourceId: definition.id,
        ),
        status: _fieldValue(
          rule.field('status'),
          _FieldContext(page, page.root),
          sourceId: definition.id,
        ),
        catalogUrl: _optionalUrlField(
          rule.field('catalogUrl'),
          _FieldContext(page, page.root),
        ),
      );
    });
  }

  Future<RuleCatalog> catalog(String tocUrl, {String? detailUrl}) async {
    final rule = _requiredOperation(definition.catalogRule, '目录');
    return _withinOperation((deadline) async {
      return _collectPages(
        rule,
        {
          'tocUrl': tocUrl,
          'bookUrl': detailUrl ?? tocUrl,
          'id': detailUrl ?? tocUrl,
          'page': '1',
        },
        deadline,
        (root, item) {
          final title = _requiredField(
            rule.field('title'),
            root,
            item,
            '目录章节标题',
          );
          final url = _resolveSourceUrl(
            _requiredField(rule.field('url'), root, item, '目录章节 URL'),
            base: root.finalUri,
            sameOrigin: true,
          );
          final id = _fieldValue(
            rule.field('id'),
            _FieldContext(root, item),
            sourceId: definition.id,
          );
          return RuleChapterRef(
            id: id.isEmpty ? url.toString() : id,
            title: title,
            url: url.toString(),
          );
        },
      ).then(
        (page) =>
            RuleCatalog(chapters: page.items, pagesFetched: page.pagesFetched),
      );
    });
  }

  Future<RuleSourceChapter> chapter(
    String chapterUrl, {
    String? detailUrl,
  }) async {
    final rule = _requiredOperation(definition.contentRule, '正文');
    return _withinOperation((deadline) async {
      final pages = <String>[];
      final images = <RuleSourceImage>[];
      final seen = <String>{};
      var current = _renderUrl(rule.urlTemplate, {
        'chapterUrl': chapterUrl,
        'bookUrl': detailUrl ?? chapterUrl,
        'id': chapterUrl,
        'page': '1',
      });
      var count = 0;
      while (true) {
        _checkDeadline(deadline);
        if (!seen.add(current.toString())) {
          throw RuleSourcePaginationException(definition.id, '正文分页链接循环。');
        }
        final page = await _loadPageAt(rule, current, deadline);
        final rawHtml = _requiredField(
          rule.field('content'),
          page,
          page.root,
          '正文内容',
        );
        final sanitized = _sanitizeContent(rawHtml, page.finalUri);
        pages.add(sanitized.html);
        images.addAll(sanitized.images);
        count++;
        final nextValue = _nextValue(rule, page);
        if (nextValue.isEmpty) break;
        if (count >= limits.maxPages) {
          throw RuleSourceLimitException(
            definition.id,
            '正文超过 ${limits.maxPages} 页分页上限。',
          );
        }
        current = _resolveSourceUrl(
          nextValue,
          base: page.finalUri,
          sameOrigin: true,
        );
      }
      final uniqueImages = <String, RuleSourceImage>{};
      for (final image in images) {
        uniqueImages.putIfAbsent(image.url, () => image);
      }
      return RuleSourceChapter(
        url: _checkedResultUrl(chapterUrl),
        contentHtml: pages.join('\n'),
        images: uniqueImages.values.toList(growable: false),
        pagesFetched: count,
      );
    });
  }

  Future<RulePage<T>> _collectPages<T>(
    RuleOperation rule,
    Map<String, String> values,
    DateTime deadline,
    T Function(_PageContext page, dynamic item) mapItem,
  ) async {
    final items = <T>[];
    final seen = <String>{};
    var current = _renderUrl(rule.urlTemplate, values);
    var count = 0;
    while (true) {
      _checkDeadline(deadline);
      if (!seen.add(current.toString())) {
        throw RuleSourcePaginationException(definition.id, '分页链接循环：$current');
      }
      final page = await _loadPageAt(rule, current, deadline);
      final roots = _select(rule.items!.selector, page);
      for (final item in roots) {
        items.add(mapItem(page, item));
      }
      count++;
      final nextValue = _nextValue(rule, page);
      if (nextValue.isEmpty) {
        return RulePage(items: items, pagesFetched: count, reachedEnd: true);
      }
      if (count >= limits.maxPages) {
        throw RuleSourceLimitException(
          definition.id,
          '分页超过 ${limits.maxPages} 页上限。',
        );
      }
      current = _resolveSourceUrl(
        nextValue,
        base: page.finalUri,
        sameOrigin: true,
      );
    }
  }

  Future<RulePage<T>> _loadItemsPage<T>(
    RuleOperation rule,
    Map<String, String> values,
    DateTime deadline,
    T Function(_PageContext page, dynamic item) mapItem, {
    Uri? initialUrl,
  }) async {
    _checkDeadline(deadline);
    final requested = initialUrl ?? _renderUrl(rule.urlTemplate, values);
    final page = await _loadPageAt(rule, requested, deadline);
    final items = [
      for (final item in _select(rule.items!.selector, page))
        mapItem(page, item),
    ];
    final nextValue = _nextValue(rule, page);
    final next =
        nextValue.isEmpty
            ? null
            : _resolveSourceUrl(
              nextValue,
              base: page.finalUri,
              sameOrigin: true,
            );
    if (next != null && next == page.finalUri) {
      throw RuleSourcePaginationException(definition.id, '分页链接循环：$next');
    }
    return RulePage(
      items: items,
      pagesFetched: 1,
      reachedEnd: next == null,
      nextPageUrl: next?.toString(),
    );
  }

  RuleSourceBook _book(
    RuleOperation rule,
    _PageContext page,
    dynamic item,
    String kind,
  ) {
    final context = _FieldContext(page, item);
    final title = _requiredField(rule.field('title'), page, item, '$kind 书名');
    final detailUrl = _requiredField(
      rule.field('detailUrl'),
      page,
      item,
      '$kind 详情链接',
    );
    final resolvedDetail =
        _resolveSourceUrl(
          detailUrl,
          base: page.finalUri,
          sameOrigin: true,
        ).toString();
    final id = _fieldValue(rule.field('id'), context, sourceId: definition.id);
    return RuleSourceBook(
      id: id.isEmpty ? resolvedDetail : id,
      title: title,
      author: _fieldValue(
        rule.field('author'),
        context,
        sourceId: definition.id,
      ),
      detailUrl: resolvedDetail,
      coverUrl: _optionalUrlField(rule.field('coverUrl'), context),
      description: _fieldValue(
        rule.field('description'),
        context,
        sourceId: definition.id,
      ),
      latestChapter: _fieldValue(
        rule.field('latestChapter'),
        context,
        sourceId: definition.id,
      ),
    );
  }

  Future<T> _withinOperation<T>(Future<T> Function(DateTime deadline) work) {
    final deadline = DateTime.now().add(limits.operationTimeout);
    return work(deadline).timeout(
      limits.operationTimeout,
      onTimeout:
          () => throw RuleSourceNetworkException(definition.id, '操作超过总时限。'),
    );
  }

  Future<_PageContext> _loadPage(
    RuleOperation rule,
    Map<String, String> values,
    DateTime deadline,
  ) => _loadPageAt(rule, _renderUrl(rule.urlTemplate, values), deadline);

  Future<_PageContext> _loadPageAt(
    RuleOperation rule,
    Uri uri,
    DateTime deadline,
  ) async {
    var current = _resolveSourceUrl(uri.toString(), sameOrigin: true);
    final redirected = <String>{current.toString()};
    for (var count = 0; ; count++) {
      _checkDeadline(deadline);
      final remaining = deadline.difference(DateTime.now());
      final timeout =
          remaining < limits.requestTimeout ? remaining : limits.requestTimeout;
      if (timeout <= Duration.zero) {
        throw RuleSourceNetworkException(definition.id, '请求超过总时限。');
      }
      RuleSourceHttpResponse response;
      try {
        response = await transport
            .get(current, timeout: timeout, maxBytes: limits.maxResponseBytes)
            .timeout(timeout);
      } on _ResponseTooLarge {
        throw RuleSourceLimitException(
          definition.id,
          '响应超过 ${limits.maxResponseBytes} 字节上限。',
        );
      } on TimeoutException {
        throw RuleSourceNetworkException(definition.id, '请求超时。');
      } on RuleSourceException {
        rethrow;
      } catch (error) {
        throw RuleSourceNetworkException(definition.id, '请求失败：$error');
      }
      if (response.bytes.length > limits.maxResponseBytes) {
        throw RuleSourceLimitException(
          definition.id,
          '响应超过 ${limits.maxResponseBytes} 字节上限。',
        );
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          throw RuleSourceNetworkException(
            definition.id,
            'HTTP 跳转缺少 Location。',
          );
        }
        if (count >= limits.maxRedirects) {
          throw RuleSourceLimitException(
            definition.id,
            'HTTP 跳转超过 ${limits.maxRedirects} 次上限。',
          );
        }
        current = _resolveSourceUrl(location, base: current, sameOrigin: true);
        if (!redirected.add(current.toString())) {
          throw RuleSourcePaginationException(definition.id, 'HTTP 跳转链接循环。');
        }
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RuleSourceNetworkException(
          definition.id,
          'HTTP ${response.statusCode}。',
        );
      }
      final text = await _decodeResponse(response);
      final jsonMode = _operationUsesJson(rule);
      dynamic root;
      if (jsonMode) {
        try {
          root = jsonDecode(text);
        } on FormatException catch (error) {
          throw RuleSourceExtractionException(
            definition.id,
            '响应不是有效 JSON：${error.message}',
          );
        }
      } else {
        root = html_parser.parse(text);
      }
      return _PageContext(root: root, finalUri: current);
    }
  }

  Future<String> _decodeResponse(RuleSourceHttpResponse response) async {
    final declared = _charsetFromContentType(response.headers['content-type']);
    final charset = declared ?? definition.charset;
    if (charset == 'utf-8' || charset == 'utf8') {
      return utf8.decode(response.bytes);
    }
    if (charset == 'gbk' || charset == 'gb2312' || charset == 'cp936') {
      return _decodeGbk(response.bytes);
    }
    throw RuleSourceUnsupportedException(
      definition.id,
      '响应字符集 "$charset" 不受支持。',
    );
  }

  Uri _renderUrl(String template, Map<String, String> values) {
    final exact = RegExp(
      r'^\{\{([A-Za-z][A-Za-z0-9]*)\}\}$',
    ).firstMatch(template.trim());
    if (exact != null && values.containsKey(exact.group(1))) {
      return _resolveSourceUrl(values[exact.group(1)]!, sameOrigin: true);
    }
    final rendered = template.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (
      match,
    ) {
      final token = match.group(1)!;
      final value = values[token];
      if (value == null) {
        throw RuleSourceSchemaException(definition.id, 'URL 模板缺少变量 $token。');
      }
      return Uri.encodeComponent(value);
    });
    return _resolveSourceUrl(rendered, sameOrigin: true);
  }

  Uri _resolveSourceUrl(String value, {Uri? base, required bool sameOrigin}) {
    if (value.trim().isEmpty) {
      throw RuleSourceExtractionException(definition.id, 'URL 为空。');
    }
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null) {
      throw RuleSourceExtractionException(definition.id, '发现无效 URL。');
    }
    var uri = (base ?? definition.baseUrl).resolveUri(parsed);
    // Some HTTPS sites still emit their own links with an HTTP scheme. Upgrade
    // those same-host default-port links; never downgrade a secure request.
    if (definition.baseUrl.scheme == 'https' &&
        uri.scheme == 'http' &&
        uri.host == definition.baseUrl.host &&
        uri.port == 80) {
      uri = uri.replace(scheme: 'https', port: definition.baseUrl.port);
    }
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        _isLocalHost(uri.host)) {
      throw RuleSourceUnsupportedException(
        definition.id,
        '拒绝非法或本机网络 URL：$value',
      );
    }
    if (sameOrigin && !_sameOrigin(uri, definition.baseUrl)) {
      throw RuleSourceUnsupportedException(
        definition.id,
        '拒绝访问书源站点以外的 URL：$value',
      );
    }
    return uri;
  }

  String _checkedResultUrl(String value) =>
      _resolveSourceUrl(value, sameOrigin: true).toString();

  String _optionalUrlField(RuleField? field, _FieldContext context) {
    final value = _fieldValue(field, context, sourceId: definition.id);
    if (value.isEmpty) return '';
    return _resolveSourceUrl(
      value,
      base: context.page.finalUri,
      sameOrigin: false,
    ).toString();
  }

  String _nextValue(RuleOperation rule, _PageContext page) {
    final field = rule.next;
    if (field == null) return '';
    return _fieldValue(
      field,
      _FieldContext(page, page.root),
      sourceId: definition.id,
    ).trim();
  }

  String _requiredField(
    RuleField? field,
    _PageContext page,
    dynamic item,
    String label,
  ) {
    final value =
        _fieldValue(
          field,
          _FieldContext(page, item),
          sourceId: definition.id,
        ).trim();
    if (value.isEmpty) {
      throw RuleSourceExtractionException(definition.id, '$label 未提取到内容。');
    }
    return value;
  }

  String _fieldValue(
    RuleField? field,
    _FieldContext context, {
    required String sourceId,
  }) => _extract(field, context, sourceId: sourceId);

  String _extract(
    RuleField? field,
    _FieldContext context, {
    required String sourceId,
  }) {
    if (field == null) return '';
    final nodes =
        _select(field.selector, context.page, context.item)
            .where(
              (node) =>
                  field.matchText == null ||
                  (node is dom.Element && node.text.trim() == field.matchText),
            )
            .toList();
    if (nodes.isEmpty) return '';
    final node = nodes.first;
    if (field.selector.kind == RuleSelectorKind.json) {
      if (field.kind == RuleValueKind.html) {
        return node is String ? node : jsonEncode(node);
      }
      if (node == null) return '';
      if (node is String || node is num || node is bool) return '$node'.trim();
      return jsonEncode(node);
    }
    final element = node as dom.Element;
    switch (field.kind) {
      case RuleValueKind.text:
        return element.text.trim();
      case RuleValueKind.html:
        return element.innerHtml.trim();
      case RuleValueKind.attribute:
        return element.attributes[field.attribute] ?? '';
    }
  }

  List<dynamic> _select(
    RuleSelector selector,
    _PageContext page, [
    dynamic item,
  ]) {
    if (selector.kind == RuleSelectorKind.json) {
      final target = item ?? page.root;
      return _selectJsonPath(target, selector.expression);
    }
    final target = item ?? page.root;
    if (selector.expression == ':scope') {
      if (target is dom.Element) return [target];
      if (target is dom.Document && target.documentElement != null) {
        return [target.documentElement!];
      }
      return const [];
    }
    if (target is dom.Document) {
      return target.querySelectorAll(selector.expression);
    }
    if (target is dom.Element) {
      return target.querySelectorAll(selector.expression);
    }
    return const [];
  }

  bool _operationUsesJson(RuleOperation rule) {
    final selectors = <RuleSelector>[
      if (rule.items != null) rule.items!.selector,
      ...rule.fields.values.map((field) => field.selector),
      if (rule.items != null)
        ...rule.items!.fields.values.map((field) => field.selector),
      if (rule.next != null) rule.next!.selector,
    ];
    return selectors.any((selector) => selector.kind == RuleSelectorKind.json);
  }

  void _checkDeadline(DateTime deadline) {
    if (!DateTime.now().isBefore(deadline)) {
      throw RuleSourceNetworkException(definition.id, '操作超过总时限。');
    }
  }

  RuleOperation _requiredOperation(RuleOperation? rule, String label) {
    if (rule == null) {
      throw RuleSourceUnsupportedException(definition.id, '该书源未声明$label能力。');
    }
    return rule;
  }
}

class _PageContext {
  const _PageContext({required this.root, required this.finalUri});
  final dynamic root;
  final Uri finalUri;
}

class _FieldContext {
  const _FieldContext(this.page, this.item);
  final _PageContext page;
  final dynamic item;
}

class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}

Future<String> _decodeGbk(Uint8List bytes) async {
  final table = await _gbkTable();
  final output = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    final lead = bytes[i];
    if (lead <= 0x7f) {
      output.writeCharCode(lead);
      continue;
    }
    if (lead < 0x81 || lead > 0xfe || i + 1 >= bytes.length) {
      throw const FormatException('GBK 响应包含无效字节。');
    }
    final trail = bytes[++i];
    if (trail < 0x40 || trail > 0xfe || trail == 0x7f) {
      throw const FormatException('GBK 响应包含无效双字节序列。');
    }
    final index = (lead - 0x81) * 191 + (trail - 0x40);
    final codePoint = table[index];
    if (codePoint == 0) {
      throw const FormatException('GBK 响应包含未映射字符。');
    }
    output.writeCharCode(codePoint);
  }
  return output.toString();
}

Future<Uint16List>? _cachedGbkTable;
Future<Uint16List> _gbkTable() => _cachedGbkTable ??= _loadGbkTable();

Future<Uint16List> _loadGbkTable() async {
  final bytes = await rootBundle.load(
    'lib/assets/encodings/gbk-to-unicode.bin',
  );
  const length = 126 * 191 * 2;
  if (bytes.lengthInBytes != length) {
    throw const FormatException('GBK 字符映射表损坏。');
  }
  final data = bytes.buffer.asByteData(
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  final table = Uint16List(126 * 191);
  for (var index = 0; index < table.length; index++) {
    table[index] = data.getUint16(index * 2, Endian.little);
  }
  return table;
}

String? _charsetFromContentType(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r"""charset\s*=\s*["']?([^;"'\s]+)""",
    caseSensitive: false,
  ).firstMatch(value);
  return match?.group(1)?.toLowerCase();
}

List<dynamic> _selectJsonPath(dynamic root, String expression) {
  var values = <dynamic>[root];
  final segments =
      RegExp(
        r'\.([A-Za-z_][A-Za-z0-9_-]*)|\[\*\]',
      ).allMatches(expression).toList();
  for (final segment in segments) {
    final key = segment.group(1);
    final next = <dynamic>[];
    for (final value in values) {
      if (key != null) {
        if (value is Map && value.containsKey(key)) next.add(value[key]);
      } else if (value is List) {
        next.addAll(value);
      }
    }
    values = next;
  }
  return values;
}

({String html, List<RuleSourceImage> images}) _sanitizeContent(
  String source,
  Uri documentUri,
) {
  final fragment = html_parser.parseFragment(source);
  for (final element
      in fragment
          .querySelectorAll(
            'script, iframe, object, embed, form, base, link, meta, style, svg, math',
          )
          .toList()) {
    element.remove();
  }
  final images = <RuleSourceImage>[];
  for (final element in fragment.querySelectorAll('*')) {
    for (final attribute in element.attributes.keys.toList()) {
      final name = attribute.toString().toLowerCase();
      if (name.startsWith('on') || name == 'style') {
        element.attributes.remove(attribute);
      }
    }
    for (final attribute in const ['href', 'src', 'data-src']) {
      final value = element.attributes[attribute];
      if (value == null || value.trim().isEmpty) continue;
      final uri = _publicUri(value, documentUri);
      if (uri == null) {
        element.attributes.remove(attribute);
      } else {
        element.attributes[attribute] = uri.toString();
      }
    }
    if (element.localName == 'img') {
      final sourceUrl =
          element.attributes['src'] ?? element.attributes['data-src'];
      if (sourceUrl == null) {
        element.attributes.remove('srcset');
        continue;
      }
      element.attributes['src'] = sourceUrl;
      element.attributes.remove('data-src');
      element.attributes.remove('srcset');
      images.add(
        RuleSourceImage(url: sourceUrl, alt: element.attributes['alt'] ?? ''),
      );
    }
  }
  return (html: fragment.outerHtml, images: images);
}

Uri? _publicUri(String value, Uri base) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) return null;
  final uri = base.resolveUri(parsed);
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      _isLocalHost(uri.host)) {
    return null;
  }
  return uri;
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

bool _isLocalHost(String host) {
  final normalized = host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (normalized == 'localhost' ||
      normalized.endsWith('.localhost') ||
      normalized.endsWith('.local') ||
      normalized.endsWith('.internal')) {
    return true;
  }
  final parts = normalized.split('.');
  if (parts.length == 4 && parts.every((part) => int.tryParse(part) != null)) {
    final a = int.parse(parts[0]);
    final b = int.parse(parts[1]);
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        a >= 224;
  }
  return normalized.contains(':') &&
      (normalized == '::' ||
          normalized == '::1' ||
          normalized.startsWith('fc') ||
          normalized.startsWith('fd') ||
          normalized.startsWith('fe80:') ||
          normalized.startsWith('::ffff:127.') ||
          normalized.startsWith('::ffff:10.') ||
          normalized.startsWith('::ffff:192.168.'));
}
