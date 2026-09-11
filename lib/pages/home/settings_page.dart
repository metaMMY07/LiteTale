import 'dart:io';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/app_color_settings.dart';
import 'package:wild/widgets/source_settings.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/screen_up_on_reading_property.dart';
import 'package:wild/cubits/screen_up_on_scroll_property.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/cubits/volume_control_cubit.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: BlocBuilder<ThemeCubit, ReaderTheme>(
        builder: (context, theme) {
          return ListView(
            children: [
              const SizedBox(height: 8),
              const SourceSettings(),
              if (usesMaterialYou)
                const Card(
                  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: AppColorSettings(),
                ),
              // 阅读器设置
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '阅读器设置',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    BlocBuilder<ReaderTypeCubit, ReaderType>(
                      builder: (context, type) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('阅读器类型'),
                              const SizedBox(height: 8),
                              SegmentedButton<ReaderType>(
                                segments: const [
                                  ButtonSegment<ReaderType>(
                                    value: ReaderType.normal,
                                    label: Text('普通阅读器'),
                                    icon: Icon(Icons.book),
                                  ),
                                  ButtonSegment<ReaderType>(
                                    value: ReaderType.html,
                                    label: Text('HTML阅读器'),
                                    icon: Icon(Icons.html),
                                  ),
                                ],
                                selected: {type},
                                onSelectionChanged: (
                                  Set<ReaderType> types,
                                ) async {
                                  await context
                                      .read<ReaderTypeCubit>()
                                      .updateType(types.first);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      screenUpOnReadingSetting(),
                      screenUpOnScrollSetting(),
                      const SizedBox(height: 16),
                    ],
                    // 音量键控制设置（安卓 & iOS）
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      BlocBuilder<VolumeControlCubit, bool>(
                        builder: (context, isEnabled) {
                          return SwitchListTile(
                            title: const Text('音量键翻页'),
                            value: isEnabled,
                            onChanged: (value) {
                              context.read<VolumeControlCubit>().updateVolumeControl(value);
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
              // 主题设置
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '主题设置',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    RadioListTile<ReaderThemeMode>(
                      title: const Text('跟随系统'),
                      value: ReaderThemeMode.auto,
                      groupValue: theme.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          context.read<ThemeCubit>().setThemeMode(value);
                        }
                      },
                    ),
                    RadioListTile<ReaderThemeMode>(
                      title: const Text('浅色'),
                      value: ReaderThemeMode.light,
                      groupValue: theme.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          context.read<ThemeCubit>().setThemeMode(value);
                        }
                      },
                    ),
                    RadioListTile<ReaderThemeMode>(
                      title: const Text('深色'),
                      value: ReaderThemeMode.dark,
                      groupValue: theme.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          context.read<ThemeCubit>().setThemeMode(value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              // API Host 设置
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '文库8镜像地址',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    BlocBuilder<ApiHostCubit, String>(
                      builder: (context, apiHost) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('仅影响文库8；书源切换请使用上方设置'),
                              const SizedBox(height: 8),
                              TextField(
                                controller: TextEditingController(text: apiHost),
                                decoration: const InputDecoration(
                                  hintText: '留空使用默认地址',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.link),
                                ),
                                onSubmitted: (value) async {
                                  try {
                                    await context.read<ApiHostCubit>().updateApiHost(value);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('API Host 已更新'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('更新失败: $e'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  }
                                },
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        try {
                                          await context.read<ApiHostCubit>().resetToDefault();
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('已重置为默认地址'),
                                                duration: Duration(seconds: 2),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('重置失败: $e'),
                                                duration: const Duration(seconds: 2),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('重置为默认'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              // 缓存设置
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '缓存设置',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined),
                      title: const Text('清除接口缓存'),
                      subtitle: const Text('清除所有网络请求的缓存数据'),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder:
                              (context) => AlertDialog(
                                title: const Text('清除缓存'),
                                content: const Text('确定要清除所有接口缓存吗？'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      Navigator.pop(context);
                                      try {
                                        await cleanAllWebCache();
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('缓存已清除'),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text('清除缓存失败: $e'),
                                              duration: const Duration(
                                                seconds: 2,
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    child: const Text('确定'),
                                  ),
                                ],
                              ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
