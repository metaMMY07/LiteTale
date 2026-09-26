import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';

class ReaderCurlSetting extends StatelessWidget {
  const ReaderCurlSetting({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<ReaderCurlCubit, bool>(
    builder: (context, enabled) => SwitchListTile(
      title: const Text('仿书翻页'),
      subtitle: const Text('普通阅读器中跟随手指翻动书页；关闭后恢复原来的翻页方式'),
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
