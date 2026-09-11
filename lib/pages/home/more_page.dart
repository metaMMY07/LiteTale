import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/account_page.dart';
import 'package:wild/pages/home/settings_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/pages/novel/novel_download_page.dart';

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UpdateCubit, UpdateState>(
      builder: (context, state) {
        if (usesMaterialYou) return _mobilePage(context, state);
        return Scaffold(
          appBar: AppBar(title: const Text('更多')),
          body: ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
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
                    MaterialPageRoute(
                      builder: (context) => const AccountPage(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SettingsPage(),
                    ),
                  );
                },
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
        );
      },
    );
  }

  Widget _mobilePage(BuildContext context, UpdateState state) {
    final colors = Theme.of(context).colorScheme;
    void open(Widget page) =>
        Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    Widget entry(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback onTap,
    ) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: colors.secondaryContainer,
        foregroundColor: colors.onSecondaryContainer,
        child: Icon(icon),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
                          activeSource.value == SourceId.wenku8 ? auth.username ?? '你的阅读空间' : '轻书架阅读空间',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(color: colors.onPrimaryContainer),
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
            margin: EdgeInsets.zero,
            child: Column(
              children: [
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
                  () => open(const SettingsPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card.filled(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                entry(
                  Icons.tune_rounded,
                  '阅读与外观',
                  '主题、字体、翻页与阅读习惯',
                  () => open(const SettingsPage()),
                ),
                entry(
                  Icons.info_outline_rounded,
                  '关于 LiteTale',
                  state.updateInfo == null ? '版本与开源信息' : '发现新版本',
                  () => Navigator.pushNamed(context, '/about'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
