import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/login_page.dart';
import 'package:wild/pages/shelf_login_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/shelf_session.dart';
import 'package:wild/sources/source_api.dart' as api;

/// Kept within settings; the rest of the app shows exactly one provider.
class SourceSettings extends StatelessWidget {
  const SourceSettings({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SourceId>(
    valueListenable: activeSource,
    builder:
        (context, source, _) => Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('书源与账号', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('一次使用一个书源。切换后保留各自的登录状态。'),
                const SizedBox(height: 12),
                DropdownButtonFormField<SourceId>(
                  value: source,
                  decoration: const InputDecoration(labelText: '当前书源'),
                  items:
                      SourceId.values
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(s.label),
                            ),
                          )
                          .toList(),
                  onChanged: (value) async {
                    if (value == null || value == activeSource.value) return;
                    try {
                      await api.selectSource(value);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('书源选择未能保存，请重试')),
                        );
                      }
                    }
                  },
                ),
                const SizedBox(height: 12),
                BlocBuilder<AuthCubit, AuthState>(
                  builder:
                      (context, auth) => ValueListenableBuilder<bool>(
                        valueListenable: ShelfSession.instance.signedIn,
                        builder: (context, shelfSignedIn, _) {
                          final signedIn =
                              source == SourceId.wenku8
                                  ? auth.status == AuthStatus.authenticated
                                  : shelfSignedIn;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                  FilledButton.tonal(
                                    onPressed: () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder:
                                              (_) =>
                                                  source == SourceId.wenku8
                                                      ? const LoginPage()
                                                      : const ShelfLoginPage(),
                                        ),
                                      );
                                      // Rebuild visible source pages even if the provider is unchanged.
                                      sourceRevision.value++;
                                    },
                                    child: Text(
                                      signedIn ? '重新登录' : '登录${source.label}',
                                    ),
                                  ),
                                  if (signedIn)
                                    TextButton(
                                      onPressed: () async {
                                        try {
                                          if (source == SourceId.wenku8) {
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
                                                content: Text('退出失败，请重试'),
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
  );
}
