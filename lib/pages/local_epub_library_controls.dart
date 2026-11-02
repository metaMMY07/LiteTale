import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/epub/epub_import_queue.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/epub/local_epub_organization.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

Future<String?> chooseEpubCollection(
  BuildContext context,
  LocalEpubOrganizationStore store, {
  required String title,
  String? initial,
  bool allowUnfiled = false,
}) {
  var selected = initial != null && store.hasCollection(initial) ? initial : '';
  return showAdaptiveDialog<String>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setState) => AlertDialog.adaptive(
                title: Text(title),
                content: SizedBox(
                  width: 420,
                  height: math.min(300, MediaQuery.sizeOf(ctx).height * .4),
                  child: ListView(
                    children: [
                      if (allowUnfiled)
                        AppRadioListTile<String>(
                          value: '',
                          groupValue: selected,
                          onChanged:
                              (value) => setState(() => selected = value!),
                          title: const Text('不指定分类'),
                        ),
                      for (final collection in store.collections)
                        AppRadioListTile<String>(
                          value: collection.id,
                          groupValue: selected,
                          onChanged:
                              (value) => setState(() => selected = value!),
                          title: Text(collection.name),
                        ),
                      if (store.collections.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('请先通过「管理分类」创建分类。'),
                        ),
                    ],
                  ),
                ),
                actions: [
                  AppButton.text(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  AppButton.filled(
                    onPressed:
                        selected.isEmpty && !allowUnfiled
                            ? null
                            : () => Navigator.pop(ctx, selected),
                    child: Text(allowUnfiled ? '开始导入' : '加入分类'),
                  ),
                ],
              ),
        ),
  );
}

Future<String?> editEpubCollectionName(BuildContext context, {String? name}) =>
    showAdaptiveDialog<String>(
      context: context,
      builder: (_) => _CollectionNameDialog(name: name),
    );

class _CollectionNameDialog extends StatefulWidget {
  const _CollectionNameDialog({this.name});
  final String? name;
  @override
  State<_CollectionNameDialog> createState() => _CollectionNameDialogState();
}

class _CollectionNameDialogState extends State<_CollectionNameDialog> {
  late final _controller = TextEditingController(text: widget.name);
  String? _error;
  void _save() {
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = '请输入分类名称');
    } else {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog.adaptive(
    title: Text(widget.name == null ? '新建分类' : '重命名分类'),
    content: Padding(
      padding: const EdgeInsets.only(top: 12),
      child: AppTextField(
        key: const ValueKey('epub-collection-name'),
        controller: _controller,
        autofocus: true,
        inputFormatters: [LengthLimitingTextInputFormatter(80)],
        decoration: InputDecoration(
          hintText: '例如：待看、校园、某个系列',
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      AppButton.text(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      AppButton.filled(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class LocalEpubCollectionsPage extends StatefulWidget {
  const LocalEpubCollectionsPage({super.key, required this.library});
  final LocalEpubLibrary library;
  @override
  State<LocalEpubCollectionsPage> createState() =>
      _LocalEpubCollectionsPageState();
}

class _LocalEpubCollectionsPageState extends State<LocalEpubCollectionsPage> {
  bool _busy = false;
  String? _error;
  LocalEpubOrganizationStore get store => widget.library.organization;

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is EpubOrganizationException
                      ? error.message
                      : '未能保存分类，请稍后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await editEpubCollectionName(context);
    if (name != null && mounted) {
      await _perform(() async {
        await store.createCollection(name);
      });
    }
  }

  Future<void> _action(EpubCollection collection, String action) async {
    if (action == 'rename') {
      final name = await editEpubCollectionName(context, name: collection.name);
      if (name != null && mounted) {
        await _perform(() => store.renameCollection(collection.id, name));
      }
    } else if (action == 'remove') {
      final confirmed = await showAdaptiveDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog.adaptive(
              title: const Text('移除分类'),
              content: Text('移除「${collection.name}」？书籍仍保留在「全部」和其他分类中。'),
              actions: [
                AppButton.text(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                AppButton.filled(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('移除分类'),
                ),
              ],
            ),
      );
      if (confirmed == true && mounted) {
        await _perform(() => store.removeCollection(collection.id));
      }
    } else {
      await _perform(
        () => store.moveCollection(collection.id, action == 'up' ? -1 : 1),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      store,
      widget.library,
      widget.library.imports,
    ]),
    builder: (context, _) {
      final enabled =
          store.isReady && !_busy && !widget.library.imports.isRunning;
      return Scaffold(
        appBar: AppBar(title: const Text('管理分类')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('一本书可以加入多个分类。整理分类不会复制或移动 EPUB，也不会改变阅读记录。'),
              const SizedBox(height: 16),
              AppButton.filledIcon(
                onPressed: enabled ? _create : null,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建分类'),
              ),
              if (_error ?? store.loadError case final String error)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (widget.library.imports.isRunning)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('正在导入书籍，完成后即可调整分类。'),
                ),
              const SizedBox(height: 12),
              for (var i = 0; i < store.collections.length; i++)
                AppleGlassCard(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(store.collections[i].name),
                    subtitle: Text(
                      '${widget.library.books.where((b) => store.contains(store.collections[i].id, b.id)).length} 本',
                    ),
                    trailing: AppPopupMenuButton<String>(
                      tooltip: '${store.collections[i].name}的分类操作',
                      enabled: enabled,
                      onSelected:
                          (action) => _action(store.collections[i], action),
                      itemBuilder:
                          (_) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('重命名'),
                            ),
                            PopupMenuItem(
                              value: 'up',
                              enabled: i > 0,
                              child: const Text('上移'),
                            ),
                            PopupMenuItem(
                              value: 'down',
                              enabled: i < store.collections.length - 1,
                              child: const Text('下移'),
                            ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('移除分类'),
                            ),
                          ],
                    ),
                  ),
                ),
              if (store.collections.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '还没有分类，创建一个来整理你的书籍。',
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class EpubImportPanel extends StatelessWidget {
  const EpubImportPanel({super.key, required this.queue});
  final EpubImportQueue queue;
  @override
  Widget build(BuildContext context) {
    if (!queue.hasResults) return const SizedBox.shrink();
    final current =
        queue.items
            .where((i) => i.status == EpubImportStatus.importing)
            .firstOrNull;
    return AppleGlassCard(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (queue.isRunning)
              const AppLoadingIndicator(size: 24)
            else
              Icon(
                queue.count(EpubImportStatus.failed) == 0
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    queue.isRunning
                        ? '正在导入 ${queue.completed}/${queue.items.length}'
                        : '导入完成',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    current?.name ??
                        '成功 ${queue.count(EpubImportStatus.imported)} · 重复 ${queue.count(EpubImportStatus.duplicate)} · 失败 ${queue.count(EpubImportStatus.failed)} · 停止 ${queue.count(EpubImportStatus.cancelled)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (queue.classificationFailures > 0)
                    Text('${queue.classificationFailures} 本分类未保存'),
                ],
              ),
            ),
            AppButton.text(
              onPressed: () => showEpubImportResults(context, queue),
              child: const Text('详情'),
            ),
            if (!queue.isRunning)
              AppIconButton(
                tooltip: '关闭导入结果',
                icon: const Icon(Icons.close),
                onPressed: queue.dismiss,
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showEpubImportResults(
  BuildContext context,
  EpubImportQueue queue,
) => showAdaptiveDialog<void>(
  context: context,
  builder:
      (ctx) => AnimatedBuilder(
        animation: queue,
        builder:
            (ctx, _) => AlertDialog.adaptive(
              title: Text(
                queue.isRunning
                    ? '导入中 ${queue.completed}/${queue.items.length}'
                    : '导入结果',
              ),
              content: SizedBox(
                width: 440,
                height: math.min(360, MediaQuery.sizeOf(ctx).height * .45),
                child: ListView.builder(
                  itemCount: queue.items.length,
                  itemBuilder: (_, index) {
                    final item = queue.items[index];
                    final (label, icon) = switch (item.status) {
                      EpubImportStatus.queued => ('等待导入', Icons.schedule),
                      EpubImportStatus.importing => (
                        '正在导入',
                        Icons.hourglass_top,
                      ),
                      EpubImportStatus.imported => (
                        item.result?.upgraded == true
                            ? '原书样式已更新，记录已保留'
                            : '导入成功',
                        Icons.check_circle_outline,
                      ),
                      EpubImportStatus.duplicate => (
                        '已在书库中，已跳过',
                        Icons.library_add_check_outlined,
                      ),
                      EpubImportStatus.failed => (
                        item.error ?? '导入失败',
                        Icons.error_outline,
                      ),
                      EpubImportStatus.cancelled => (
                        '已停止，可继续导入',
                        Icons.pause_circle_outline,
                      ),
                    };
                    return ListTile(
                      leading: Icon(icon),
                      title: Text(item.name),
                      subtitle: Text(
                        [
                          label,
                          if (item.classificationError != null)
                            item.classificationError!,
                          if (item.warning != null) item.warning!,
                        ].join('\n'),
                      ),
                    );
                  },
                ),
              ),
              actions: [
                if (queue.isRunning && queue.count(EpubImportStatus.queued) > 0)
                  AppButton.text(
                    onPressed: queue.stop,
                    child: const Text('停止后续导入'),
                  ),
                if (!queue.isRunning &&
                    queue.count(EpubImportStatus.failed) > 0)
                  AppButton.text(
                    onPressed: () => unawaited(queue.retryFailed()),
                    child: const Text('重试失败项'),
                  ),
                if (!queue.isRunning &&
                    queue.count(EpubImportStatus.cancelled) > 0)
                  AppButton.text(
                    onPressed: () => unawaited(queue.resumeCancelled()),
                    child: const Text('继续未完成'),
                  ),
                if (!queue.isRunning && queue.classificationFailures > 0)
                  AppButton.text(
                    onPressed: () => unawaited(queue.retryClassification()),
                    child: const Text('重试分类'),
                  ),
                AppButton.filled(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(queue.isRunning ? '返回书库' : '完成'),
                ),
              ],
            ),
      ),
);
