import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:wild/cubits/app_accent_cubit.dart';

void showAppColors(BuildContext context) {
  final cubit = context.read<AppAccentCubit>();
  FocusManager.instance.primaryFocus?.unfocus();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder:
        (_) => BlocProvider.value(
          value: cubit,
          child: const SafeArea(
            child: SingleChildScrollView(child: AppColorSettings()),
          ),
        ),
  );
}

class AppColorSettings extends StatelessWidget {
  const AppColorSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppAccentCubit, String>(
      builder: (context, selected) {
        Future<void> choose(String value) async {
          try {
            await context.read<AppAccentCubit>().select(value);
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('配色已切换，但未能保存，请重试')));
            }
          }
        }

        Future<void> chooseCustom() async {
          var picked =
              appAccentSeed(selected) ?? Theme.of(context).colorScheme.primary;
          final result = await showDialog<Color>(
            context: context,
            builder:
                (dialogContext) => AlertDialog(
                  title: const Text('自定义主题颜色'),
                  content: SingleChildScrollView(
                    child: ColorPicker(
                      pickerColor: picked,
                      enableAlpha: false,
                      labelTypes: const [],
                      onColorChanged: (color) => picked = color,
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, picked),
                      child: const Text('应用'),
                    ),
                  ],
                ),
          );
          if (result != null && context.mounted) {
            await choose(customAccentValue(result));
          }
        }

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('主题配色', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('选择喜欢的颜色，立即应用到整个界面。'),
              const SizedBox(height: 16),
              ChoiceChip(
                label: const Text('跟随系统壁纸'),
                avatar: const Icon(Icons.wallpaper_rounded, size: 18),
                selected: selected == 'system',
                onSelected: (_) => choose('system'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children:
                    appAccentColors.entries
                        .map(
                          (entry) => ChoiceChip(
                            label: Text(entry.value.$1),
                            avatar: CircleAvatar(
                              backgroundColor: entry.value.$2,
                              radius: 9,
                            ),
                            selected: selected == entry.key,
                            onSelected: (_) => choose(entry.key),
                          ),
                        )
                        .toList(),
              ),
              const SizedBox(height: 12),
              ActionChip(
                avatar: CircleAvatar(
                  backgroundColor:
                      selected.startsWith('custom:')
                          ? appAccentSeed(selected)
                          : Theme.of(context).colorScheme.primary,
                  radius: 9,
                ),
                label: Text(
                  selected.startsWith('custom:') ? '自定义颜色（已选择）' : '自定义颜色',
                ),
                onPressed: chooseCustom,
              ),
              const SizedBox(height: 12),
              Text(
                '壁纸取色需要 Android 12 或更新版本；不可用时使用鸢尾紫。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
