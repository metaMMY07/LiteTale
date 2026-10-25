import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

import 'rule_source_models.dart';
import 'legado_compatibility.dart';

const _schemaName = 'litetale-rule-source';
const _schemaVersion = 1;

/// Validated, immutable source description. Rules are data and never evaluated
/// as code. Only GET requests and the CSS/JSON selector subsets below exist.
class RuleSourceDefinition {
  const RuleSourceDefinition._({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.version,
    required this.charset,
    required this.discoverRule,
    required this.searchRule,
    required this.detailRule,
    required this.catalogRule,
    required this.contentRule,
    this.userAgent,
    this.cookieJar = false,
    this.importKey,
  });

  final String id;
  final String name;
  final Uri baseUrl;
  final String version;
  final String charset;
  final RuleOperation? discoverRule;
  final RuleOperation? searchRule;
  final RuleOperation? detailRule;
  final RuleOperation? catalogRule;
  final RuleOperation? contentRule;
  final String? userAgent;
  final bool cookieJar;
  final String? importKey;

  RuleSourceCapabilities get capabilities {
    final cover = [
      discoverRule,
      searchRule,
      detailRule,
    ].whereType<RuleOperation>().any((rule) => rule.hasField('coverUrl'));
    return RuleSourceCapabilities(
      discover: discoverRule != null,
      search: searchRule != null,
      detail: detailRule != null,
      catalog: catalogRule != null,
      content: contentRule != null,
      cover: cover,
      images: contentRule?.field('content')?.kind == RuleValueKind.html,
    );
  }

  /// Serializes a validated source in the canonical LiteTale JSON format.
  /// Optional identity overrides support renaming and saving a duplicate under
  /// a new stable id without changing any extraction rules.
  Map<String, dynamic> toJson({String? id, String? name, String? version}) {
    final savedId = id ?? this.id;
    final savedName = name ?? this.name;
    final savedVersion = version ?? this.version;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(savedId)) {
      throw RuleSourceSchemaException(savedId, 'source.id 格式无效。');
    }
    if (savedName.trim().isEmpty || savedVersion.trim().isEmpty) {
      throw RuleSourceSchemaException(savedId, '书源名称和版本不能为空。');
    }
    return {
      'schema': _schemaName,
      'schemaVersion': _schemaVersion,
      'source': {
        'id': savedId,
        'name': savedName,
        'baseUrl': baseUrl.toString(),
        'version': savedVersion,
        'charset': charset,
        if (userAgent != null) 'userAgent': userAgent,
        if (cookieJar) 'cookieJar': true,
        if (importKey != null) 'importKey': importKey,
      },
      'rules': {
        if (discoverRule != null) 'discover': _operationToJson(discoverRule!),
        if (searchRule != null) 'search': _operationToJson(searchRule!),
        if (detailRule != null) 'detail': _operationToJson(detailRule!),
        if (catalogRule != null) 'catalog': _operationToJson(catalogRule!),
        if (contentRule != null) 'content': _operationToJson(contentRule!),
      },
    };
  }

  RuleSourceDefinition withIdentity({String? id, String? name}) {
    final savedId = id ?? this.id;
    final savedName = name ?? this.name;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(savedId)) {
      throw RuleSourceSchemaException(savedId, 'source.id 格式无效。');
    }
    if (savedName.trim().isEmpty) {
      throw RuleSourceSchemaException(savedId, '书源名称不能为空。');
    }
    return RuleSourceDefinition._(
      id: savedId,
      name: savedName.trim(),
      baseUrl: baseUrl,
      version: version,
      charset: charset,
      discoverRule: discoverRule,
      searchRule: searchRule,
      detailRule: detailRule,
      catalogRule: catalogRule,
      contentRule: contentRule,
      userAgent: userAgent,
      cookieJar: cookieJar,
      importKey: importKey,
    );
  }

  factory RuleSourceDefinition.fromJson(Map<String, dynamic> json) {
    final schema = json['schema'];
    final sourceId = _sourceIdFrom(json);
    if (schema != _schemaName) {
      throw RuleSourceSchemaException(sourceId, 'schema 必须是 "$_schemaName"。');
    }
    final version = json['schemaVersion'];
    if (version != _schemaVersion) {
      throw RuleSourceUnsupportedException(
        sourceId,
        '不支持 schemaVersion=$version，只支持 $_schemaVersion。',
      );
    }
    _onlyKeys(json, const {
      'schema',
      'schemaVersion',
      'source',
      'rules',
    }, '根对象');
    final source = _asMap(json['source'], 'source');
    _onlyKeys(source, const {
      'id',
      'name',
      'baseUrl',
      'version',
      'charset',
      'userAgent',
      'cookieJar',
      'importKey',
    }, 'source');
    final id = _requiredString(source, 'id', 'source');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(id)) {
      throw RuleSourceSchemaException(id, 'source.id 格式无效。');
    }
    final name = _requiredString(source, 'name', 'source');
    final sourceVersion = _requiredString(source, 'version', 'source');
    final baseUrlText = _requiredString(source, 'baseUrl', 'source');
    final baseUrl = _parseBaseUrl(id, baseUrlText);
    final userAgent = source['userAgent'];
    if (userAgent != null &&
        (userAgent is! String ||
            userAgent.isEmpty ||
            userAgent.length > 1024 ||
            userAgent.codeUnits.any((c) => c < 32 || c > 126))) {
      throw RuleSourceSchemaException(id, 'source.userAgent 必须是有效的静态请求头。');
    }
    final cookieJar = source['cookieJar'];
    if (cookieJar != null && cookieJar is! bool) {
      throw RuleSourceSchemaException(id, 'source.cookieJar 必须是布尔值。');
    }
    final importKey = source['importKey'];
    if (importKey != null) {
      if (importKey is! String || importKey.length > 2048) {
        throw RuleSourceSchemaException(id, 'source.importKey 无效。');
      }
      final importUri = _parseBaseUrl(id, importKey);
      if (importUri.origin != baseUrl.origin) {
        throw RuleSourceSchemaException(id, '书源导入身份必须与站点同源。');
      }
    }
    final rawCharset = source['charset'];
    if (rawCharset != null && rawCharset is! String) {
      throw RuleSourceSchemaException(id, 'source.charset 必须是字符串。');
    }
    final charset = (rawCharset as String? ?? 'utf-8').toLowerCase();
    if (charset != 'utf-8' && charset != 'utf8' && charset != 'gbk') {
      throw RuleSourceUnsupportedException(
        id,
        '字符集 "$charset" 不受支持，仅支持 UTF-8 和 GBK。',
      );
    }
    final rules = _asMap(json['rules'], 'rules');
    _onlyKeys(rules, const {
      'discover',
      'search',
      'detail',
      'catalog',
      'content',
    }, 'rules');
    if (rules.isEmpty) {
      throw RuleSourceSchemaException(id, 'rules 至少需要声明一项能力规则。');
    }
    return RuleSourceDefinition._(
      id: id,
      name: name,
      baseUrl: baseUrl,
      version: sourceVersion,
      charset: charset == 'utf8' ? 'utf-8' : charset,
      discoverRule: _optionalOperation(id, 'discover', rules['discover']),
      searchRule: _optionalOperation(id, 'search', rules['search']),
      detailRule: _optionalOperation(id, 'detail', rules['detail']),
      catalogRule: _optionalOperation(id, 'catalog', rules['catalog']),
      contentRule: _optionalOperation(id, 'content', rules['content']),
      userAgent: userAgent as String?,
      cookieJar: cookieJar == true,
      importKey: importKey as String?,
    );
  }

  /// Converts the explicitly supported part of a Reading/Legado JSON source.
  /// Login, arbitrary headers, JS, XPath, selector pipelines and encryption
  /// rules are refused so conversion cannot silently produce empty results.
  factory RuleSourceDefinition.fromLegadoJson(Map<String, dynamic> legado) {
    _rejectLegadoExecutableOrCredentialFeatures(legado);
    final rawBase = legado['bookSourceUrl'];
    if (rawBase is! String || rawBase.trim().isEmpty) {
      throw const RuleSourceUnsupportedException(
        'legado',
        '缺少 bookSourceUrl，无法确定来源域名。',
      );
    }
    final rawName = legado['bookSourceName'];
    final sourceUri = _parseBaseUrl('legado', rawBase);
    final idValue = legado['id'];
    final explicitId =
        idValue is String && idValue.trim().isNotEmpty ? idValue.trim() : null;
    // This provisional value is only used in actionable conversion errors.
    // The stable default identity is computed below from the converted rules.
    final id =
        explicitId ??
        'legado_${sha256.convert(utf8.encode('${sourceUri.origin}|${rawName is String ? rawName.trim() : ''}')).toString().substring(0, 16)}';
    final name =
        rawName is String && rawName.trim().isNotEmpty
            ? rawName.trim()
            : sourceUri.host;
    final legadoCharset = legado['charset'];
    final sourceCharset =
        legadoCharset is String ? legadoCharset.toLowerCase() : null;

    Map<String, dynamic>? explore;
    final exploreUrl = legado['exploreUrl'];
    final exploreRule = legado['ruleExplore'];
    if (exploreUrl != null || exploreRule != null) {
      if (exploreUrl is! String ||
          exploreUrl.trim().isEmpty ||
          exploreRule is! Map) {
        throw RuleSourceUnsupportedException(
          id,
          'Legado discovery 需要同时提供 exploreUrl 和 ruleExplore。',
        );
      }
      explore = _convertLegadoListOperation(
        'discover',
        exploreUrl,
        Map<String, dynamic>.from(exploreRule),
        listKey: 'bookList',
        fieldMap: const {
          'id': 'bookUrl',
          'title': 'name',
          'detailUrl': 'bookUrl',
          'author': 'author',
          'coverUrl': 'coverUrl',
          'description': 'intro',
          'latestChapter': 'lastChapter',
        },
      );
    }

    final searchUrl = legado['searchUrl'];
    final ruleSearch = legado['ruleSearch'];
    Map<String, dynamic>? search;
    if (searchUrl != null || ruleSearch != null) {
      if (searchUrl is! String ||
          searchUrl.trim().isEmpty ||
          ruleSearch is! Map) {
        throw RuleSourceUnsupportedException(
          id,
          'Legado search 需要同时提供 searchUrl 和 ruleSearch。',
        );
      }
      search = _convertLegadoListOperation(
        'search',
        searchUrl,
        Map<String, dynamic>.from(ruleSearch),
        listKey: 'bookList',
        fieldMap: const {
          'id': 'bookUrl',
          'title': 'name',
          'author': 'author',
          'detailUrl': 'bookUrl',
          'coverUrl': 'coverUrl',
          'description': 'intro',
          'latestChapter': 'lastChapter',
        },
      );
    }
    if (search == null && explore == null) {
      throw RuleSourceUnsupportedException(
        id,
        'Legado 转换至少需要一组完整的 discovery 或 search 规则。',
      );
    }
    final ruleBookInfo = _legadoRuleMap(
      legado['ruleBookInfo'],
      id,
      'ruleBookInfo',
    );
    _onlyLegadoRuleKeys(id, ruleBookInfo, const {
      'name',
      'author',
      'coverUrl',
      'intro',
      'lastChapter',
      'kind',
      'tocUrl',
    }, 'ruleBookInfo');
    _requireStringRuleValues(ruleBookInfo, id, 'ruleBookInfo');
    final detail = <String, dynamic>{
      'url': '{{bookUrl}}',
      'fields': <String, dynamic>{
        for (final pair
            in const {
              'title': 'name',
              'author': 'author',
              'coverUrl': 'coverUrl',
              'description': 'intro',
              'latestChapter': 'lastChapter',
              'status': 'kind',
              'catalogUrl': 'tocUrl',
            }.entries)
          if (ruleBookInfo[pair.value] is String &&
              (ruleBookInfo[pair.value] as String).trim().isNotEmpty)
            pair.key: _legadoField(ruleBookInfo[pair.value] as String),
      },
    };
    final ruleToc = _legadoRuleMap(legado['ruleToc'], id, 'ruleToc');
    _onlyLegadoRuleKeys(id, ruleToc, const {
      'chapterList',
      'chapterName',
      'chapterUrl',
    }, 'ruleToc');
    _requireStringRuleValues(ruleToc, id, 'ruleToc');
    Map<String, dynamic>? catalog;
    if (ruleToc.isNotEmpty &&
        !const {
          'chapterList',
          'chapterName',
          'chapterUrl',
        }.every(ruleToc.containsKey)) {
      throw RuleSourceUnsupportedException(
        id,
        'Legado ruleToc 必须同时提供 chapterList、chapterName 和 chapterUrl。',
      );
    }
    if ((ruleToc['chapterList'] is String) &&
        (ruleToc['chapterName'] is String) &&
        (ruleToc['chapterUrl'] is String)) {
      catalog = {
        'url': '{{tocUrl}}',
        'items': {
          'selector': _legadoSelector(ruleToc['chapterList'] as String),
          'fields': {
            'id': _legadoField(ruleToc['chapterUrl'] as String),
            'title': _legadoField(ruleToc['chapterName'] as String),
            'url': _legadoField(ruleToc['chapterUrl'] as String),
          },
        },
      };
    }
    final ruleContent = _legadoRuleMap(
      legado['ruleContent'],
      id,
      'ruleContent',
    );
    _onlyLegadoRuleKeys(id, ruleContent, const {'content'}, 'ruleContent');
    _requireStringRuleValues(ruleContent, id, 'ruleContent');
    if (ruleContent.isNotEmpty && !ruleContent.containsKey('content')) {
      throw RuleSourceUnsupportedException(
        id,
        'Legado ruleContent 必须提供 content。',
      );
    }
    Map<String, dynamic>? content;
    if (ruleContent['content'] is String &&
        (ruleContent['content'] as String).trim().isNotEmpty) {
      content = {
        'url': '{{chapterUrl}}',
        'fields': {'content': _legadoField(ruleContent['content'] as String)},
      };
    }
    final convertedRules = <String, dynamic>{
      if (explore != null) 'discover': explore,
      if (search != null) 'search': search,
      'detail': detail,
      if (catalog != null) 'catalog': catalog,
      if (content != null) 'content': content,
    };
    final stableId =
        explicitId ??
        'legado_${sha256.convert(utf8.encode('${sourceUri.origin}|$name|${_canonicalJson(convertedRules)}')).toString().substring(0, 16)}';
    final converted = <String, dynamic>{
      'schema': _schemaName,
      'schemaVersion': _schemaVersion,
      'source': {
        'id': stableId,
        'name': name,
        'baseUrl': sourceUri.toString(),
        'version': (legado['bookSourceVersion'] ?? 'legado-unknown').toString(),
        if (sourceCharset != null) 'charset': sourceCharset,
      },
      'rules': convertedRules,
    };
    return RuleSourceDefinition.fromJson(converted);
  }
}

class RuleOperation {
  const RuleOperation({
    required this.urlTemplate,
    required this.fields,
    this.items,
    this.next,
  });

  final String urlTemplate;
  final RuleItemSet? items;
  final Map<String, RuleField> fields;
  final RuleField? next;

  RuleField? field(String name) => fields[name] ?? items?.fields[name];
  bool hasField(String name) => field(name) != null;
}

Map<String, dynamic> _operationToJson(RuleOperation operation) => {
  'url': operation.urlTemplate,
  if (operation.items != null)
    'items': {
      'selector': _selectorToJson(operation.items!.selector),
      'fields': {
        for (final entry in operation.items!.fields.entries)
          entry.key: _fieldToJson(entry.value),
      },
    }
  else
    'fields': {
      for (final entry in operation.fields.entries)
        entry.key: _fieldToJson(entry.value),
    },
  if (operation.next != null)
    'pagination': {'next': _fieldToJson(operation.next!)},
};

Map<String, dynamic> _fieldToJson(RuleField field) => {
  'selector': _selectorToJson(field.selector),
  'value': switch (field.kind) {
    RuleValueKind.text => 'text',
    RuleValueKind.html => 'html',
    RuleValueKind.attribute => 'attr',
  },
  if (field.attribute != null) 'attribute': field.attribute,
  if (field.matchText != null) 'matchText': field.matchText,
  if (field.legado != null) 'legado': field.legado!.expression,
  if (field.asUrl) 'asUrl': true,
};

String _selectorToJson(RuleSelector selector) =>
    '${selector.kind.name}:${selector.expression}';

class RuleItemSet {
  const RuleItemSet({required this.selector, required this.fields});
  final RuleSelector selector;
  final Map<String, RuleField> fields;
}

class RuleField {
  const RuleField({
    required this.selector,
    required this.kind,
    this.attribute,
    this.matchText,
    this.legado,
    this.asUrl = false,
  });

  final RuleSelector selector;
  final RuleValueKind kind;
  final String? attribute;
  final String? matchText;
  final LegadoTextRule? legado;
  final bool asUrl;
}

enum RuleValueKind { text, html, attribute }

class RuleSelector {
  const RuleSelector._(this.kind, this.expression, [this.legado]);

  final RuleSelectorKind kind;
  final String expression;
  final LegadoSelector? legado;

  factory RuleSelector.parse(String input, String sourceId, String where) {
    final value = input.trim();
    if (value.startsWith('legado:')) {
      final expression = value.substring(7).trim();
      return RuleSelector._(
        RuleSelectorKind.legado,
        expression,
        LegadoSelector.parse(expression),
      );
    }
    if (value.startsWith('css:')) {
      final css = value.substring(4).trim();
      if (css.isEmpty) {
        throw RuleSourceSchemaException(sourceId, '$where 的 CSS 选择器为空。');
      }
      try {
        if (css != ':scope') {
          html_parser.parseFragment('').querySelectorAll(css);
        }
      } catch (error) {
        throw RuleSourceSchemaException(sourceId, '$where 的 CSS 选择器无效：$error');
      }
      return RuleSelector._(RuleSelectorKind.css, css);
    }
    if (value.startsWith('json:')) {
      final path = value.substring(5).trim();
      if (!RegExp(
        r'^\$(?:\.[A-Za-z_][A-Za-z0-9_-]*|\[\*\])*$',
      ).hasMatch(path)) {
        throw RuleSourceUnsupportedException(
          sourceId,
          '$where 仅支持 JSONPath \$.a.b 和 \$.a.b[*]。',
        );
      }
      return RuleSelector._(RuleSelectorKind.json, path);
    }
    if (value.startsWith('xpath:') || value.startsWith('//')) {
      throw RuleSourceUnsupportedException(sourceId, '$where 使用了不支持的 XPath。');
    }
    if (value.startsWith('@js:') ||
        value.startsWith('js:') ||
        value.contains('{{@')) {
      throw RuleSourceUnsupportedException(sourceId, '$where 使用了不支持的脚本规则。');
    }
    throw RuleSourceSchemaException(sourceId, '$where 必须以 css: 或 json: 开头。');
  }
}

enum RuleSelectorKind { css, json, legado }

class RuleSourceValidation {
  const RuleSourceValidation.success(this.index, this.definition)
    : error = null;
  const RuleSourceValidation.failure(this.index, this.error)
    : definition = null;

  final int index;
  final RuleSourceDefinition? definition;
  final String? error;
  bool get isSuccess => definition != null;
}

/// Parses one source or a JSON list. Each list member is validated separately;
/// one damaged entry does not hide usable neighbors. Duplicate ids fail later
/// entries explicitly.
List<RuleSourceValidation> validateRuleSourceBatch(String jsonText) {
  dynamic decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (error) {
    return [RuleSourceValidation.failure(0, 'JSON 格式错误：${error.message}')];
  }
  final entries = decoded is List ? decoded : <dynamic>[decoded];
  final seenIds = <String>{};
  return [
    for (var index = 0; index < entries.length; index++)
      _validateBatchEntry(index, entries[index], seenIds),
  ];
}

/// Alias named for the import flow, returning one success/error record per
/// source member while preserving the index for UI presentation.
List<RuleSourceValidation> parseRuleSourceImport(String jsonText) =>
    validateRuleSourceBatch(jsonText);

RuleSourceValidation _validateBatchEntry(
  int index,
  dynamic entry,
  Set<String> seenIds,
) {
  try {
    if (entry is! Map) {
      throw const RuleSourceSchemaException('unknown', '每个书源必须是 JSON 对象。');
    }
    final map = Map<String, dynamic>.from(entry);
    final definition =
        map.containsKey('schema')
            ? RuleSourceDefinition.fromJson(map)
            : RuleSourceDefinition.fromLegadoJson(map);
    if (!seenIds.add(definition.id)) {
      throw RuleSourceSchemaException(definition.id, '同一批文件中 source.id 重复。');
    }
    return RuleSourceValidation.success(index, definition);
  } on RuleSourceException catch (error) {
    return RuleSourceValidation.failure(index, error.toString());
  } on FormatException catch (error) {
    return RuleSourceValidation.failure(index, '格式错误：${error.message}');
  } catch (error) {
    return RuleSourceValidation.failure(index, '无法验证：$error');
  }
}

RuleOperation? _optionalOperation(String sourceId, String name, dynamic raw) {
  if (raw == null) return null;
  final operation = _asMap(raw, 'rules.$name');
  _onlyKeys(operation, const {
    'url',
    'items',
    'fields',
    'pagination',
  }, 'rules.$name');
  final url = _requiredString(operation, 'url', 'rules.$name');
  _validateTemplate(sourceId, url, 'rules.$name.url');
  final itemsRaw = operation['items'];
  RuleItemSet? items;
  Map<String, RuleField> fields = const {};
  if (itemsRaw != null) {
    if (operation.containsKey('fields')) {
      throw RuleSourceSchemaException(
        sourceId,
        'rules.$name 不能同时使用顶层 fields 和 items.fields。',
      );
    }
    final itemMap = _asMap(itemsRaw, 'rules.$name.items');
    _onlyKeys(itemMap, const {'selector', 'fields'}, 'rules.$name.items');
    final selector = RuleSelector.parse(
      _requiredString(itemMap, 'selector', 'rules.$name.items'),
      sourceId,
      'rules.$name.items.selector',
    );
    final fieldMap = _asMap(itemMap['fields'], 'rules.$name.items.fields');
    _validateFieldNames(sourceId, name, fieldMap);
    items = RuleItemSet(
      selector: selector,
      fields: _parseFields(sourceId, fieldMap, 'rules.$name.items.fields'),
    );
  } else {
    final fieldMap = _asMap(operation['fields'], 'rules.$name.fields');
    _validateFieldNames(sourceId, name, fieldMap);
    fields = _parseFields(sourceId, fieldMap, 'rules.$name.fields');
  }
  final pagination = operation['pagination'];
  RuleField? next;
  if (pagination != null) {
    final paginationMap = _asMap(pagination, 'rules.$name.pagination');
    _onlyKeys(paginationMap, const {'next'}, 'rules.$name.pagination');
    if (paginationMap['next'] != null) {
      next = _parseField(
        sourceId,
        paginationMap['next'],
        'rules.$name.pagination.next',
      );
    }
  }
  if (items == null && fields.isEmpty) {
    throw RuleSourceSchemaException(sourceId, 'rules.$name 没有可抽取字段。');
  }
  if (items != null && items.fields.isEmpty) {
    throw RuleSourceSchemaException(sourceId, 'rules.$name.items.fields 不能为空。');
  }
  if (name == 'discover' || name == 'search' || name == 'catalog') {
    if (items == null) {
      throw RuleSourceSchemaException(sourceId, 'rules.$name 必须定义 items。');
    }
    final requiredFields =
        name == 'catalog'
            ? const {'title', 'url'}
            : const {'title', 'detailUrl'};
    for (final required in requiredFields) {
      if (!items.fields.containsKey(required)) {
        throw RuleSourceSchemaException(
          sourceId,
          'rules.$name.items.fields 缺少 $required。',
        );
      }
    }
  }
  if ((name == 'detail' || name == 'content') && items != null) {
    throw RuleSourceSchemaException(sourceId, 'rules.$name 不支持 items。');
  }
  if (name == 'content' && !fields.containsKey('content')) {
    throw RuleSourceSchemaException(
      sourceId,
      'rules.content.fields 缺少 content。',
    );
  }
  final selectorKinds = <RuleSelectorKind>{
    if (items != null) items.selector.kind,
    ...fields.values.map((field) => field.selector.kind),
    if (items != null)
      ...items.fields.values.map((field) => field.selector.kind),
    if (next != null) next.selector.kind,
  };
  final responseKinds =
      selectorKinds
          .map(
            (kind) =>
                kind == RuleSelectorKind.legado ? RuleSelectorKind.css : kind,
          )
          .toSet();
  if (responseKinds.length > 1) {
    throw RuleSourceUnsupportedException(
      sourceId,
      'rules.$name 不能混用 HTML/CSS 与 JSON 响应规则。',
    );
  }
  if (name == 'search' &&
      !url.contains('{{query}}') &&
      !url.contains('{{key}}')) {
    throw RuleSourceUnsupportedException(
      sourceId,
      'rules.search.url 必须包含 {{query}} 搜索词变量。',
    );
  }
  if (name == 'detail' && operation['pagination'] != null) {
    throw RuleSourceUnsupportedException(sourceId, 'rules.detail 不支持分页规则。');
  }
  return RuleOperation(
    urlTemplate: url,
    fields: fields,
    items: items,
    next: next,
  );
}

Map<String, RuleField> _parseFields(
  String sourceId,
  Map<String, dynamic> raw,
  String where,
) => Map.unmodifiable({
  for (final entry in raw.entries)
    entry.key: _parseField(sourceId, entry.value, '$where.${entry.key}'),
});

RuleField _parseField(String sourceId, dynamic raw, String where) {
  final map = _asMap(raw, where);
  _onlyKeys(map, const {
    'selector',
    'value',
    'attribute',
    'matchText',
    'legado',
    'asUrl',
  }, where);
  final selector = RuleSelector.parse(
    _requiredString(map, 'selector', where),
    sourceId,
    '$where.selector',
  );
  final value = _requiredString(map, 'value', where);
  final kind = switch (value) {
    'text' => RuleValueKind.text,
    'html' => RuleValueKind.html,
    'attr' => RuleValueKind.attribute,
    _ =>
      throw RuleSourceUnsupportedException(
        sourceId,
        '$where.value "$value" 不受支持，仅支持 text、html、attr。',
      ),
  };
  final attribute = map['attribute'];
  if (kind == RuleValueKind.attribute) {
    if (attribute is! String ||
        !RegExp(r'^[A-Za-z_:][A-Za-z0-9_.:-]{0,63}$').hasMatch(attribute)) {
      throw RuleSourceSchemaException(sourceId, '$where.attribute 无效。');
    }
  } else if (attribute != null) {
    throw RuleSourceSchemaException(sourceId, '$where.attribute 仅适用于 attr。');
  }
  if (selector.kind == RuleSelectorKind.json &&
      kind == RuleValueKind.attribute) {
    throw RuleSourceUnsupportedException(sourceId, '$where JSON 字段不支持 attr。');
  }
  final matchText = map['matchText'];
  if (matchText != null &&
      (matchText is! String ||
          matchText.trim().isEmpty ||
          matchText.length > 100 ||
          selector.kind != RuleSelectorKind.css)) {
    throw RuleSourceSchemaException(
      sourceId,
      '$where.matchText 必须是 1–100 字符的 CSS 文本过滤条件。',
    );
  }
  final legado = map['legado'];
  final asUrl = map['asUrl'];
  if (legado != null &&
      (legado is! String ||
          selector.kind != RuleSelectorKind.css ||
          matchText != null)) {
    throw RuleSourceSchemaException(sourceId, '$where.legado 必须是 HTML 字段规则。');
  }
  if (asUrl != null && asUrl is! bool) {
    throw RuleSourceSchemaException(sourceId, '$where.asUrl 必须是布尔值。');
  }
  return RuleField(
    selector: selector,
    kind: kind,
    attribute: attribute as String?,
    matchText: matchText as String?,
    legado: legado is String ? LegadoTextRule.parse(legado) : null,
    asUrl: asUrl == true,
  );
}

void _validateFieldNames(
  String sourceId,
  String operation,
  Map<String, dynamic> fields,
) {
  const allowed = {
    'discover': {
      'id',
      'title',
      'author',
      'detailUrl',
      'coverUrl',
      'description',
      'latestChapter',
    },
    'search': {
      'id',
      'title',
      'author',
      'detailUrl',
      'coverUrl',
      'description',
      'latestChapter',
    },
    'detail': {
      'title',
      'author',
      'coverUrl',
      'description',
      'latestChapter',
      'status',
      'catalogUrl',
    },
    'catalog': {'id', 'title', 'url'},
    'content': {'content'},
  };
  for (final key in fields.keys) {
    if (!allowed[operation]!.contains(key)) {
      throw RuleSourceUnsupportedException(
        sourceId,
        'rules.$operation 不支持字段 "$key"。',
      );
    }
  }
}

String _requiredString(Map<String, dynamic> map, String key, String where) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw RuleSourceSchemaException('unknown', '$where.$key 必须是非空字符串。');
  }
  return value.trim();
}

Map<String, dynamic> _asMap(dynamic value, String where) {
  if (value is! Map) {
    throw RuleSourceSchemaException('unknown', '$where 必须是对象。');
  }
  try {
    return Map<String, dynamic>.from(value);
  } on TypeError {
    throw RuleSourceSchemaException('unknown', '$where 的键必须是字符串。');
  }
}

Map<String, dynamic> _legadoRuleMap(
  dynamic value,
  String sourceId,
  String where,
) {
  if (value == null) return <String, dynamic>{};
  if (value is! Map) {
    throw RuleSourceUnsupportedException(sourceId, '$where 必须是由简单规则字符串组成的对象。');
  }
  return Map<String, dynamic>.from(value);
}

void _requireStringRuleValues(
  Map<String, dynamic> rules,
  String sourceId,
  String where,
) {
  for (final entry in rules.entries) {
    if (entry.value is! String) {
      throw RuleSourceUnsupportedException(
        sourceId,
        '$where.${entry.key} 必须是简单 CSS/JSON 规则字符串。',
      );
    }
  }
}

void _onlyKeys(Map<String, dynamic> map, Set<String> allowed, String where) {
  final unknown = map.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw RuleSourceSchemaException(
      'unknown',
      '$where 包含未支持字段：${unknown.join(', ')}。',
    );
  }
}

String _sourceIdFrom(Map<String, dynamic> json) {
  final source = json['source'];
  if (source is Map && source['id'] is String) return source['id'] as String;
  if (json['bookSourceUrl'] is String) return 'legado';
  return 'unknown';
}

Uri _parseBaseUrl(String sourceId, String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw RuleSourceSchemaException(
      sourceId,
      'baseUrl 必须是无凭据、无查询参数的 HTTP(S) 站点根地址。',
    );
  }
  final normalized = uri.replace(path: uri.path.isEmpty ? '/' : uri.path);
  if (_isLocalOrPrivateHost(normalized.host)) {
    throw RuleSourceUnsupportedException(sourceId, 'baseUrl 不允许指向本机或私有网络地址。');
  }
  return normalized;
}

bool _isLocalOrPrivateHost(String host) {
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
  if (normalized.contains(':')) {
    return normalized == '::1' ||
        normalized == '::' ||
        normalized.startsWith('fc') ||
        normalized.startsWith('fd') ||
        normalized.startsWith('fe80:') ||
        normalized.startsWith('::ffff:127.') ||
        normalized.startsWith('::ffff:10.') ||
        normalized.startsWith('::ffff:192.168.');
  }
  return false;
}

void _validateTemplate(String sourceId, String template, String where) {
  const tokens = {
    'query',
    'page',
    'bookUrl',
    'tocUrl',
    'chapterUrl',
    'id',
    'key',
  };
  final matches = RegExp(r'\{\{([^{}]+)\}\}').allMatches(template).toList();
  for (final match in matches) {
    final token = match.group(1)!;
    if (!tokens.contains(token)) {
      throw RuleSourceUnsupportedException(
        sourceId,
        '$where 使用了未知 URL 变量 "{{$token}}"。',
      );
    }
  }
  final stripped = template.replaceAll(RegExp(r'\{\{[^{}]+\}\}'), 'x');
  if (RegExp(r'[{}]').hasMatch(stripped)) {
    throw RuleSourceUnsupportedException(sourceId, '$where 的 URL 模板语法无效。');
  }
  final uri = Uri.tryParse(stripped);
  if (uri == null ||
      (uri.hasScheme && uri.scheme != 'http' && uri.scheme != 'https')) {
    throw RuleSourceUnsupportedException(sourceId, '$where 只支持 HTTP(S) URL。');
  }
}

Map<String, dynamic> _convertLegadoListOperation(
  String operation,
  String url,
  Map<String, dynamic> legadoRules, {
  required String listKey,
  required Map<String, String> fieldMap,
}) {
  final listRule = legadoRules[listKey];
  if (listRule is! String || listRule.trim().isEmpty) {
    throw RuleSourceUnsupportedException(
      'legado',
      'rule${operation[0].toUpperCase()}${operation.substring(1)}.$listKey 缺失。',
    );
  }
  _onlyLegadoRuleKeys(
    'legado',
    legadoRules,
    {listKey, ...fieldMap.values},
    'rule${operation[0].toUpperCase()}${operation.substring(1)}',
  );
  final fields = <String, dynamic>{};
  for (final entry in fieldMap.entries) {
    final raw = legadoRules[entry.value];
    if (raw != null && raw is! String) {
      throw RuleSourceUnsupportedException(
        'legado',
        'Legado 字段 ${entry.value} 必须是简单规则字符串。',
      );
    }
    if (raw is String && raw.trim().isNotEmpty) {
      fields[entry.key] = _legadoField(raw);
    }
  }
  final template = url
      .replaceAll('{{key}}', '{{query}}')
      .replaceAll('{{page}}', '{{page}}');
  return {
    'url': template,
    'items': {'selector': _legadoSelector(listRule), 'fields': fields},
  };
}

void _onlyLegadoRuleKeys(
  String sourceId,
  Map<String, dynamic> rules,
  Set<String> supported,
  String where,
) {
  final unsupported =
      rules.keys.where((key) => !supported.contains(key)).toList();
  if (unsupported.isNotEmpty) {
    throw RuleSourceUnsupportedException(
      sourceId,
      '$where 包含未实现的 Legado 规则字段：${unsupported.join(', ')}。',
    );
  }
}

String _canonicalJson(Object? value) => jsonEncode(_canonicalJsonValue(value));

Object? _canonicalJsonValue(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map(
              (entry) => MapEntry(
                entry.key.toString(),
                _canonicalJsonValue(entry.value),
              ),
            )
            .toList()
          ..sort((first, second) => first.key.compareTo(second.key));
    return Map<String, Object?>.fromEntries(entries);
  }
  if (value is List) {
    return value.map(_canonicalJsonValue).toList(growable: false);
  }
  return value;
}

String _legadoSelector(String rule) {
  final normalized = rule.trim();
  if (normalized.startsWith(r'$.')) return 'json:$normalized';
  if (normalized.startsWith('//') || normalized.startsWith('xpath:')) {
    throw const RuleSourceUnsupportedException(
      'legado',
      'Legado XPath 规则不受支持。',
    );
  }
  return 'css:$normalized';
}

Map<String, dynamic> _legadoField(String rule) {
  final normalized = rule.trim();
  if (_hasUnsupportedLegadoSyntax(normalized)) {
    throw RuleSourceUnsupportedException(
      'legado',
      '不支持 Legado 规则语法：$normalized',
    );
  }
  final separator = normalized.lastIndexOf('@');
  final selector =
      separator < 0 ? normalized : normalized.substring(0, separator).trim();
  final property =
      separator < 0 ? 'text' : normalized.substring(separator + 1).trim();
  final kind = switch (property.toLowerCase()) {
    'text' => 'text',
    'html' => 'html',
    'href' || 'src' || 'data-src' || 'content' => 'attr',
    _ =>
      throw RuleSourceUnsupportedException(
        'legado',
        'Legado 字段属性 "$property" 不受支持。',
      ),
  };
  if (kind == 'attr') {
    return {
      'selector': _legadoSelector(selector.isEmpty ? '*' : selector),
      'value': 'attr',
      'attribute': property.toLowerCase(),
    };
  }
  return {
    'selector': _legadoSelector(selector.isEmpty ? '*' : selector),
    'value': kind,
  };
}

void _rejectLegadoExecutableOrCredentialFeatures(Map<String, dynamic> legado) {
  const credentialKeys = {
    'loginUrl',
    'loginCheckJs',
    'loginUi',
    'header',
    'headerMap',
    'cookie',
  };
  for (final key in credentialKeys) {
    final value = legado[key];
    if (value != null && value != false && value != '') {
      throw RuleSourceUnsupportedException(
        'legado',
        '检测到 $key；登录、请求头和凭据规则当前不支持。',
      );
    }
  }
  void visit(dynamic value, String path) {
    if (value is String) {
      if (_hasUnsupportedLegadoSyntax(value)) {
        throw RuleSourceUnsupportedException(
          'legado',
          '$path 包含 JS、XPath、规则管道或加密语法，当前不支持。',
        );
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        visit(entry.value, '$path.${entry.key}');
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        visit(value[i], '$path[$i]');
      }
    }
  }

  visit(legado, r'$');
}

bool _hasUnsupportedLegadoSyntax(String value) {
  final lower = value.toLowerCase();
  return lower.contains('@js:') ||
      lower.contains('javascript:') ||
      lower.contains('xpath:') ||
      lower.contains('||') ||
      lower.contains('##') ||
      lower.contains('&&') ||
      lower.contains('@get:') ||
      lower.contains('@put:') ||
      lower.contains('@post:') ||
      lower.contains('@replace:') ||
      lower.contains('@json:') ||
      lower.contains('@base64:') ||
      lower.contains('@decode:') ||
      lower.contains('@encode:');
}
