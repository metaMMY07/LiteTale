import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/settings/reader_settings_page.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/ios_dock_insets.dart';
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
import 'package:wild/widgets/platform_controls.dart';

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UpdateCubit, UpdateState>(
      builder: (context, state) {
        if (usesAppleGlass) return _iosPage(context, state);
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

  Widget _iosPage(BuildContext context, UpdateState state) {
    final theme = Theme.of(context);
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    void open(Widget page) => openSettingsPage(context, page);

    return Scaffold(
      appBar:
          canPop
              ? AppBar(
                leading: AppIconButton(
                  tooltip: '返回',
                  icon: const Icon(CupertinoIcons.chevron_back),
                  onPressed: () => Navigator.maybePop(context),
                ),
              )
              : null,
      body: RepaintBoundary(
        child: SafeArea(
          top: !canPop,
          bottom: false,
          child: LeftAlignedScrollView(
            key: const PageStorageKey('ios-more-scroll'),
            phoneInset: 16,
            topInset: 16,
            bottomInset:
                20 +
                MediaQuery.paddingOf(context).bottom -
                IosDockInsets.bottomOf(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    '我的',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IosSettingsSection(
                  key: const ValueKey('more-navigation-card'),
                  title: '账号',
                  rows: [
                    IosSettingsRow(
                      key: const ValueKey('more-entry-source'),
                      icon: CupertinoIcons.person_crop_circle,
                      title: '书源与账号',
                      description: '切换书源、导入规则和管理登录',
                      onTap: () => open(const SourceSettingsPage()),
                    ),
                  ],
                ),
                IosSettingsSection(
                  title: '通用',
                  rows: [
                    IosSettingsRow(
                      icon: CupertinoIcons.book,
                      title: '阅读',
                      description: '排版、翻页和阅读方式',
                      onTap: () => open(const ReaderSettingsPage()),
                    ),
                    IosSettingsRow(
                      key: const ValueKey('more-entry-display'),
                      icon: CupertinoIcons.paintbrush,
                      title: '外观',
                      description: '主题、颜色和字体',
                      onTap:
                          () => open(const SettingsPage(appearanceOnly: true)),
                    ),
                  ],
                ),
                IosSettingsSection(
                  title: '数据',
                  rows: [
                    IosSettingsRow(
                      icon: CupertinoIcons.arrow_down_to_line,
                      title: '离线下载',
                      description: '管理已下载的书籍',
                      onTap: () => open(const NovelDownloadPage()),
                    ),
                    IosSettingsRow(
                      icon: CupertinoIcons.chart_bar,
                      title: '阅读统计',
                      description: '查看阅读活动与时长',
                      onTap: () => open(const ReadingStatisticsPage()),
                    ),
                    IosSettingsRow(
                      icon: CupertinoIcons.archivebox,
                      title: '缓存',
                      description: '管理接口缓存',
                      onTap: () => open(const CacheSettingsPage()),
                    ),
                  ],
                ),
                IosSettingsSection(
                  title: '关于',
                  rows: [
                    IosSettingsRow(
                      key: const ValueKey('more-entry-about'),
                      icon: CupertinoIcons.info_circle,
                      title: '应用相关',
                      description:
                          state.updateInfo == null ? '版本、更新和开源信息' : '发现新版本',
                      onTap: () => Navigator.pushNamed(context, '/about'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
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
        bottomInset:
            12 +
            MediaQuery.paddingOf(context).bottom -
            IosDockInsets.bottomOf(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppleGlassCard.filled(
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
                  AppleGlassCard.filled(
                    key: const ValueKey('more-navigation-card'),
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    color: usesMaterialYou ? colors.surfaceContainerLow : null,
                    child: SettingsTileGroup(children: entries),
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
