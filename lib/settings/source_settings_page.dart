import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/widgets/source_settings.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class SourceSettingsPage extends StatefulWidget {
  const SourceSettingsPage({super.key});
  @override
  State<SourceSettingsPage> createState() => _SourceSettingsPageState();
}

class _SourceSettingsPageState extends State<SourceSettingsPage> {
  late final host = TextEditingController(
    text: context.read<ApiHostCubit>().state,
  );
  String? hostError;
  @override
  void dispose() {
    host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('书源与账号')),
    body: LeftAlignedScrollView(
      bottomInset: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SourceSettings(),
          SettingsGroup(
            title: '文库8镜像',
            icon: Icons.link_rounded,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('仅影响文库8；留空使用默认地址。\n$wenku8HostHint'),
              ),
              TextField(
                controller: host,
                decoration: InputDecoration(
                  labelText: '镜像地址',
                  prefixIcon: const Icon(Icons.link),
                  errorText: hostError,
                  errorMaxLines: 3,
                ),
                onSubmitted: (_) => _saveHost(),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(onPressed: _saveHost, child: const Text('保存')),
                    OutlinedButton(
                      onPressed:
                          () => settingsAction(context, () async {
                            await context.read<ApiHostCubit>().resetToDefault();
                            if (context.mounted) {
                              setState(() {
                                host.text = context.read<ApiHostCubit>().state;
                                hostError = null;
                              });
                            }
                          }, success: '已恢复默认地址'),
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: '缓存',
            icon: Icons.storage_outlined,
            children: [
              SettingsEntry(
                icon: Icons.cleaning_services_outlined,
                title: '清除接口缓存',
                description: '保留账号、书架和阅读记录',
                onTap: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder:
                        (ctx) => AlertDialog(
                          title: const Text('清除接口缓存'),
                          content: const Text('下次打开页面时会重新获取数据。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('清除'),
                            ),
                          ],
                        ),
                  );
                  if (yes == true && context.mounted) {
                    await settingsAction(
                      context,
                      cleanAllWebCache,
                      success: '接口缓存已清除',
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Future<void> _saveHost() async {
    String normalized;
    try {
      normalized = normalizeWenku8Host(host.text);
    } on FormatException catch (error) {
      setState(() => hostError = error.message);
      return;
    }
    setState(() => hostError = null);
    await settingsAction(context, () async {
      await context.read<ApiHostCubit>().updateApiHost(normalized);
      if (mounted) host.text = context.read<ApiHostCubit>().state;
    }, success: '镜像地址已保存');
  }
}
