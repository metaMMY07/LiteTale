import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/login_page.dart';
import 'package:wild/pages/shelf_login_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/shelf_session.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/services/bili_browser.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/material_source_picker.dart';

/// Kept within settings; the rest of the app shows exactly one provider.
class SourceSettings extends StatelessWidget {
  const SourceSettings({super.key});

  Future<void> _selectSource(BuildContext context, SourceId? value) async {
    if (value == null || value == activeSource.value) return;
    try {
      await api.selectSource(value);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('书源选择未能保存，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: sourceRevision,
    builder:
        (context, revision, __) => ValueListenableBuilder<SourceId>(
          valueListenable: activeSource,
          builder:
              (context, source, _) => AppleGlassCard(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '书源与账号',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text('一次使用一个书源。切换后保留各自的登录状态。'),
                      const SizedBox(height: 12),
                      if (usesMaterialYou)
                        MaterialSourcePicker(
                          value: source,
                          sources: api.availableSources,
                          onChanged: (value) => _selectSource(context, value),
                        )
                      else
                        AppDropdownButtonFormField<SourceId>(
                          value: source,
                          decoration: const InputDecoration(labelText: '当前书源'),
                          items:
                              api.availableSources
                                  .map(
                                    (s) => DropdownMenuItem(
                                      value: s,
                                      child: Text(
                                        usesAppleGlass && s.isRule
                                            ? '${s.label}（导入）'
                                            : s.label,
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) => _selectSource(context, value),
                        ),
                      const SizedBox(height: 12),
                      if (source == SourceId.bili)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '公开书源 · 无需登录\n使用原站关键词搜索和完整目录\n收藏与阅读记录保存在本机',
                            ),
                            const SizedBox(height: 8),
                            BiliRecoveryButton(
                              error: BiliSiteVerificationRequired(
                                target: Uri.parse('https://www.bilinovel.net/'),
                                kind: BiliProbeKind.document,
                                revision: revision,
                                desktopSite: false,
                              ),
                              source: source,
                              onRecovered: () async {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('原站验证已完成，可返回发现或继续阅读。'),
                                  ),
                                );
                              },
                            ),
                          ],
                        )
                      else if (source == SourceId.huanmeng)
                        const Text(
                          '幻梦原站公开接口 · 无需登录\n支持搜索、分类、目录与正文；下架或受限书籍以原站返回为准。\n收藏与阅读记录保留在本机。',
                        )
                      else if (source == SourceId.esj)
                        const Text('此书源已从内置列表撤下，请切换其他书源。\n原有收藏与阅读记录保留在本机。')
                      else if (source == SourceId.lnovel || source.isRule)
                        Text('公开书源 · 无需登录\n收藏与阅读记录保存在本机')
                      else
                        BlocBuilder<AuthCubit, AuthState>(
                          builder:
                              (context, auth) => ValueListenableBuilder<bool>(
                                valueListenable: ShelfSession.instance.signedIn,
                                builder: (context, shelfSignedIn, _) {
                                  final signedIn =
                                      source == SourceId.wenku8
                                          ? auth.status ==
                                              AuthStatus.authenticated
                                          : shelfSignedIn;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        signedIn
                                            ? '${source.label} · 已保存登录'
                                            : '${source.label} · 未登录',
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 12,
                                        children: [
                                          AppButton.tonal(
                                            onPressed: () async {
                                              await Navigator.push(
                                                context,
                                                HorizontalCoverPageRoute(
                                                  builder:
                                                      (_) =>
                                                          source ==
                                                                  SourceId
                                                                      .wenku8
                                                              ? const LoginPage()
                                                              : const ShelfLoginPage(),
                                                ),
                                              );
                                              // Rebuild visible source pages even if the provider is unchanged.
                                              sourceRevision.value++;
                                            },
                                            child: Text(
                                              signedIn
                                                  ? '重新登录'
                                                  : '登录${source.label}',
                                            ),
                                          ),
                                          if (signedIn)
                                            AppButton.text(
                                              onPressed: () async {
                                                try {
                                                  if (source ==
                                                      SourceId.wenku8) {
                                                    await api.logout();
                                                    if (context.mounted) {
                                                      context
                                                          .read<AuthCubit>()
                                                          .logout();
                                                    }
                                                  } else {
                                                    await ShelfSession.instance
                                                        .logout();
                                                    api.clearShelfSessionCache();
                                                  }
                                                  sourceRevision.value++;
                                                } catch (_) {
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          '退出失败，请重试',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                }
                                              },
                                              child: const Text('退出当前书源'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  );
                                },
                              ),
                        ),
                    ],
                  ),
                ),
              ),
        ),
  );
}
