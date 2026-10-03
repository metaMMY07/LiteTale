import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/settings/theme_paper_page.dart' show SettingsValueSlider;
import 'package:wild/widgets/left_aligned_scrollable.dart';

class ReaderSettingsPage extends StatelessWidget {
  const ReaderSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final type = context.watch<ReaderTypeCubit>();
    final curl = context.watch<ReaderCurlCubit>();
    final size = context.watch<FontSizeCubit>();
    final line = context.watch<LineHeightCubit>();
    final spacing = context.watch<ParagraphSpacingCubit>();
    final top = context.watch<TopBarHeightCubit>();
    final bottom = context.watch<BottomBarHeightCubit>();
    final left = context.watch<LeftPaddingCubit>();
    final right = context.watch<RightPaddingCubit>();
    return Scaffold(
      appBar: AppBar(title: const Text('阅读显示')),
      body: LeftAlignedScrollView(
        bottomInset: 28,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionLabel('文本'),
            SettingsValueSlider(
              title: '字号',
              value: size.state,
              min: 10,
              max: 40,
              onSaved: size.updateFontSize,
            ),
            SettingsValueSlider(
              title: '行距',
              value: line.state,
              min: 1,
              max: 2.5,
              decimals: 1,
              onSaved: line.updateLineHeight,
            ),
            SettingsValueSlider(
              title: '段间距',
              value: spacing.state,
              min: 0,
              max: 60,
              onSaved: spacing.updateSpacing,
            ),
            const SettingsSectionLabel('翻页效果'),
            SettingsEntry(
              icon: Icons.chrome_reader_mode_outlined,
              title: '阅读模式',
              filled: false,
              description: '重新打开阅读器后生效',
              option: type.state == ReaderType.normal ? '分页阅读' : '连续滚动',
              onTap: () async {
                final v = await chooseSetting(context, '阅读模式', const {
                  ReaderType.normal: '分页阅读',
                  ReaderType.html: '连续滚动',
                }, type.state);
                if (v != null && context.mounted) {
                  await settingsAction(context, () => type.updateType(v));
                }
              },
            ),
            SettingsSwitch(
              icon: Icons.auto_stories_outlined,
              title: '仿真翻页',
              description: '保留纸张曲面与手势跟随；关闭时直接翻页',
              value: curl.state,
              onChanged:
                  type.state == ReaderType.html
                      ? null
                      : (v) =>
                          settingsAction(context, () => curl.setEnabled(v)),
            ),
            const SettingsSectionLabel('页边距'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('横屏双页沿用同一组页边距。阅读界面保持不显示页码、时间与电量。'),
            ),
            SettingsValueSlider(
              title: '上边距',
              value: top.state,
              min: 0,
              max: 80,
              onSaved: top.updateHeight,
            ),
            SettingsValueSlider(
              title: '下边距',
              value: bottom.state,
              min: 0,
              max: 80,
              onSaved: bottom.updateHeight,
            ),
            SettingsValueSlider(
              title: '左边距',
              value: left.state,
              min: 0,
              max: 80,
              onSaved: left.updatePadding,
            ),
            SettingsValueSlider(
              title: '右边距',
              value: right.state,
              min: 0,
              max: 80,
              onSaved: right.updatePadding,
            ),
          ],
        ),
      ),
    );
  }
}
