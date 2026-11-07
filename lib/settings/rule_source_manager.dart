import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/sources/source_website.dart';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/sources/rules/rule_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/services/source_import_file.dart';
import 'package:wild/widgets/app_loading_indicator.dart';

class RuleSourceManager extends StatefulWidget {
  const RuleSourceManager({super.key, this.registry, this.pickFile});
  final RuleSourceRegistry? registry;
  final Future<XFile?> Function()? pickFile;
  @override
  State<RuleSourceManager> createState() => _RuleSourceManagerState();
}

enum _SourceImportInput { file, link, paste }

class _RuleSourceManagerState extends State<RuleSourceManager> {
  bool busy = false;
  bool loading = false;
  RuleSourceRegistry get registry =>
      widget.registry ?? RuleSourceRegistry.instance;

  Future<void> _import(_SourceImportInput input) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final String raw;
      switch (input) {
        case _SourceImportInput.file:
          final file = await (widget.pickFile ?? pickSourceImportFile)();
          if (file == null || !mounted) return;
          setState(() => loading = true);
          raw = await readSourceImportFile(
            file,
          ).timeout(const Duration(seconds: 15));
        case _SourceImportInput.link:
          final link = await _input(context, '导入书源链接', 'HTTPS JSON 文件地址');
          if (link == null || link.trim().isEmpty || !mounted) return;
          setState(() => loading = true);
          raw = await fetchSourceImport(Uri.parse(link.trim()));
        case _SourceImportInput.paste:
          final value = await _input(
            context,
            '粘贴书源规则',
            'JSON 规则',
            multiline: true,
          );
          if (value == null || value.trim().isEmpty) return;
          raw = value;
      }
      final items = inspectSourceImport(
        raw,
        installedSources: registry.entries,
      );
      if (!mounted) return;
      if (loading) setState(() => loading = false);
      await Navigator.of(context).push(
        HorizontalCoverPageRoute(
          builder:
              (_) => RuleImportPreviewPage(items: items, registry: registry),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          loading = false;
        });
      }
    }
  }

  Future<void> _action(InstalledRuleSource entry, String action) async {
    try {
      final id = entry.definition.id;
      switch (action) {
        case 'website':
          final uri = sourceWebsite(
            SourceId.rule(id),
            ruleBaseUrl: entry.definition.baseUrl,
          );
          if (uri != null && mounted) await openSourceWebsite(context, uri);
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const Text(
                '支持 LiteTale JSON 和部分阅读书源规则。预览新增、更新及不兼容项后，再选择要保存的书源。',
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  AppButton.tonalIcon(
                    onPressed:
                        busy ? null : () => _import(_SourceImportInput.file),
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('本地文件'),
                  ),
                  AppButton.outlinedIcon(
                    onPressed:
                        busy ? null : () => _import(_SourceImportInput.link),
                    icon: const Icon(Icons.link),
                    label: const Text('链接导入'),
                  ),
                  AppButton.outlinedIcon(
                    onPressed:
                        busy ? null : () => _import(_SourceImportInput.paste),
                    icon: const Icon(Icons.content_paste_rounded),
                    label: const Text('粘贴规则'),
                  ),
                ],
              ),
            ),
            if (loading)
              usesAppleGlass
                  ? const Center(child: AppLoadingIndicator(size: 24))
                  : const LinearProgressIndicator(),
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
                    '${entry.builtIn ? '内置' : '导入'} · ${entry.definition.version} · ${entry.enabled ? '已启用' : '已停用'}\n${entry.definition.baseUrl.origin}/',
                  ),
                  isThreeLine: true,
                  onTap: entry.enabled ? () => _action(entry, 'use') : null,
                  trailing: AppPopupMenuButton<String>(
                    onSelected: (value) => _action(entry, value),
                    itemBuilder:
                        (_) => [
                          const PopupMenuItem(
                            value: 'website',
                            child: Text('打开原网站'),
                          ),
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
  bool multiline = false,
}) => showAdaptiveDialog<String>(
  context: context,
  builder:
      (_) => _SourceInputDialog(
        title: title,
        label: label,
        initial: initial,
        multiline: multiline,
      ),
);

class _SourceInputDialog extends StatefulWidget {
  const _SourceInputDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.multiline,
  });

  final String title, label, initial;
  final bool multiline;

  @override
  State<_SourceInputDialog> createState() => _SourceInputDialogState();
}

class _SourceInputDialogState extends State<_SourceInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog.adaptive(
    title: Text(widget.title),
    scrollable: true,
    content: AppTextField(
      controller: _controller,
      autofocus: true,
      maxLines: widget.multiline ? 6 : 1,
      minLines: widget.multiline ? 3 : null,
      keyboardType: widget.multiline ? TextInputType.multiline : null,
      autocorrect: !widget.multiline,
      enableSuggestions: !widget.multiline,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      AppButton.text(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      AppButton.filled(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(widget.multiline ? '预览' : '确定'),
      ),
    ],
  );
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
  final copies = <int>{};
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.items.length; i++) {
      final status = widget.items[i].status;
      if (status == SourceImportStatus.added ||
          status == SourceImportStatus.updated) {
        selected.add(i);
      } else if (status == SourceImportStatus.conflict) {
        copies.add(i);
      }
    }
  }

  Future<void> _save() async {
    if (saving || selected.isEmpty) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final definitions = <RuleSourceDefinition>[];
      final updateTimes = <String, int>{};
      final previewedSources = <String, InstalledRuleSource?>{};
      var sequence = DateTime.now().microsecondsSinceEpoch;
      for (final index in selected.toList()..sort()) {
        final item = widget.items[index];
        var value = item.definition!;
        if (copies.contains(index)) {
          final copy = value.toJson(
            id:
                '${value.id.substring(0, math.min(35, value.id.length))}_copy_${sequence++}',
            name: '${value.name}（副本）',
          );
          // An independent copy must not compete with the original identity.
          (copy['source'] as Map<String, dynamic>).remove('importKey');
          value = RuleSourceDefinition.fromJson(copy);
        }
        definitions.add(value);
        previewedSources[value.id] =
            copies.contains(index) ? null : item.existing;
        if (item.updateTime case final time?) updateTimes[value.id] = time;
      }
      await registry.install(
        definitions,
        replace: true,
        updateTimes: updateTimes,
        previewedSources: previewedSources,
      );
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
              '共 ${widget.items.length} 项，已选 ${selected.length} 项。请选择要保存的书源。',
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
          title: Text(
            item.name == null ? '第 ${index + 1} 项未通过' : '${item.name} · 未通过',
          ),
          subtitle: Text(item.error ?? '规则无效'),
        ),
      );
    }
    final existing = item.existing;
    final copyOnly = item.status == SourceImportStatus.conflict;
    final unchanged = item.status == SourceImportStatus.unchanged;
    final status = switch (item.status) {
      SourceImportStatus.added => '新增',
      SourceImportStatus.updated => '有更新',
      SourceImportStatus.unchanged => '规则相同',
      SourceImportStatus.older => '版本较旧',
      SourceImportStatus.conflict => '来源冲突',
      SourceImportStatus.invalid => '未通过',
    };
    final notices = <String>[
      if (copyOnly) ...item.notices,
      if (!source.capabilities.discover && source.capabilities.search)
        '此书源通过搜索使用，未提供首页推荐。',
      if (!source.capabilities.images) '当前规则仅提供文字阅读，不包含插图。',
      if (item.notices.any(
        (notice) => notice.contains('kind') && notice.contains('跳过'),
      ))
        '部分分类信息未导入，目录与正文规则已保留。',
    ];
    return AppleGlassCard(
      child: Column(
        children: [
          AppCheckboxListTile(
            value: selected.contains(index),
            onChanged:
                saving || (unchanged && !copies.contains(index))
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
              '$status · ${source.version}\n${source.baseUrl}\n${source.capabilities.search ? '支持站内搜索' : '按目录逐页查找'} · 目录与正文 · ${source.capabilities.images ? '支持插图' : '文字阅读'}',
            ),
          ),
          if (notices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final notice in notices)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        notice,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          if (copyOnly)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text('选中后另存为新书源。'),
            )
          else if (existing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: AppDropdownButtonFormField<bool>(
                value: copies.contains(index),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '已有版本 ${existing.definition.version}',
                ),
                items: [
                  DropdownMenuItem(
                    value: false,
                    child: Text(unchanged ? '跳过相同规则' : '替换规则，保留原书源数据'),
                  ),
                  const DropdownMenuItem(value: true, child: Text('另存为新书源')),
                ],
                onChanged:
                    saving
                        ? null
                        : (value) => setState(() {
                          if (value == true) {
                            copies.add(index);
                            selected.add(index);
                          } else {
                            copies.remove(index);
                            if (unchanged) selected.remove(index);
                          }
                        }),
              ),
            ),
        ],
      ),
    );
  }
}
