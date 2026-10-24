import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/sources/rules/rule_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class RuleSourceManager extends StatefulWidget {
  const RuleSourceManager({super.key});
  @override
  State<RuleSourceManager> createState() => _RuleSourceManagerState();
}

class _RuleSourceManagerState extends State<RuleSourceManager> {
  bool busy = false;
  final registry = RuleSourceRegistry.instance;

  Future<void> _import(bool fromLink) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      String raw;
      if (fromLink) {
        final link = await _input(context, '导入书源链接', 'HTTPS JSON 文件地址');
        if (link == null || link.trim().isEmpty) return;
        raw = await fetchSourceImport(Uri.parse(link.trim()));
      } else {
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'JSON 书源',
              extensions: ['json'],
              mimeTypes: ['application/json'],
            ),
          ],
        );
        if (file == null) return;
        if (await file.length() > 2 * 1024 * 1024) {
          throw const FormatException('书源文件不能超过 2 MB');
        }
        raw = utf8.decode(await file.readAsBytes()).replaceFirst('\uFEFF', '');
      }
      final items = inspectSourceImport(raw);
      if (!mounted) return;
      await Navigator.of(context).push(
        HorizontalCoverPageRoute(
          builder: (_) => RuleImportPreviewPage(items: items),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _action(InstalledRuleSource entry, String action) async {
    try {
      final id = entry.definition.id;
      switch (action) {
        case 'use':
          await api.selectSource(SourceId.rule(id));
        case 'rename':
          final name = await _input(
            context,
            '书源名称',
            '输入名称',
            initial: entry.definition.name,
          );
          if (name != null) await registry.rename(id, name);
        case 'enable':
          await registry.setEnabled(id, !entry.enabled);
        case 'remove':
          final yes = await showAdaptiveDialog<bool>(
            context: context,
            builder:
                (ctx) => AlertDialog.adaptive(
                  title: const Text('移除书源规则'),
                  content: const Text('保留这本书源的书架、历史与离线内容。重新导入相同书源后可继续使用。'),
                  actions: [
                    AppButton.text(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    AppButton.filled(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('移除规则'),
                    ),
                  ],
                ),
          );
          if (yes == true) await registry.remove(id);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    builder:
        (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                '添加与管理书源',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '支持 LiteTale JSON 和部分阅读 JSON 规则。导入前会检查兼容情况；当前规则书源使用公开阅读，无需账号。',
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  AppButton.tonalIcon(
                    onPressed: busy ? null : () => _import(false),
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('本地文件'),
                  ),
                  AppButton.outlinedIcon(
                    onPressed: busy ? null : () => _import(true),
                    icon: const Icon(Icons.link),
                    label: const Text('链接导入'),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (registry.warning != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(registry.warning!),
              ),
            for (final entry in registry.entries)
              AppleGlassCard(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: Icon(
                    entry.enabled
                        ? Icons.auto_stories_outlined
                        : Icons.pause_circle_outline,
                  ),
                  title: Text(entry.definition.name),
                  subtitle: Text(
                    '${entry.builtIn ? '内置' : '导入'} · ${entry.definition.version} · ${entry.enabled ? '已启用' : '已停用'}\n${entry.definition.baseUrl.host}',
                  ),
                  isThreeLine: true,
                  onTap: entry.enabled ? () => _action(entry, 'use') : null,
                  trailing: AppPopupMenuButton<String>(
                    onSelected: (value) => _action(entry, value),
                    itemBuilder:
                        (_) => [
                          if (entry.enabled)
                            const PopupMenuItem(
                              value: 'use',
                              child: Text('使用此书源'),
                            ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('重命名'),
                          ),
                          PopupMenuItem(
                            value: 'enable',
                            child: Text(entry.enabled ? '停用' : '启用'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('移除规则'),
                          ),
                        ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
  );
}

Future<String?> _input(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showAdaptiveDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog.adaptive(
            title: Text(title),
            content: AppTextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
            ),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              AppButton.filled(
                onPressed: () => Navigator.pop(ctx, controller.text),
                child: const Text('确定'),
              ),
            ],
          ),
    );
  } finally {
    // The route's exit frame may still read the field after showDialog returns.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }
}

class RuleImportPreviewPage extends StatefulWidget {
  const RuleImportPreviewPage({super.key, required this.items, this.registry});
  final List<SourceImportItem> items;
  final RuleSourceRegistry? registry;
  @override
  State<RuleImportPreviewPage> createState() => _RuleImportPreviewPageState();
}

class _RuleImportPreviewPageState extends State<RuleImportPreviewPage> {
  RuleSourceRegistry get registry =>
      widget.registry ?? RuleSourceRegistry.instance;
  final selected = <int>{};
  final modes = <int, String>{};
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.items.length; i++) {
      final source = widget.items[i].definition;
      if (source != null) {
        selected.add(i);
        modes[i] = registry[source.id] == null ? 'new' : 'copy';
      }
    }
  }

  Future<void> _save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final definitions = <RuleSourceDefinition>[];
      var sequence = DateTime.now().microsecondsSinceEpoch;
      for (final index in selected) {
        final value = widget.items[index].definition!;
        definitions.add(
          modes[index] == 'copy'
              ? RuleSourceDefinition.fromJson(
                value.toJson(
                  id:
                      '${value.id.substring(0, math.min(35, value.id.length))}_copy_${sequence++}',
                  name: '${value.name}（副本）',
                ),
              )
              : value,
        );
      }
      await registry.install(definitions, replace: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入 ${definitions.length} 个书源')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('确认导入书源')),
    body: LeftAlignedScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '可用 ${widget.items.where((e) => e.definition != null).length} / ${widget.items.length} 个。请选择要导入的规则。',
            ),
          ),
          for (var index = 0; index < widget.items.length; index++)
            _item(index),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: AppButton.filledIcon(
              onPressed: saving || selected.isEmpty ? null : _save,
              icon: const Icon(Icons.download_done_rounded),
              label: Text(saving ? '正在保存…' : '导入所选书源'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _item(int index) {
    final item = widget.items[index];
    final source = item.definition;
    if (source == null) {
      return AppleGlassCard(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text('第 ${index + 1} 项未通过'),
          subtitle: Text(item.error ?? '规则无效'),
        ),
      );
    }
    final existing = registry[source.id];
    return AppleGlassCard(
      child: Column(
        children: [
          AppCheckboxListTile(
            value: selected.contains(index),
            onChanged:
                saving
                    ? null
                    : (value) => setState(() {
                      if (value == true) {
                        selected.add(index);
                      } else {
                        selected.remove(index);
                      }
                    }),
            title: Text(source.name),
            subtitle: Text(
              '${source.baseUrl.host} · ${source.version}\n${source.capabilities.search ? '支持站内搜索' : '按目录逐页查找'} · 目录与正文 · ${source.capabilities.images ? '支持插图' : '文字阅读'}',
            ),
          ),
          if (existing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: AppDropdownButtonFormField<String>(
                value: modes[index] == 'new' ? 'replace' : modes[index],
                decoration: InputDecoration(
                  labelText: '已有版本 ${existing.definition.version}',
                ),
                items: const [
                  DropdownMenuItem(value: 'copy', child: Text('另存为新书源')),
                  DropdownMenuItem(
                    value: 'replace',
                    child: Text('替换规则，保留原书源数据'),
                  ),
                ],
                onChanged:
                    saving
                        ? null
                        : (value) => setState(() => modes[index] = value!),
              ),
            ),
        ],
      ),
    );
  }
}
