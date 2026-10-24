import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';

class ReaderCurlSetting extends StatelessWidget {
  const ReaderCurlSetting({super.key});

  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? const SizedBox.shrink()
          : BlocBuilder<ReaderCurlCubit, bool>(
            builder:
                (context, enabled) => AppSwitchListTile(
                  title: const Text('仿书翻页'),
                  subtitle: const Text('在线书源可跟随手指翻动书页；本地 EPUB 使用普通翻页'),
                  value: enabled,
                  onChanged: (value) async {
                    try {
                      await context.read<ReaderCurlCubit>().setEnabled(value);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('翻页设置已切换，但未能保存，请重试')),
                        );
                      }
                    }
                  },
                ),
          );
}
