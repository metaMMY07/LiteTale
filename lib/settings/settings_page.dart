import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/font_settings_page.dart';
import 'package:wild/settings/reader_settings_page.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/settings/theme_paper_page.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/theme/material_you.dart';

/// The former settings entry now opens display preferences directly.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.appearanceOnly = false});

  final bool appearanceOnly;

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<SettingsPreferencesCubit>();
    final prefs = preferences.state;
    Future<void> chooseVariant() async {
      final v = await chooseSetting(
        context,
        '汉字变体',
        hanVariantNames,
        prefs.hanVariant,
      );
      if (v != null && context.mounted) {
        await settingsAction(
          context,
          () => preferences.update((s) => s.copyWith(hanVariant: v)),
        );
      }
    }

    if (appearanceOnly) {
      return Scaffold(
        appBar: settingsAppBar(context, '外观'),
        body: LeftAlignedScrollView(
          bottomInset: 28,
          child: IosSettingsSection(
            title: '显示',
            rows: [
              IosSettingsRow(
                icon: CupertinoIcons.paintbrush,
                title: '主题与纸张',
                description: '深浅色、配色、应用图标与阅读背景',
                onTap: () => openSettingsPage(context, const ThemePaperPage()),
              ),
              IosSettingsRow(
                icon: CupertinoIcons.textformat_size,
                title: '字体设置',
                description: '全局界面字体与小说阅读字体',
                onTap:
                    () => openSettingsPage(context, const FontSettingsPage()),
              ),
              IosSettingsRow(
                icon: CupertinoIcons.textformat,
                title: '汉字变体',
                description: hanVariantNames[prefs.hanVariant] ?? '选择地区字形',
                onTap: chooseVariant,
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('显示')),
      body: LeftAlignedScrollView(
        bottomInset: 28,
        child: AppleGlassCard.filled(
          key: const ValueKey('display-navigation-card'),
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          color:
              usesMaterialYou
                  ? Theme.of(context).scaffoldBackgroundColor
                  : null,
          child: SettingsTileGroup(
            children: [
              SettingsEntry(
                icon: Icons.format_paint_outlined,
                title: '主题与纸张',
                description: '深浅色、配色、应用图标与阅读背景',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => openSettingsPage(context, const ThemePaperPage()),
              ),
              SettingsEntry(
                icon: Icons.text_fields_rounded,
                title: '字体设置',
                description: '全局界面字体与小说阅读字体',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap:
                    () => openSettingsPage(context, const FontSettingsPage()),
              ),
              SettingsEntry(
                icon: Icons.chrome_reader_mode_outlined,
                title: '阅读显示',
                description: '字号、行距、页边距、翻页效果与音量键翻页',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap:
                    () => openSettingsPage(context, const ReaderSettingsPage()),
              ),
              SettingsEntry(
                icon: Icons.translate_rounded,
                title: '汉字变体',
                description: '选择字体支持的地区字形',
                option: hanVariantNames[prefs.hanVariant],
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: chooseVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const logLevelNames = {'off': '关闭', 'error': '错误', 'info': '信息', 'debug': '调试'};
