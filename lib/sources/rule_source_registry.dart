import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:wild/src/rust/api/database.dart' as db;
import 'rules/rule_source.dart';
import 'rules/legado_compatibility.dart';

class InstalledRuleSource {
  const InstalledRuleSource(
    this.definition, {
    this.enabled = true,
    this.builtIn = false,
  });
  final RuleSourceDefinition definition;
  final bool enabled, builtIn;
  InstalledRuleSource copyWith({
    bool? enabled,
    RuleSourceDefinition? definition,
  }) => InstalledRuleSource(
    definition ?? this.definition,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
  );
}

class SourceImportItem {
  const SourceImportItem({
    this.definition,
    this.error,
    this.notices = const [],
    this.name,
  });
  final RuleSourceDefinition? definition;
  final String? error;
  final List<String> notices;
  final String? name;
}

List<SourceImportItem> inspectSourceImport(
  String raw, {
  TargetPlatform? platform,
  Iterable<InstalledRuleSource> installedSources = const [],
}) {
  final ios = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
  if (utf8.encode(raw).length > 2 * 1024 * 1024) {
    throw const FormatException('书源文件不能超过 2 MB');
  }
  final decoded = jsonDecode(raw.startsWith('\uFEFF') ? raw.substring(1) : raw);
  final list = decoded is List ? decoded : [decoded];
  if (ios && list.isEmpty) throw const FormatException('文件中没有书源');
  if (list.length > 100) throw const FormatException('一次最多导入 100 个书源');
  final ids = <String>{};
  return list.map((value) {
    try {
      if (value is! Map) throw const FormatException('书源必须是 JSON 对象');
      final map = Map<String, dynamic>.from(value);
      RuleSourceDefinition definition;
      var notices = <String>[];
      if (map.containsKey('bookSourceUrl')) {
        try {
          definition = RuleSourceDefinition.fromLegadoJson(map);
        } on RuleSourceException {
          if (!ios) rethrow;
          final converted = convertLegadoSource(map);
          definition = RuleSourceDefinition.fromJson(converted.definition);
          notices = converted.notices;
        }
      } else {
        definition = RuleSourceDefinition.fromJson(map);
      }
      if (ios && map['bookSourceUrl'] is String) {
        final key =
            Uri.parse((map['bookSourceUrl'] as String).trim()).toString();
        final matches =
            installedSources
                .where((entry) => entry.definition.importKey == key)
                .toList();
        final exact =
            matches
                .where((entry) => entry.definition.id == definition.id)
                .firstOrNull;
        final existing = exact ?? (matches.length == 1 ? matches.single : null);
        final canonical = definition.toJson(id: existing?.definition.id);
        (canonical['source'] as Map<String, dynamic>)['importKey'] = key;
        definition = RuleSourceDefinition.fromJson(canonical);
      }
      if (!definition.capabilities.detail ||
          !definition.capabilities.catalog ||
          !definition.capabilities.content) {
        throw const FormatException('阅读书源需要详情、目录和正文规则');
      }
      if (!definition.capabilities.discover &&
          !definition.capabilities.search) {
        throw const FormatException('书源需要提供发现或搜索入口');
      }
      if (!ids.add(definition.id)) {
        throw FormatException('同一文件出现重复书源 ID：${definition.id}');
      }
      return SourceImportItem(
        definition: definition,
        notices: List.unmodifiable(notices),
        name: definition.name,
      );
    } catch (error) {
      final name =
          value is Map
              ? value['bookSourceName'] ??
                  (value['source'] is Map ? value['source']['name'] : null)
              : null;
      return SourceImportItem(
        error: '$error',
        name: name is String ? name : null,
      );
    }
  }).toList();
}

Future<String> fetchSourceImport(Uri uri) async {
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('请输入 HTTPS 书源文件链接');
  }
  final client = http.Client();
  try {
    return await (() async {
      // A direct JSON link only. Redirects are explicit failures so the URL in
      // the import preview remains the address actually requested.
      final response = await client.send(
        http.Request('GET', uri)..followRedirects = false,
      );
      if (response.statusCode != 200) {
        throw StateError('书源下载失败（HTTP ${response.statusCode}）');
      }
      var length = 0;
      final chunks = <int>[];
      await for (final chunk in response.stream) {
        length += chunk.length;
        if (length > 2 * 1024 * 1024) {
          throw const FormatException('书源文件不能超过 2 MB');
        }
        chunks.addAll(chunk);
      }
      return utf8.decode(chunks).replaceFirst('\uFEFF', '');
    })().timeout(const Duration(seconds: 15));
  } finally {
    client.close();
  }
}

class RuleSourceRegistry extends ChangeNotifier {
  RuleSourceRegistry({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => db.loadProperty(key: propertyKey)),
       _write =
           write ?? ((raw) => db.saveProperty(key: propertyKey, value: raw));
  static final instance = RuleSourceRegistry();
  static const propertyKey = 'litetale.rule_sources_v1';
  // Retire only previously bundled entries. Explicit user imports remain data.
  static const _retiredBuiltIns = {'wikisource_zh', 'dushuzhijia_classics'};
  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  final _entries = <String, InstalledRuleSource>{};
  final _revisions = <String, int>{};
  final _origins = <String, String>{};
  Future<void> _writes = Future.value();
  Future<void>? _loading;
  String? warning;
  List<InstalledRuleSource> get entries => List.unmodifiable(_entries.values);
  InstalledRuleSource? operator [](String id) => _entries[id];
  int revision(String id) => _revisions[id] ?? 0;

  Future<void> load({List<Map<String, dynamic>>? builtIns}) =>
      _loading ??= _load(builtIns);
  Future<void> _load(List<Map<String, dynamic>>? builtIns) async {
    final defaults =
        builtIns ??
        (jsonDecode(
                  await rootBundle.loadString(
                    'assets/book_sources/bundled.json',
                  ),
                )
                as List)
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList();
    final next = <String, InstalledRuleSource>{};
    for (final raw in defaults) {
      final source = RuleSourceDefinition.fromJson(raw);
      if (_retiredBuiltIns.contains(source.id)) continue;
      next[source.id] = InstalledRuleSource(source, builtIn: true);
    }
    String raw;
    try {
      raw = await _read().timeout(const Duration(seconds: 3));
    } catch (_) {
      raw = '';
      warning = '已保存书源暂时无法读取，可重启后重试。';
    }
    if (raw.isNotEmpty) {
      try {
        final saved = jsonDecode(raw) as Map;
        if (saved['version'] != 1) throw const FormatException('不支持的书源存储版本');
        final origins = saved['origins'];
        if (origins is Map) {
          for (final entry in origins.entries) {
            if (entry.key is String && entry.value is String) {
              _origins[entry.key as String] = entry.value as String;
            }
          }
        }
        final items = saved['entries'] as List;
        if (items.length > 100) throw const FormatException('保存的书源数量超限');
        for (final item in items) {
          try {
            final source = RuleSourceDefinition.fromJson(
              Map<String, dynamic>.from(item['definition'] as Map),
            );
            // Keep the identity pin, but do not restore retired built-ins from
            // an older installation's saved registry. No books are deleted.
            _origins.putIfAbsent(source.id, () => source.baseUrl.origin);
            if (item['builtIn'] == true &&
                _retiredBuiltIns.contains(source.id)) {
              continue;
            }
            next[source.id] = InstalledRuleSource(
              source,
              enabled: item['enabled'] != false,
              builtIn: item['builtIn'] == true,
            );
          } catch (_) {
            warning = '部分书源配置无法读取，其余书源仍可使用。';
          }
        }
        // A removed built-in stays removed on subsequent launches.
        for (final id in (saved['removedBuiltIns'] as List? ?? const [])) {
          next.remove(id);
          _removedBuiltIns.add(id as String);
        }
      } catch (_) {
        warning = '已保存的书源配置无法读取，保留原数据。请重新导入可用规则。';
      }
    }
    _entries.addAll(next);
    for (final entry in next.values) {
      _origins.putIfAbsent(
        entry.definition.id,
        () => entry.definition.baseUrl.origin,
      );
    }
    notifyListeners();
  }

  final _removedBuiltIns = <String>{};
  Future<void> _change(
    void Function(Map<String, InstalledRuleSource>, Set<String>) change,
  ) {
    final next = _writes.then((_) async {
      final entries = Map<String, InstalledRuleSource>.from(_entries);
      final removed = Set<String>.from(_removedBuiltIns);
      change(entries, removed);
      final origins = Map<String, String>.from(_origins);
      for (final entry in entries.values) {
        final definition = entry.definition;
        final pinned = origins[definition.id];
        if (pinned != null && pinned != definition.baseUrl.origin) {
          throw StateError('此书源 ID 已用于其他站点，请另存为新书源。');
        }
        origins[definition.id] = definition.baseUrl.origin;
      }
      if (origins.length > 1000) throw StateError('书源身份数量已达上限');
      await _write(
        jsonEncode({
          'version': 1,
          'entries':
              entries.values
                  .map(
                    (e) => {
                      'definition': e.definition.toJson(),
                      'enabled': e.enabled,
                      'builtIn': e.builtIn,
                    },
                  )
                  .toList(),
          'removedBuiltIns': removed.toList(),
          'origins': origins,
        }),
      );
      for (final id in {..._entries.keys, ...entries.keys}) {
        if (!identical(_entries[id], entries[id])) {
          _revisions[id] = revision(id) + 1;
        }
      }
      _entries
        ..clear()
        ..addAll(entries);
      _origins
        ..clear()
        ..addAll(origins);
      _removedBuiltIns
        ..clear()
        ..addAll(removed);
      notifyListeners();
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> install(
    List<RuleSourceDefinition> definitions, {
    bool replace = false,
  }) => _change((entries, removed) {
    if (definitions.map((d) => d.id).toSet().length != definitions.length) {
      throw const FormatException('此次导入包含重复书源 ID');
    }
    if (entries.length +
            definitions.where((d) => !entries.containsKey(d.id)).length >
        100) {
      throw const FormatException('最多保存 100 个规则书源');
    }
    for (final definition in definitions) {
      final existing = entries[definition.id];
      if (existing != null && !replace) {
        throw StateError('书源 ${definition.name} 已存在，请选择替换或另存');
      }
      if (existing != null &&
          existing.definition.baseUrl.origin != definition.baseUrl.origin) {
        throw StateError('域名已改变，请另存为新书源，避免混用原书籍数据');
      }
      entries[definition.id] = InstalledRuleSource(
        definition,
        enabled: existing?.enabled ?? true,
        builtIn: existing?.builtIn ?? false,
      );
      removed.remove(definition.id);
    }
  });
  Future<void> setEnabled(String id, bool enabled) => _change((entries, _) {
    final value = entries[id];
    if (value != null) entries[id] = value.copyWith(enabled: enabled);
  });
  Future<void> rename(String id, String name) => _change((entries, _) {
    final entry = entries[id];
    if (entry == null || name.trim().isEmpty) return;
    final raw = entry.definition.toJson();
    (raw['source'] as Map)['name'] = name.trim();
    entries[id] = entry.copyWith(
      definition: RuleSourceDefinition.fromJson(raw),
    );
  });
  Future<void> remove(String id) => _change((entries, removed) {
    if (entries.remove(id)?.builtIn == true) removed.add(id);
  });
}
