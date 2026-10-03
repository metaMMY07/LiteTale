import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/cubits/screen_up_on_reading_property.dart';
import 'package:wild/cubits/screen_up_on_scroll_property.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/methods.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/settings/app_logs.dart';
import 'package:wild/settings/data_snapshot.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/settings/settings_platform.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/system.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';

class DataSettingsPage extends StatefulWidget {
  const DataSettingsPage({super.key, this.initialExport = false});
  final bool initialExport;
  @override
  State<DataSettingsPage> createState() => _DataSettingsPageState();
}

class _DataSettingsPageState extends State<DataSettingsPage> {
  final service = DataSnapshotService();
  bool bookshelves = true, reading = true, settings = true, busy = false;
  late bool exporting = widget.initialExport;
  String status = '';

  Future<void> _run(Future<String?> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '';
    });
    try {
      final result = await action();
      if (mounted && result != null) {
        setState(() => status = result);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (error) {
      await AppLogs.instance.record(
        'error',
        exporting ? '数据快照导出失败' : '数据快照导入失败',
      );
      final message =
          error is FormatException ? error.message : '操作未完成，原有数据已保留，请重试';
      if (mounted) {
        setState(() => status = message);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> _export() async {
    if (reading) await context.read<ReadingStatisticsCubit>().persist();
    final doc = await service.build(
      bookshelves: bookshelves,
      reading: reading,
      settings: settings,
    );
    final now = DateTime.now();
    final name =
        'LiteTale-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.litetale';
    final saved = await saveSettingsDocument(
      name,
      utf8.encode(doc.json),
      mime: 'application/vnd.litetale.snapshot',
    );
    if (!saved) return null;
    await AppLogs.instance.record('info', '数据快照已导出');
    return doc.warnings.isEmpty ? '快照已保存' : '快照已保存；${doc.warnings.join('；')}';
  }

  Future<String?> _import() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'LiteTale 快照',
          extensions: ['litetale', 'json'],
          mimeTypes: [
            'application/vnd.litetale.snapshot',
            'application/json',
            'application/octet-stream',
          ],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > maxSnapshotBytes) {
      throw const FormatException('快照不能超过256 MB');
    }
    final doc = await service.parse(await file.readAsString());
    if (!mounted) return null;
    final overwrite = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('导入数据'),
            content: SingleChildScrollView(
              child: Text(
                '快照时间：${doc.createdAt}\n包含：${[if (doc.hasBookshelves) '本地书架与搜索记录', if (doc.hasReading) '阅读记录与统计', if (doc.hasSettings) '设置、字体与纸张'].join('、')}\n\n'
                '合并会保留已有书架，阅读进度取较新的记录，设置使用快照中的值。\n\n'
                '覆盖会替换快照包含的数据类别：\n'
                '${doc.hasReading ? '• 阅读数据：替换全部书源的本机阅读记录与统计。\n' : ''}'
                '${doc.hasBookshelves ? '• 书架：替换轻书架、轻小说百科的全部本机收藏与搜索记录。\n' : ''}'
                '${doc.hasSettings ? '• 设置：替换主题、排版、字体与纸张设置。\n' : ''}'
                '\n未包含的数据类别保留；账号、登录状态、文库8在线书架和下载不受影响。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('覆盖'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('合并'),
              ),
            ],
          ),
    );
    if (overwrite == null || !mounted) return null;
    if (doc.hasReading) await context.read<ReadingStatisticsCubit>().persist();
    await service.restore(doc, overwrite: overwrite);
    // Storage commit is finished. Report refresh errors distinctly, because a
    // failed reload must not tell the user that a successful import rolled back.
    try {
      if (mounted) await reloadSnapshotSettings(context, doc);
    } catch (_) {
      return '数据已导入，部分显示设置将在重启应用后生效';
    }
    await AppLogs.instance.record('info', '数据快照已导入');
    return '数据已${overwrite ? '覆盖' : '合并'}导入';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(exporting ? '快照数据' : '导入数据')),
    body: LeftAlignedScrollView(
      topInset: 16,
      bottomInset: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('导出快照'),
                icon: Icon(Icons.save_alt_outlined),
              ),
              ButtonSegment(
                value: false,
                label: Text('导入数据'),
                icon: Icon(Icons.file_open_outlined),
              ),
            ],
            selected: {exporting},
            onSelectionChanged:
                busy
                    ? null
                    : (v) => setState(() {
                      exporting = v.first;
                      status = '';
                    }),
          ),
          const SizedBox(height: 20),
          if (exporting) ...[
            CheckboxListTile(
              title: const Text('书架'),
              subtitle: const Text('轻书架与公开书源的本地收藏、搜索记录'),
              value: bookshelves,
              onChanged:
                  busy ? null : (v) => setState(() => bookshelves = v ?? false),
            ),
            CheckboxListTile(
              title: const Text('阅读数据'),
              subtitle: const Text('各书源独立的阅读进度和真实阅读统计'),
              value: reading,
              onChanged:
                  busy ? null : (v) => setState(() => reading = v ?? false),
            ),
            CheckboxListTile(
              title: const Text('设置'),
              subtitle: const Text('主题、排版、导入字体和阅读背景'),
              value: settings,
              onChanged:
                  busy ? null : (v) => setState(() => settings = v ?? false),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '文库8的在线书架保存在其服务器；登录账号、密码、会话和离线下载不写入快照。文件格式为 LiteTale .litetale，不能直接导入其他应用的 .lnr 文件。',
            ),
          ),
          FilledButton.icon(
            onPressed:
                busy || (exporting && !bookshelves && !reading && !settings)
                    ? null
                    : () => _run(exporting ? _export : _import),
            icon: Icon(
              exporting ? Icons.save_alt_outlined : Icons.file_open_outlined,
            ),
            label: Text(exporting ? '保存到文件' : '选择快照文件'),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: ExpressiveLoadingIndicator()),
            ),
          if (status.isNotEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(status)),
        ],
      ),
    ),
  );
}

Future<void> reloadSnapshotSettings(
  BuildContext context,
  SnapshotDocument doc,
) async {
  final statistics = context.read<ReadingStatisticsCubit>();
  final preferences = context.read<SettingsPreferencesCubit>();
  final tasks = <Future<void>>[];
  if (doc.hasReading) tasks.add(statistics.reload());
  if (doc.hasSettings) {
    final root =
        Platform.isAndroid || Platform.isIOS
            ? await dataRoot()
            : await desktopRoot();
    if (!context.mounted) return;
    tasks.addAll([
      preferences.initialize(),
      context.read<FontSettingsCubit>().initialize(root),
      context.read<AppAccentCubit>().load(),
      context.read<ReaderCurlCubit>().load(),
      context.read<ReaderBackgroundCubit>().init(root),
      context.read<FontSizeCubit>().loadFontSize(),
      context.read<LineHeightCubit>().loadLineHeight(),
      context.read<ParagraphSpacingCubit>().loadSpacing(),
      context.read<ThemeCubit>().loadTheme(),
      context.read<ReaderTypeCubit>().loadType(),
      context.read<TopBarHeightCubit>().loadHeight(),
      context.read<BottomBarHeightCubit>().loadHeight(),
      context.read<LeftPaddingCubit>().loadPadding(),
      context.read<RightPaddingCubit>().loadPadding(),
      context.read<VolumeControlCubit>().init(),
      initScreenUpOnReading().then<void>((_) {}),
      initScreenUpOnScroll().then<void>((_) {}),
    ]);
  }
  await Future.wait(tasks);
  AppLogs.instance.level = preferences.state.logLevel;
  sourceRevision.value++;
}
