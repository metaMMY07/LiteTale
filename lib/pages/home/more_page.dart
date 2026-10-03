import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/account_page.dart';
import 'package:wild/pages/home/settings_page.dart';
import 'package:wild/pages/home/font_settings_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/pages/novel/novel_download_page.dart';
import 'package:wild/settings/source_settings_page.dart';
import 'package:wild/settings/reading_statistics_page.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UpdateCubit, UpdateState>(
      builder: (context, state) {
        if (usesMaterialYou) return _mobilePage(context, state);
        return Scaffold(
          appBar: AppBar(title: const Text('更多')),
          body: LeftAlignedScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('下载'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      HorizontalCoverPageRoute(
                        builder: (context) => const NovelDownloadPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('账户'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      HorizontalCoverPageRoute(
                        builder: (context) => const AccountPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('显示'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      HorizontalCoverPageRoute(
                        builder: (context) => const SettingsPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.text_fields_rounded),
                  title: const Text('字体设置'),
                  subtitle: const Text('全局界面与小说阅读字体'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => Navigator.push(
                        context,
                        HorizontalCoverPageRoute(
                          builder: (_) => const FontSettingsPage(),
                        ),
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.updateInfo != null)
                        Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '新版本',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () {
                    Navigator.pushNamed(context, '/about');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _mobilePage(BuildContext context, UpdateState state) {
    final colors = Theme.of(context).colorScheme;
    void open(Widget page) =>
        Navigator.push(context, HorizontalCoverPageRoute(builder: (_) => page));
    Widget entry(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback onTap, {
      Key? key,
    }) => InkWell(
      key: key,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 84),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: colors.secondaryContainer,
                foregroundColor: colors.onSecondaryContainer,
                child: Icon(icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );

    final entries = <Widget>[
      entry(
        Icons.download_outlined,
        '离线下载',
        '随时继续阅读',
        () => open(const NovelDownloadPage()),
      ),
      entry(
        Icons.person_outline_rounded,
        '书源与账号',
        '管理登录与账户信息',
        () => open(const SourceSettingsPage()),
        key: const ValueKey('more-entry-source'),
      ),
      entry(
        Icons.palette_outlined,
        '显示',
        '主题、字体与阅读排版',
        () => open(const SettingsPage()),
        key: const ValueKey('more-entry-display'),
      ),
      entry(
        Icons.text_fields_rounded,
        '字体设置',
        '分别导入界面字体与阅读字体',
        () => open(const FontSettingsPage()),
      ),
      entry(
        Icons.insights_outlined,
        '阅读统计',
        '查看阅读活动与时长',
        () => open(const ReadingStatisticsPage()),
      ),
      entry(
        Icons.info_outline_rounded,
        '关于 LiteTale',
        state.updateInfo == null ? '版本与开源信息' : '发现新版本',
        () => Navigator.pushNamed(context, '/about'),
        key: const ValueKey('more-entry-about'),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: LeftAlignedScrollView(
        phoneInset: 20,
        tabletInset: 32,
        topInset: 12,
        // The home Scaffold extends beneath its glass navigation bar. Reserve
        // its inherited inset so the final operation can scroll above the bar.
        bottomInset: 12 + MediaQuery.paddingOf(context).bottom,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card.filled(
                    margin: EdgeInsets.zero,
                    color: colors.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.auto_stories_rounded,
                            size: 36,
                            color: colors.onPrimaryContainer,
                          ),
                          const SizedBox(height: 20),
                          BlocBuilder<AuthCubit, AuthState>(
                            builder:
                                (context, auth) => Text(
                                  activeSource.value == SourceId.wenku8
                                      ? auth.username ?? '你的阅读空间'
                                      : '${activeSource.value.label}阅读空间',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineSmall?.copyWith(
                                    color: colors.onPrimaryContainer,
                                  ),
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '收藏喜欢的故事，按自己的节奏阅读。',
                            style: TextStyle(color: colors.onPrimaryContainer),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card.filled(
                    key: const ValueKey('more-navigation-card'),
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < entries.length;
                          index++
                        ) ...[
                          if (index > 0)
                            Divider(
                              height: 1,
                              indent: 76,
                              endIndent: 16,
                              color: colors.outlineVariant,
                            ),
                          entries[index],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
