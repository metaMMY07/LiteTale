import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
// The DOM package exposes matches only through its selector implementation.
// ignore: implementation_imports
import 'package:html/src/query_selector.dart' as html_selectors;

/// The explicit, offline subset of Legado understood by the iOS importer.
/// No part of this module evaluates JavaScript or performs I/O.
class LegadoImportResult {
  const LegadoImportResult({required this.definition, required this.notices});

  final Map<String, dynamic> definition;
  final List<String> notices;
}

/// Converts declarations, keeping the complete field rules for later parsing.
/// The caller must still validate the canonical source and its request policy.
LegadoImportResult convertLegadoSource(Map<String, dynamic> raw) {
  final notices = <String>[];
  _checkSourceKeys(raw, notices);
  final originalUrl = _required(raw, 'bookSourceUrl', '书源');
  final uri = Uri.tryParse(originalUrl);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('bookSourceUrl 必须是无凭据的 HTTP(S) URL。');
  }
  final importKey = uri.toString();
  final digest = sha256.convert(utf8.encode(importKey)).toString();
  final name = _optionalString(raw, 'bookSourceName', '书源') ?? uri.host;
  final type = raw['bookSourceType'];
  if (type != null && type != 0) {
    throw const FormatException('当前仅支持 bookSourceType=0 的文字书源。');
  }
  final cookieJar = raw['enabledCookieJar'];
  if (cookieJar != null && cookieJar is! bool) {
    throw const FormatException('enabledCookieJar 必须是布尔值。');
  }
  final userAgent = _staticUserAgent(raw['header'], notices);
  final charset =
      (_optionalString(raw, 'charset', '书源') ?? 'utf-8').toLowerCase();
  if (!const {'utf-8', 'utf8', 'gbk'}.contains(charset)) {
    throw FormatException('不支持字符集 $charset。');
  }
  final rules = <String, dynamic>{};
  final search = _ruleMap(raw['ruleSearch'], 'ruleSearch');
  final searchUrl = _optionalString(raw, 'searchUrl', '书源');
  if (searchUrl != null || search.isNotEmpty) {
    if (searchUrl == null || search.isEmpty) {
      throw const FormatException('搜索需要同时提供 searchUrl 和 ruleSearch。');
    }
    rules['search'] = _listOperation(searchUrl, search, 'ruleSearch', notices);
  }
  final explore = _ruleMap(raw['ruleExplore'], 'ruleExplore');
  final exploreUrl = _optionalString(raw, 'exploreUrl', '书源');
  if (raw['enabledExplore'] != false && exploreUrl != null) {
    rules['discover'] = _listOperation(
      exploreUrl,
      explore.isEmpty || !_hasValue(explore['bookList']) ? search : explore,
      'ruleExplore',
      notices,
    );
  } else {
    // Even an unused rule must not smuggle an unsupported executable stage.
    if (explore.isNotEmpty) {
      _checkListRule(explore, 'ruleExplore', notices);
      notices.add('ruleExplore 没有可用的 exploreUrl，未生成发现入口。');
    } else if (raw.containsKey('ruleExplore')) {
      notices.add('ruleExplore 为空且没有发现入口；此书源通过搜索使用。');
    }
  }

  final info = _ruleMap(raw['ruleBookInfo'], 'ruleBookInfo');
  if (info.isNotEmpty) {
    _onlyRuleKeys(info, const {
      'name',
      'author',
      'coverUrl',
      'intro',
      'lastChapter',
      'tocUrl',
      'kind',
      'status',
      'wordCount',
      'updateTime',
    }, 'ruleBookInfo');
    final fields = <String, dynamic>{};
    for (final pair
        in const {
          'title': 'name',
          'author': 'author',
          'coverUrl': 'coverUrl',
          'description': 'intro',
          'latestChapter': 'lastChapter',
          'catalogUrl': 'tocUrl',
          'status': 'status',
        }.entries) {
      final value = _optionalString(info, pair.value, 'ruleBookInfo');
      if (value != null) {
        fields[pair.key] = _field(
          value,
          notices,
          asUrl: const {'coverUrl', 'catalogUrl'}.contains(pair.key),
        );
      }
    }
    if (!fields.containsKey('title')) {
      throw const FormatException('ruleBookInfo.name 是详情必需的标题规则。');
    }
    final kind = _optionalString(info, 'kind', 'ruleBookInfo');
    if (kind != null && _containsScript(kind)) {
      // BookInfo calls getStringList, whereas the reviewed script expects a
      // String. Do not quietly join that List and claim equivalent behavior.
      final segments = _stages(kind);
      for (final stage in segments.where((stage) => stage.script)) {
        _parseReplace(stage.value, textInput: true);
      }
      _ReadExpression.parse(segments.first.value.split('##').first.trim());
      notices.add(
        'ruleBookInfo.kind 的 result 存在 List/String 类型疑点；已跳过此可选分类字段，未将其当作阅读状态。',
      );
    } else if (kind != null) {
      LegadoTextRule.parse(kind);
      notices.add('ruleBookInfo.kind 是分类元数据，未映射为阅读状态。');
    }
    _metadataFields(info, 'ruleBookInfo', const {
      'wordCount',
      'updateTime',
    }, notices);
    rules['detail'] = {'url': '{{bookUrl}}', 'fields': fields};
  }

  final toc = _ruleMap(raw['ruleToc'], 'ruleToc');
  if (toc.isNotEmpty) {
    _onlyRuleKeys(toc, const {
      'chapterList',
      'chapterName',
      'chapterUrl',
      'nextTocUrl',
    }, 'ruleToc');
    final list = _required(toc, 'chapterList', 'ruleToc');
    LegadoSelector.parse(list);
    rules['catalog'] = {
      'url': '{{tocUrl}}',
      'items': {
        'selector': 'legado:$list',
        'fields': {
          'id': _field(_required(toc, 'chapterUrl', 'ruleToc'), notices),
          'title': _field(_required(toc, 'chapterName', 'ruleToc'), notices),
          'url': _field(
            _required(toc, 'chapterUrl', 'ruleToc'),
            notices,
            asUrl: true,
          ),
        },
      },
      if (_hasValue(toc['nextTocUrl']))
        'pagination': {
          'next': _field(
            _required(toc, 'nextTocUrl', 'ruleToc'),
            notices,
            asUrl: true,
          ),
        },
    };
  }
  final content = _ruleMap(raw['ruleContent'], 'ruleContent');
  if (content.isNotEmpty) {
    _onlyRuleKeys(content, const {
      'content',
      'nextContentUrl',
      'imageStyle',
    }, 'ruleContent');
    rules['content'] = {
      'url': '{{chapterUrl}}',
      'fields': {
        'content': _field(
          _required(content, 'content', 'ruleContent'),
          notices,
        ),
      },
      if (_hasValue(content['nextContentUrl']))
        'pagination': {
          'next': _field(
            _required(content, 'nextContentUrl', 'ruleContent'),
            notices,
            asUrl: true,
          ),
        },
    };
    if (_hasValue(content['imageStyle'])) {
      _optionalString(content, 'imageStyle', 'ruleContent');
      notices.add('ruleContent.imageStyle 仅为显示元数据，不代表此书源支持插图。');
    }
  }
  if (rules.isEmpty) {
    throw const FormatException('没有可转换的书源操作。');
  }
  return LegadoImportResult(
    definition: {
      'schema': 'litetale-rule-source',
      'schemaVersion': 1,
      'source': {
        'id': 'legado_ios_${digest.substring(0, 20)}',
        'name': name,
        'baseUrl': uri.toString(),
        'version':
            _optionalString(raw, 'bookSourceVersion', '书源') ?? 'legado-ios-1',
        'charset': charset == 'utf8' ? 'utf-8' : charset,
        'importKey': importKey,
        'cookieJar': cookieJar ?? false,
        if (userAgent != null) 'userAgent': userAgent,
      },
      'rules': rules,
    },
    notices: List.unmodifiable(notices.toSet()),
  );
}

Map<String, dynamic> _listOperation(
  String url,
  Map<String, dynamic> rule,
  String where,
  List<String> notices,
) {
  _checkListRule(rule, where, notices);
  final list = _required(rule, 'bookList', where);
  LegadoSelector.parse(list);
  final title = _required(rule, 'name', where);
  final bookUrl = _required(rule, 'bookUrl', where);
  return {
    'url': _urlTemplate(url),
    'items': {
      'selector': 'legado:$list',
      'fields': {
        'id': _field(bookUrl, notices),
        'title': _field(title, notices),
        'detailUrl': _field(bookUrl, notices, asUrl: true),
        for (final pair
            in const {
              'author': 'author',
              'coverUrl': 'coverUrl',
              'description': 'intro',
              'latestChapter': 'lastChapter',
            }.entries)
          if (_hasValue(rule[pair.value]))
            pair.key: _field(
              _required(rule, pair.value, where),
              notices,
              asUrl: pair.key == 'coverUrl',
            ),
      },
    },
  };
}

void _checkListRule(
  Map<String, dynamic> rule,
  String where,
  List<String> notices,
) {
  _onlyRuleKeys(rule, const {
    'bookList',
    'name',
    'bookUrl',
    'author',
    'coverUrl',
    'intro',
    'lastChapter',
    'kind',
    'wordCount',
    'updateTime',
    'checkKeyWord',
  }, where);
  _metadataFields(rule, where, const {
    'kind',
    'wordCount',
    'updateTime',
  }, notices);
  if (_hasValue(rule['checkKeyWord'])) {
    _optionalString(rule, 'checkKeyWord', where);
    notices.add('$where.checkKeyWord 是作者的调试元数据，不会作为请求或搜索词执行。');
  }
}

void _metadataFields(
  Map<String, dynamic> rule,
  String where,
  Set<String> keys,
  List<String> notices,
) {
  for (final key in keys) {
    final value = _optionalString(rule, key, where);
    if (value != null) {
      LegadoTextRule.parse(value);
      notices.add('$where.$key 是可选元数据，当前阅读模型未保存该字段。');
    }
  }
}

Map<String, dynamic> _field(
  String raw,
  List<String> notices, {
  bool asUrl = false,
}) {
  final parsed = LegadoTextRule.parse(raw);
  notices.addAll(parsed.notices);
  return {
    'selector': 'css::scope',
    'value': parsed.returnsHtml ? 'html' : 'text',
    'legado': raw,
    if (asUrl) 'asUrl': true,
  };
}

String _urlTemplate(String value) {
  if (value.length > 4096 ||
      value.contains(
        RegExp(
          r'<js|@js:|@webjs:|javascript:|\},\s*\{|,\s*\{',
          caseSensitive: false,
        ),
      ) ||
      value.contains('<') ||
      value.contains('>')) {
    throw const FormatException('URL 规则仅支持普通 GET 地址和 key/page 占位符。');
  }
  for (final match in RegExp(r'\{\{(.*?)\}\}').allMatches(value)) {
    if (!const {'key', 'query', 'page'}.contains(match.group(1))) {
      throw const FormatException('URL 规则包含不支持的内嵌表达式。');
    }
  }
  final converted = value.replaceAll('{{key}}', '{{query}}');
  if (converted
      .replaceAll(RegExp(r'\{\{(?:query|page)\}\}'), '')
      .contains(RegExp(r'[{}]'))) {
    throw const FormatException('URL 规则包含不支持的参数语法。');
  }
  return converted;
}

String? _staticUserAgent(dynamic raw, List<String> notices) {
  if (!_hasValue(raw)) return null;
  if (raw is! String || raw.length > 4096) {
    throw const FormatException('header 仅支持静态 User-Agent。');
  }
  var value = raw.trim();
  if (value.startsWith('@js:')) {
    final body = value.substring(4).trim();
    // The whole expression must be this call with a JSON object argument.
    final match = RegExp(
      r'^JSON\.stringify\s*\(([\s\S]*)\)\s*;?$',
    ).firstMatch(body);
    if (match == null) {
      throw const FormatException(
        'header 脚本仅支持完整的 JSON.stringify(字面 JSON 对象)。',
      );
    }
    value = match.group(1)!.trim();
    notices.add(
      'header 的 JSON.stringify 字面对象已转换为静态 User-Agent；未执行 JavaScript。',
    );
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    throw const FormatException('header 必须是静态 JSON，不能执行脚本或读取设备/凭据。');
  }
  if (decoded is! Map || decoded.length != 1) {
    throw const FormatException('header 当前只支持一个静态 User-Agent 字段。');
  }
  final entry = decoded.entries.single;
  if (entry.key is! String ||
      (entry.key as String).toLowerCase() != 'user-agent' ||
      entry.value is! String ||
      (entry.value as String).trim().isEmpty ||
      (entry.value as String).length > 1024 ||
      (entry.value as String).contains(RegExp(r'[\r\n\x00]'))) {
    throw const FormatException('header 仅支持有效的静态 User-Agent。');
  }
  return entry.value as String;
}

void _checkSourceKeys(Map<String, dynamic> raw, List<String> notices) {
  const accepted = {
    'id',
    'bookSourceUrl',
    'bookSourceName',
    'bookSourceType',
    'bookSourceVersion',
    'bookSourceComment',
    'bookSourceGroup',
    'customOrder',
    'enabled',
    'enabledExplore',
    'enabledCookieJar',
    'header',
    'charset',
    'lastUpdateTime',
    'respondTime',
    'weight',
    'searchUrl',
    'exploreUrl',
    'ruleSearch',
    'ruleExplore',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
  };
  for (final entry in raw.entries) {
    if (!accepted.contains(entry.key) && _hasValue(entry.value)) {
      throw FormatException('不支持书源字段 ${entry.key}；登录、脚本库、宿主桥和网络脚本不可执行。');
    }
  }
  if (_hasValue(raw['respondTime'])) {
    notices.add('respondTime 仅为作者提供的响应时间排序信息，不会作为请求超时。');
  }
}

Map<String, dynamic> _ruleMap(dynamic raw, String where) {
  if (raw == null || raw == '') return {};
  if (raw is String) {
    try {
      raw = jsonDecode(raw);
    } on FormatException {
      throw FormatException('$where 必须是规则对象或该对象的 JSON 字符串。');
    }
  }
  if (raw is! Map || raw.keys.any((key) => key is! String)) {
    throw FormatException('$where 必须是规则对象。');
  }
  return Map<String, dynamic>.from(raw);
}

void _onlyRuleKeys(
  Map<String, dynamic> rule,
  Set<String> allowed,
  String where,
) {
  for (final entry in rule.entries) {
    if (!allowed.contains(entry.key) && _hasValue(entry.value)) {
      throw FormatException('$where.${entry.key} 尚不支持，不能静默忽略操作规则。');
    }
    if (allowed.contains(entry.key) &&
        entry.value != null &&
        entry.value is! String) {
      throw FormatException('$where.${entry.key} 必须是规则字符串。');
    }
  }
}

bool _hasValue(dynamic value) =>
    value != null &&
    value != '' &&
    !(value is String && value.trim().isEmpty) &&
    !(value is Map && value.isEmpty) &&
    !(value is List && value.isEmpty);

String _required(Map<String, dynamic> map, String key, String where) =>
    _optionalString(map, key, where) ??
    (throw FormatException('$where.$key 不能为空。'));

String? _optionalString(Map<String, dynamic> map, String key, String where) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$where.$key 必须是字符串。');
  return value.trim().isEmpty ? null : value.trim();
}

/// Parsed JSoup-style selection, excluding the final text/attribute read.
class LegadoSelector {
  LegadoSelector._(this.expression, this._branches, this._operator);

  final String expression;
  final List<List<_SelectStep>> _branches;
  final String? _operator;

  factory LegadoSelector.parse(String expression) {
    final input = expression.trim();
    _checkExpression(input);
    final composition = _composition(input);
    final branches = <List<_SelectStep>>[];
    for (var branch in composition.parts) {
      var css = false;
      if (branch.startsWith('@CSS:')) {
        branch = branch.substring(5).trim();
        css = true;
      } else if (branch.startsWith('@@')) {
        branch = branch.substring(2).trim();
        css = true;
      }
      final chain = css ? [branch] : _splitTop(branch, '@');
      if (chain.length > 32 || chain.any((value) => value.trim().isEmpty)) {
        throw const FormatException('Legado 选择器链为空或超过 32 段。');
      }
      branches.add([
        for (final part in chain) _SelectStep.parse(part.trim(), css: css),
      ]);
    }
    return LegadoSelector._(expression, branches, composition.operator);
  }

  List<dom.Element> select(dom.Node root) => _select(root, _Budget());

  List<dom.Element> _select(dom.Node root, _Budget budget) {
    final groups = <List<dom.Element>>[];
    for (final branch in _branches) {
      var contexts = <dom.Node>[root];
      for (final step in branch) {
        final next = <dom.Element>[];
        for (final context in contexts) {
          next.addAll(step.select(context, budget));
          budget.results(next.length);
        }
        contexts = next;
      }
      final result = contexts.whereType<dom.Element>().toList();
      groups.add(result);
      if (_operator == '||' && result.isNotEmpty) break;
    }
    final result = _merge(groups, _operator);
    budget.results(result.length);
    return result;
  }
}

class _SelectStep {
  const _SelectStep(this.css, this.text, this.children, this.index);
  final String? css;
  final String? text;
  final bool children;
  final int? index;

  factory _SelectStep.parse(String value, {required bool css}) {
    int? index;
    if (!css) {
      final match = RegExp(r'\.(-?\d+)$').firstMatch(value);
      if (match != null) {
        index = int.tryParse(match.group(1)!);
        if (index == null || index.abs() > 100000) {
          throw const FormatException('选择器索引超限。');
        }
        value = value.substring(0, match.start);
      }
      if (value == 'children') return _SelectStep(null, null, true, index);
      if (value.startsWith('text.')) {
        final text = value.substring(5);
        if (text.isEmpty || text.length > 256) {
          throw const FormatException('text. 需要 1–256 字符的自有文字条件。');
        }
        return _SelectStep(null, text, false, index);
      }
      for (final prefix
          in const {'class.': '.', 'id.': '#', 'tag.': ''}.entries) {
        if (value.startsWith(prefix.key)) {
          final name = value.substring(prefix.key.length);
          if (!RegExp(
            r'^[A-Za-z_\u0080-\uFFFF][A-Za-z0-9_\u0080-\uFFFF-]*$',
          ).hasMatch(name)) {
            throw const FormatException('class/id/tag 仅支持单个合法名称。');
          }
          value = '${prefix.value}$name';
          break;
        }
      }
    }
    if (value.isEmpty ||
        value.length > 1024 ||
        value.contains(RegExp(r'\.-?\d+(?=\.|$)|\.\s*\['))) {
      throw const FormatException('只支持单个零基/负数索引，不支持索引范围、排除或步长。');
    }
    for (final match in RegExp(
      r':nth-(?:last-)?child\(([^)]*)\)',
    ).allMatches(value)) {
      if (!RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(match.group(1)!.trim())) {
        throw const FormatException('nth-child 仅支持正整数，不支持 An+B 或范围表达式。');
      }
    }
    // The Dart selector engine does not implement the entire JSoup dialect.
    for (final match in RegExp(
      r':([A-Za-z-]+)',
    ).allMatches(_withoutQuoted(value))) {
      if (!const {
        'scope',
        'first-child',
        'last-child',
        'only-child',
        'nth-child',
        'nth-last-child',
        'not',
        'link',
      }.contains(match.group(1))) {
        throw FormatException('不支持 CSS 伪类 ${match.group(0)}。');
      }
    }
    try {
      if (value != ':scope') {
        html_parser.parseFragment('<div><a></a></div>').querySelectorAll(value);
      }
    } catch (error) {
      throw FormatException('不支持或无效的 CSS 选择器 $value：$error');
    }
    return _SelectStep(value, null, false, index);
  }

  List<dom.Element> select(dom.Node root, _Budget budget) {
    List<dom.Element> values;
    if (children) {
      values = root.nodes.whereType<dom.Element>().toList();
      budget.spend(root.nodes.length);
    } else if (text != null) {
      values = [
        for (final element in _walk(root, budget))
          if (_ownText(element).contains(text!)) element,
      ];
    } else if (css == ':scope') {
      values =
          root is dom.Element
              ? [root]
              : root.nodes.whereType<dom.Element>().toList();
    } else {
      _walk(root, budget).length;
      try {
        values = [
          if (root is dom.Element && html_selectors.matches(root, css!)) root,
          ..._query(root, css!),
        ];
      } catch (error) {
        throw FormatException('CSS 选择器执行失败：$error');
      }
    }
    budget.results(values.length);
    final selected = index;
    if (selected == null) return values;
    final actual = selected < 0 ? values.length + selected : selected;
    return actual < 0 || actual >= values.length ? [] : [values[actual]];
  }
}

/// A text/attribute read followed by explicitly compiled native replacements.
class LegadoTextRule {
  LegadoTextRule._(
    this.expression,
    this._read,
    this._replacements,
    this.notices,
  );
  final String expression;
  final _ReadExpression _read;
  final List<_Replacement> _replacements;
  final List<String> notices;
  bool get returnsHtml => _read.html;

  factory LegadoTextRule.parse(String raw) {
    _checkExpression(raw.trim(), allowScript: true);
    final stages = _stages(raw);
    if (stages.isEmpty || stages.first.script) {
      throw const FormatException('字段必须先声明当前节点/选择器的取值规则。');
    }
    final first = stages.first.value.split('##');
    final read = _ReadExpression.parse(first.first.trim());
    final replacements = <_Replacement>[];
    final notices = <String>[];
    if (first.length > 1) replacements.add(_regexStage(first.sublist(1)));
    for (final stage in stages.skip(1)) {
      if (stage.script) {
        final replacement = _parseReplace(
          stage.value,
          textInput: !read.html && replacements.isEmpty,
        );
        replacements.add(replacement);
        if (replacement is _ImageTextNoop) {
          notices.add('正文 img 清理位于 text 提取之后，按已审阅的无效果变换处理；此规则不提供插图。');
        } else {
          notices.add('纯 result.replace 表达式已编译为限定的原生文本替换；未执行 JavaScript。');
        }
      } else {
        final value = stage.value.trim();
        if (!value.startsWith('##')) {
          throw const FormatException('脚本后仅支持 ## 正则替换阶段。');
        }
        replacements.add(_regexStage(value.substring(2).split('##')));
      }
    }
    if (replacements.length > 16) throw const FormatException('字段变换不得超过 16 段。');
    return LegadoTextRule._(
      raw,
      read,
      replacements,
      List.unmodifiable(notices),
    );
  }

  String extract(dom.Node root, {bool first = false}) {
    final budget = _Budget();
    _walk(root, budget).length;
    final values = _read.values(root, budget);
    var result =
        first ? (values.isEmpty ? '' : values.first) : values.join('\n');
    _checkOutput(result);
    for (final replacement in _replacements) {
      result = replacement.apply(result);
      _checkOutput(result);
    }
    return result;
  }
}

class _ReadExpression {
  const _ReadExpression(this.branches, this.operator, this.html);
  final List<_ReadBranch> branches;
  final String? operator;
  final bool html;

  factory _ReadExpression.parse(String value) {
    final composition = _composition(value);
    final branches = <_ReadBranch>[];
    for (var part in composition.parts) {
      String? cssPrefix;
      if (part.startsWith('@CSS:')) {
        cssPrefix = '@CSS:';
        part = part.substring(5);
      } else if (part.startsWith('@@')) {
        cssPrefix = '@@';
        part = part.substring(2);
      }
      final chain = _splitTop(part, '@');
      final terminal = chain.removeLast().trim();
      if (!RegExp(r'^[A-Za-z_:][A-Za-z0-9_.:-]{0,63}$').hasMatch(terminal)) {
        throw const FormatException(
          '字段必须以 text/ownText/textNodes/html/all 或合法属性名结束。',
        );
      }
      final selector =
          chain.isEmpty
              ? null
              : LegadoSelector.parse('${cssPrefix ?? ''}${chain.join('@')}');
      branches.add(_ReadBranch(selector, terminal));
    }
    final modes =
        branches
            .map((branch) => const {'html', 'all'}.contains(branch.terminal))
            .toSet();
    if (modes.length != 1) throw const FormatException('同一字段不能合并 HTML 和纯文本取值。');
    return _ReadExpression(branches, composition.operator, modes.single);
  }

  List<String> values(dom.Node root, _Budget budget) {
    final groups = <List<String>>[];
    for (final branch in branches) {
      final values = <String>[];
      final List<dom.Node> nodes =
          branch.selector?._select(root, budget) ?? [root];
      final attribute =
          !const {
            'text',
            'ownText',
            'textNodes',
            'html',
            'all',
          }.contains(branch.terminal);
      for (final node in nodes) {
        _walk(node, budget).length;
        final value = _readNode(node, branch.terminal);
        if (value.trim().isNotEmpty &&
            (!attribute || !values.contains(value))) {
          budget.characters(value.length);
          values.add(value);
        }
        budget.results(values.length);
      }
      groups.add(values);
      if (operator == '||' && values.isNotEmpty) break;
    }
    return _merge(groups, operator);
  }
}

class _ReadBranch {
  const _ReadBranch(this.selector, this.terminal);
  final LegadoSelector? selector;
  final String terminal;
}

String _readNode(dom.Node node, String terminal) {
  if (terminal == 'text') return _text(node);
  if (terminal == 'ownText') return _ownText(node);
  if (terminal == 'textNodes') {
    return node.nodes
        .whereType<dom.Text>()
        .map((text) => text.text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n');
  }
  if (terminal == 'html' || terminal == 'all') {
    final copy = node.clone(true);
    for (final element in _query(copy, 'script, style')) {
      element.remove();
    }
    // JSoup's html/all terminal returns selected outer HTML, not just children.
    return copy is dom.Element
        ? copy.outerHtml
        : (copy is dom.Document ? copy.outerHtml : copy.toString());
  }
  return node is dom.Element ? node.attributes[terminal] ?? '' : '';
}

String _text(dom.Node root) {
  final buffer = StringBuffer();
  const block = {
    'address',
    'article',
    'aside',
    'blockquote',
    'br',
    'dd',
    'div',
    'dl',
    'dt',
    'fieldset',
    'figcaption',
    'figure',
    'footer',
    'form',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'header',
    'hr',
    'li',
    'main',
    'nav',
    'ol',
    'p',
    'pre',
    'section',
    'table',
    'td',
    'th',
    'tr',
    'ul',
  };
  void append(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is dom.Element &&
        const {'script', 'style'}.contains(node.localName)) {
      return;
    }
    final boundary = node is dom.Element && block.contains(node.localName);
    if (boundary) buffer.write(' ');
    for (final child in node.nodes) {
      append(child);
    }
    if (boundary) buffer.write(' ');
  }

  append(root);
  return buffer.toString().replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();
}

String _ownText(dom.Node root) {
  final buffer = StringBuffer();
  for (final child in root.nodes) {
    if (child is dom.Text) {
      buffer.write(child.text);
    } else if (child is dom.Element && child.localName == 'br') {
      buffer.write(' ');
    }
  }
  return buffer.toString().replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();
}

List<dom.Element> _query(dom.Node root, String css) => switch (root) {
  dom.Element element => element.querySelectorAll(css),
  dom.Document document => document.querySelectorAll(css),
  dom.DocumentFragment fragment => fragment.querySelectorAll(css),
  _ => throw const FormatException('选择器上下文必须是 Document 或 Element。'),
};

class _Budget {
  int remaining = 250000;
  int remainingCharacters = 2 * 1024 * 1024;
  void characters(int count) {
    remainingCharacters -= count;
    if (remainingCharacters < 0) {
      throw const FormatException('提取字段超过 2 Mi 字符资源预算。');
    }
  }

  void spend(int count) {
    remaining -= count;
    if (remaining < 0) throw const FormatException('Legado DOM 操作超过资源预算。');
  }

  void results(int count) {
    if (count > 10000) throw const FormatException('Legado 结果集超过 10000 项。');
  }
}

Iterable<dom.Element> _walk(dom.Node root, _Budget budget) sync* {
  final stack = <(dom.Node, int)>[(root, 0)];
  while (stack.isNotEmpty) {
    final (node, depth) = stack.removeLast();
    budget.spend(1);
    if (depth > 128) throw const FormatException('DOM 深度超过 128 层。');
    if (node is dom.Element) yield node;
    for (final child in node.nodes.reversed) {
      stack.add((child, depth + 1));
    }
  }
}

void _checkOutput(String value) {
  if (value.length > 2 * 1024 * 1024) {
    throw const FormatException('字段结果超过 2 Mi 字符。');
  }
}

void _checkExpression(String value, {bool allowScript = false}) {
  if (value.isEmpty || value.length > 8192) {
    throw const FormatException('Legado 规则必须为 1–8192 字符。');
  }
  if (value.contains(
        RegExp(
          r'\{\{|@(?:XPath|Json|put|get|webjs):|^\$[.\[]|^/',
          caseSensitive: false,
        ),
      ) ||
      (!allowScript && (value.contains('##') || _containsScript(value)))) {
    throw const FormatException('此规则需要尚未支持的 XPath/JSONPath/变量/脚本或正则选择能力。');
  }
}

bool _containsScript(String value) =>
    value.contains(RegExp(r'<\s*/?\s*js\b|@js:', caseSensitive: false));

class _Composition {
  const _Composition(this.parts, this.operator);
  final List<String> parts;
  final String? operator;
}

_Composition _composition(String value) {
  String? operator;
  var parts = [value];
  for (final candidate in const ['&&', '||', '%%']) {
    final split = _splitTop(value, candidate);
    if (split.length > 1) {
      if (operator != null) throw const FormatException('同一层暂不支持混用 &&、||、%%。');
      operator = candidate;
      parts = split;
    }
  }
  if (parts.length > 32 || parts.any((part) => part.trim().isEmpty)) {
    throw const FormatException('合并规则为空或超过 32 段。');
  }
  return _Composition(parts.map((part) => part.trim()).toList(), operator);
}

List<String> _splitTop(String value, String delimiter) {
  final result = <String>[];
  final stack = <String>[];
  String? quote;
  var escaped = false;
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '[' || char == '(') {
      stack.add(char);
      continue;
    }
    if (char == ']' || char == ')') {
      if (stack.isEmpty ||
          (char == ']'
              ? stack.removeLast() != '['
              : stack.removeLast() != '(')) {
        throw const FormatException('规则括号不匹配。');
      }
      continue;
    }
    if (stack.isEmpty && value.startsWith(delimiter, i)) {
      result.add(value.substring(start, i));
      i += delimiter.length - 1;
      start = i + 1;
    }
  }
  if (quote != null || stack.isNotEmpty || escaped) {
    throw const FormatException('规则有未闭合的引号、括号或转义。');
  }
  result.add(value.substring(start));
  return result;
}

List<T> _merge<T>(List<List<T>> groups, String? operator) {
  if (operator != '%%') return [for (final group in groups) ...group];
  final result = <T>[];
  for (var i = 0; groups.any((group) => i < group.length); i++) {
    for (final group in groups) {
      if (i < group.length) result.add(group[i]);
    }
  }
  return result;
}

String _withoutQuoted(String value) {
  final buffer = StringBuffer();
  String? quote;
  var bracket = 0;
  var escaped = false;
  for (final char in value.split('')) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '[') bracket++;
    if (char == ']') bracket--;
    if (bracket == 0) buffer.write(char);
  }
  return buffer.toString();
}

class _Stage {
  const _Stage(this.value, this.script);
  final String value;
  final bool script;
}

List<_Stage> _stages(String raw) {
  final stages = <_Stage>[];
  var position = 0;
  while (position < raw.length) {
    final open = raw.indexOf('<js>', position);
    final short = raw.indexOf('@js:', position);
    final next =
        open < 0
            ? short
            : short < 0
            ? open
            : (open < short ? open : short);
    if (next < 0) {
      if (raw.substring(position).trim().isNotEmpty) {
        stages.add(_Stage(raw.substring(position).trim(), false));
      }
      break;
    }
    if (raw.substring(position, next).trim().isNotEmpty) {
      stages.add(_Stage(raw.substring(position, next).trim(), false));
    }
    if (next == short) {
      stages.add(_Stage(raw.substring(next + 4).trim(), true));
      break;
    }
    final close = raw.indexOf('</js>', next + 4);
    if (close < 0) throw const FormatException('缺少 </js>；不支持任意脚本。');
    stages.add(_Stage(raw.substring(next + 4, close).trim(), true));
    position = close + 5;
  }
  if (stages.any((stage) => !stage.script && _containsScript(stage.value))) {
    throw const FormatException('无法识别脚本阶段。');
  }
  return stages;
}

abstract class _Replacement {
  String apply(String value);
}

_Replacement _regexStage(List<String> parts) {
  if (parts.isEmpty || parts.length > 2) {
    throw const FormatException('只支持 ##正则##替换，不支持首匹配截取模式。');
  }
  return _RegexReplacement.compile(
    parts.first,
    parts.length > 1 ? parts[1] : '',
    global: true,
  );
}

class _Noop implements _Replacement {
  @override
  String apply(String value) => value;
}

class _ImageTextNoop extends _Noop {}

_Replacement _parseReplace(String script, {required bool textInput}) {
  final parser = _ReplaceParser(script);
  parser.takeWord('result');
  parser.take('.');
  parser.takeWord('replace');
  parser.take('(');
  final (pattern, regex, global) = parser.pattern();
  parser.take(',');
  final replacement = parser.string();
  parser.take(')');
  parser.finish();
  if (pattern.length > 1024 || replacement.length > 4096) {
    throw const FormatException('原生替换表达式超限。');
  }
  if (regex &&
      textInput &&
      global &&
      pattern == r'(<img src="[^"]+")[^>]+>' &&
      replacement == r'$1>') {
    return _ImageTextNoop();
  }
  return regex
      ? _RegexReplacement.compile(pattern, replacement, global: global)
      : _RegexReplacement.compile(
        RegExp.escape(pattern),
        replacement,
        global: false,
      );
}

class _ReplaceParser {
  _ReplaceParser(this.value);
  final String value;
  int position = 0;
  void ws() {
    while (position < value.length && value[position].trim().isEmpty) {
      position++;
    }
  }

  void take(String token) {
    ws();
    if (!value.startsWith(token, position)) {
      throw const FormatException('仅支持完整的 result.replace(字面模式, 字面替换) 表达式。');
    }
    position += token.length;
  }

  void takeWord(String token) {
    take(token);
    if (position < value.length &&
        RegExp(r'[A-Za-z0-9_$]').hasMatch(value[position])) {
      throw const FormatException('不支持脚本标识符。');
    }
  }

  (String, bool, bool) pattern() {
    ws();
    if (position >= value.length) throw const FormatException('缺少替换模式。');
    if (value[position] != '/') return (string(), false, false);
    position++;
    final buffer = StringBuffer();
    var escaped = false;
    var characterClass = false;
    while (position < value.length) {
      final char = value[position++];
      if (escaped) {
        buffer.write('\\$char');
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '[') characterClass = true;
      if (char == ']') characterClass = false;
      if (char == '/' && !characterClass) {
        final start = position;
        while (position < value.length &&
            RegExp(r'[A-Za-z]').hasMatch(value[position])) {
          position++;
        }
        final flags = value.substring(start, position);
        if (flags != '' && flags != 'g') {
          throw const FormatException('原生正则替换仅支持空标志或 g。');
        }
        return (buffer.toString(), true, flags == 'g');
      }
      if (char == '\n' || char == '\r') {
        throw const FormatException('正则字面量不能换行。');
      }
      buffer.write(char);
    }
    throw const FormatException('未闭合的正则字面量。');
  }

  String string() {
    ws();
    if (position >= value.length ||
        !const ['"', "'"].contains(value[position])) {
      throw const FormatException('替换参数必须是字面字符串，不能使用变量、函数或宿主桥。');
    }
    final quote = value[position++];
    final buffer = StringBuffer();
    while (position < value.length) {
      final char = value[position++];
      if (char == quote) return buffer.toString();
      if (char == '\n' || char == '\r') {
        throw const FormatException('字符串字面量不能直接换行。');
      }
      if (char != r'\') {
        buffer.write(char);
        continue;
      }
      if (position >= value.length) break;
      final escaped = value[position++];
      const escapes = {
        'n': '\n',
        'r': '\r',
        't': '\t',
        'b': '\b',
        'f': '\f',
        '\\': '\\',
        '/': '/',
        '"': '"',
        "'": "'",
      };
      if (escaped == 'u' && position + 4 <= value.length) {
        final code = int.tryParse(
          value.substring(position, position + 4),
          radix: 16,
        );
        if (code == null) throw const FormatException('无效的 Unicode 转义。');
        buffer.writeCharCode(code);
        position += 4;
      } else if (escapes.containsKey(escaped)) {
        buffer.write(escapes[escaped]);
      } else {
        throw const FormatException('不支持此脚本字符串转义。');
      }
    }
    throw const FormatException('未闭合的字符串字面量。');
  }

  void finish() {
    ws();
    if (position < value.length && value[position] == ';') {
      position++;
      ws();
    }
    if (position != value.length) {
      throw const FormatException('替换后仍有脚本；不支持语句、网络、Java 桥或任意 JavaScript。');
    }
  }
}

/// Backtracking repetition is not admitted. The only unbounded forms are a
/// single character-class run or a literal with one leading/trailing .*, which
/// is implemented by a linear line scan rather than a backtracking regex.
class _RegexReplacement implements _Replacement {
  _RegexReplacement._(
    this.regex,
    this.replacement,
    this.global,
    this.complexity,
  );
  final RegExp regex;
  final String replacement;
  final bool global;
  final int complexity;

  static _Replacement compile(
    String pattern,
    String replacement, {
    required bool global,
  }) {
    if (pattern.length > 1024 || replacement.length > 4096) {
      throw const FormatException('正则/替换长度超限。');
    }
    if (replacement.isEmpty) {
      // Empty alternatives in watermark removals cannot change output.
      while (pattern.endsWith('|') && !pattern.endsWith(r'\|')) {
        pattern = pattern.substring(0, pattern.length - 1);
      }
      while (pattern.startsWith('|')) {
        pattern = pattern.substring(1);
      }
      if (pattern.isEmpty) return _Noop();
    }
    if (pattern.startsWith('.*')) {
      final literal = _literalRegex(pattern.substring(2));
      if (literal != null && literal.isNotEmpty) {
        _validateReplacement(replacement, 0);
        return _WildcardReplacement(literal, replacement, global, true);
      }
    }
    if (pattern.endsWith('.*')) {
      final literal = _literalRegex(pattern.substring(0, pattern.length - 2));
      if (literal != null && literal.isNotEmpty) {
        _validateReplacement(replacement, 0);
        return _WildcardReplacement(literal, replacement, global, false);
      }
    }
    final run = RegExp(
      r'^(?:\\[sdwSDW]|\[(?:\\.|[^\]\\])+\])\+$',
    ).hasMatch(pattern);
    var escaped = false;
    var inClass = false;
    var groups = 0;
    var captures = 0;
    var branches = 1;
    var tokens = 0;
    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      if (escaped) {
        if (RegExp(r'[0-9]').hasMatch(char) ||
            (RegExp(r'[A-Za-z]').hasMatch(char) &&
                !'dDsSwWbBfnrtvux'.contains(char))) {
          throw const FormatException('正则反向引用、Java 专用转义与 Unicode/宿主扩展不受支持。');
        }
        escaped = false;
        tokens++;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '[' && !inClass) {
        inClass = true;
        tokens++;
        continue;
      }
      if (char == ']' && inClass) {
        inClass = false;
        continue;
      }
      if (inClass) continue;
      if (char == '(') {
        groups++;
        if (groups > 8) throw const FormatException('正则分组超过 8 层/项。');
        if (i + 1 < pattern.length && pattern[i + 1] == '?') {
          if (!pattern.startsWith('(?:', i)) {
            throw const FormatException('不支持正则前后查找或内嵌模式。');
          }
          i += 2;
        } else {
          captures++;
        }
      } else if (char == '|') {
        // Conservatively bounds the product of choices in successive groups.
        branches *= 2;
        if (branches > 32) throw const FormatException('正则分支复杂度超限。');
      } else if (const {'*', '+', '?', '{', '}'}.contains(char) &&
          !(run && i == pattern.length - 1 && char == '+')) {
        throw const FormatException('正则量词不在安全子集内；禁止嵌套量词、量化分组及可能导致回溯爆炸的规则。');
      } else {
        tokens++;
      }
    }
    if (escaped || inClass) throw const FormatException('正则有未闭合的转义或字符类。');
    RegExp regex;
    try {
      regex = RegExp(pattern);
    } on FormatException {
      throw const FormatException('正则格式无效。');
    }
    _validateReplacement(replacement, captures);
    // Literal alternatives are handled efficiently by the native matcher.
    final literal =
        _literalRegex(pattern) != null || _literalAlternatives(pattern);
    return _RegexReplacement._(
      regex,
      replacement,
      global,
      literal || run ? 1 : (tokens + 1) * branches,
    );
  }

  @override
  String apply(String value) {
    if (value.length * complexity > 64 * 1024 * 1024) {
      throw const FormatException('正则输入与模式的组合超过资源预算。');
    }
    final buffer = StringBuffer();
    var position = 0;
    var matches = 0;
    for (final match in regex.allMatches(value)) {
      if (++matches > 32768) throw const FormatException('正则匹配次数超过资源预算。');
      buffer.write(value.substring(position, match.start));
      buffer.write(_replacementValue(replacement, match));
      if (buffer.length > 2 * 1024 * 1024) {
        throw const FormatException('正则替换结果超过资源预算。');
      }
      position = match.end;
      if (!global) break;
    }
    buffer.write(value.substring(position));
    _checkOutput(buffer.toString());
    return buffer.toString();
  }
}

String? _literalRegex(String pattern) {
  final buffer = StringBuffer();
  var escaped = false;
  for (final char in pattern.split('')) {
    if (escaped) {
      if (!r'\.^$|?*+()[]{}-/'.contains(char)) return null;
      buffer.write(char);
      escaped = false;
    } else if (char == r'\') {
      escaped = true;
    } else if (r'.^$|?*+()[]{}'.contains(char)) {
      return null;
    } else {
      buffer.write(char);
    }
  }
  return escaped ? null : buffer.toString();
}

bool _literalAlternatives(String value) =>
    value.split('|').every((part) => _literalRegex(part) != null);

String _replacementValue(String template, Match match) {
  final buffer = StringBuffer();
  for (var i = 0; i < template.length; i++) {
    final char = template[i];
    if (char != r'$' || i + 1 == template.length) {
      buffer.write(char);
      continue;
    }
    final next = template[++i];
    if (next == r'$') {
      buffer.write(r'$');
    } else if (next == '&') {
      buffer.write(match.group(0));
    } else if (RegExp(r'[0-9]').hasMatch(next)) {
      final group = int.parse(next);
      if (group > match.groupCount) {
        throw const FormatException('替换引用了不存在的正则分组。');
      }
      buffer.write(match.group(group) ?? '');
    } else {
      throw const FormatException('不支持此替换引用。');
    }
    if (buffer.length > 2 * 1024 * 1024) {
      throw const FormatException('替换分组展开超过资源预算。');
    }
  }
  return buffer.toString();
}

void _validateReplacement(String value, int captures) {
  for (var i = 0; i < value.length - 1; i++) {
    if (value[i] != r'$') continue;
    final next = value[++i];
    if (next == r'$' || next == '&') continue;
    final group = int.tryParse(next);
    if (group == null || group > captures) {
      throw const FormatException('替换引用超出限定子集或引用了不存在的正则分组。');
    }
  }
}

class _WildcardReplacement implements _Replacement {
  const _WildcardReplacement(
    this.literal,
    this.replacement,
    this.global,
    this.leading,
  );
  final String literal;
  final String replacement;
  final bool global;
  final bool leading;
  @override
  String apply(String value) {
    final buffer = StringBuffer();
    var replaced = false;
    // RegExp dot does not cross line terminators. Preserve them verbatim.
    var start = 0;
    for (var end = 0; end <= value.length; end++) {
      if (end < value.length &&
          !const {'\n', '\r', '\u2028', '\u2029'}.contains(value[end])) {
        continue;
      }
      final line = value.substring(start, end);
      final position =
          leading ? line.lastIndexOf(literal) : line.indexOf(literal);
      if (position < 0 || (!global && replaced)) {
        buffer.write(line);
      } else {
        final match =
            (leading
                    ? RegExp('^.*${RegExp.escape(literal)}')
                    : RegExp('${RegExp.escape(literal)}.*'))
                .firstMatch(line)!;
        // Anchored/known-position matching cannot rescan a failing suffix.
        buffer.write(leading ? '' : line.substring(0, position));
        buffer.write(_replacementValue(replacement, match));
        buffer.write(leading ? line.substring(position + literal.length) : '');
        replaced = true;
      }
      if (end < value.length) buffer.write(value[end]);
      if (buffer.length > 2 * 1024 * 1024) {
        throw const FormatException('正则替换结果超过资源预算。');
      }
      start = end + 1;
    }
    return buffer.toString();
  }
}
