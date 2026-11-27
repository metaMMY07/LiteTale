import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/widgets/apple_glass_chrome.dart' show usesAppleGlass;
import 'package:wild/widgets/platform_controls.dart';

class ReaderCurlSetting extends StatelessWidget {
  const ReaderCurlSetting({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReaderCurlCubit>();
    final selected = settings.state.forPlatform(isIos: usesAppleGlass);
    final choices = ReaderPageEffect.available(isIos: usesAppleGlass);
    return AppButton.text(
      onPressed:
          enabled
              ? () async {
                final effect = await chooseSetting(context, '翻页效果', {
                  for (final effect in choices) effect: effect.label,
                }, selected);
                if (effect != null && context.mounted) {
                  await settingsAction(
                    context,
                    () => settings.setEffect(effect),
                  );
                }
              }
              : null,
      child: Text(selected.label),
    );
  }
}
