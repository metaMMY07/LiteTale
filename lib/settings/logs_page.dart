import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:wild/settings/app_logs.dart';
import 'package:wild/settings/settings_platform.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  bool saving = false;
  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final done = await saveSettingsDocument(
        'LiteTale-log.txt',
        utf8.encode(AppLogs.instance.exportText()),
        mime: 'text/plain',
      );
      if (done && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日志已导出')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日志导出失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('应用日志'),
      actions: [
        IconButton(
          tooltip: '导出日志',
          onPressed: saving ? null : _save,
          icon: const Icon(Icons.save_alt_outlined),
        ),
      ],
    ),
    body: AnimatedBuilder(
      animation: AppLogs.instance,
      builder: (context, _) {
        final entries = AppLogs.instance.entries;
        if (entries.isEmpty) {
          return LeftAlignedScrollView(
            topInset: 24,
            bottomInset: 24,
            child: const Text('还没有操作记录。可在设置中调整日志级别。'),
          );
        }
        return LeftAlignedListView.builder(
          topInset: 12,
          bottomInset: 12,
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            return ListTile(
              title: Text(e.message),
              subtitle: Text('${e.time.toLocal()} · ${e.level}'),
              leading: Icon(
                e.level == 'error' ? Icons.error_outline : Icons.info_outline,
              ),
            );
          },
        );
      },
    ),
  );
}
