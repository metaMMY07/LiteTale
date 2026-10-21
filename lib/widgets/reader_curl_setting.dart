import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';

class ReaderCurlSetting extends StatelessWidget {
  const ReaderCurlSetting({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<ReaderCurlCubit, bool>(
    builder:
        (context, enabled) => SwitchListTile(
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
