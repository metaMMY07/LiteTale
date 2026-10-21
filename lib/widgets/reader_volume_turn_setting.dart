import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/settings/settings_widgets.dart';

/// The same preference is available before entering a book and in its menu.
class ReaderVolumeTurnSetting extends StatelessWidget {
  const ReaderVolumeTurnSetting({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<VolumeControlCubit, bool>(
    builder: (context, enabled) {
      final volume = context.read<VolumeControlCubit>();
      return SettingsSwitch(
        key: const ValueKey('reader-volume-turn-setting'),
        icon: Icons.volume_up_outlined,
        title: '音量键翻页',
        description:
            volume.isSupported
                ? '上键上一页，下键下一页；离开阅读器后恢复系统音量'
                : '仅支持 Android 和 iOS',
        value: enabled,
        onChanged:
            volume.isSupported
                ? (value) => settingsAction(
                  context,
                  () => volume.updateVolumeControl(value),
                )
                : null,
      );
    },
  );
}
