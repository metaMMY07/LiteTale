import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/source_settings.dart';
import 'rule_source_manager.dart';

class SourceSettingsPage extends StatelessWidget {
  const SourceSettingsPage({super.key});

  void _manageSources(BuildContext context) => Navigator.of(
    context,
  ).push(HorizontalCoverPageRoute(builder: (_) => const _ManageSourcesPage()));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsAppBar(context, '书源与账号'),
    body: LeftAlignedScrollView(
      topInset: 12,
      bottomInset: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SourceSettings(),
          const SizedBox(height: 12),
          SettingsCard(
            margin: EdgeInsets.zero,
            filled: true,
            child:
                usesAppleGlass
                    ? IosSettingsRow(
                      icon: CupertinoIcons.folder,
                      title: '添加与管理书源',
                      onTap: () => _manageSources(context),
                    )
                    : ListTile(
                      leading: const Icon(Icons.library_add_outlined),
                      title: const Text('添加与管理书源'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _manageSources(context),
                    ),
          ),
        ],
      ),
    ),
  );
}

class _ManageSourcesPage extends StatelessWidget {
  const _ManageSourcesPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsAppBar(context, '管理书源'),
    body: LeftAlignedCustomScrollView(
      bottomInset: 28,
      slivers: [
        const RuleSourceManager(),
        if (!usesAppleGlass)
          SliverToBoxAdapter(
            child: SettingsGroup(
              title: '缓存',
              icon: Icons.storage_outlined,
              children: [
                SettingsEntry(
                  icon: Icons.cleaning_services_outlined,
                  title: '清除接口缓存',
                  description: '保留账号、书架和阅读记录',
                  onTap: () => _clearCache(context),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class CacheSettingsPage extends StatelessWidget {
  const CacheSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsAppBar(context, '缓存'),
    body: LeftAlignedScrollView(
      bottomInset: 24,
      child: IosSettingsSection(
        title: '接口缓存',
        rows: [
          IosSettingsRow(
            icon: CupertinoIcons.trash,
            title: '清除接口缓存',
            description: '保留账号、书架和阅读记录',
            onTap: () => _clearCache(context),
          ),
        ],
      ),
    ),
  );
}

Future<void> _clearCache(BuildContext context) async {
  final yes = await showAdaptiveDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog.adaptive(
          title: const Text('清除接口缓存'),
          content: const Text('下次打开页面时会重新获取数据。'),
          actions: [
            AppButton.text(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            AppButton.filled(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除'),
            ),
          ],
        ),
  );
  if (yes == true && context.mounted) {
    await settingsAction(context, cleanAllWebCache, success: '接口缓存已清除');
  }
}
