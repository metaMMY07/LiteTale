import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/pages/home/font_settings_page.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/widgets/app_color_settings.dart';
import 'package:wild/widgets/launcher_icon_settings.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/settings/settings_platform.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class ThemePaperPage extends StatefulWidget {
  const ThemePaperPage({super.key});
  @override
  State<ThemePaperPage> createState() => _ThemePaperPageState();
}

class _ThemePaperPageState extends State<ThemePaperPage> {
  bool darkPaper = false;
  int sdk = 0;
  @override
  void initState() {
    super.initState();
    settingsAndroidSdk()
        .then((v) {
          if (mounted) setState(() => sdk = v);
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeCubit>().state;
    final accent = context.watch<AppAccentCubit>().state;
    final preferences = context.watch<SettingsPreferencesCubit>().state;
    final background = context.watch<ReaderBackgroundCubit>();
    final fonts = context.watch<FontSettingsCubit>().state;
    final colors = Theme.of(context).colorScheme;
    final paperColor =
        darkPaper ? theme.darkBackgroundColor : theme.lightBackgroundColor;
    final inkColor = darkPaper ? theme.darkTextColor : theme.lightTextColor;
    final paperPath =
        darkPaper
            ? background.getDarkBackgroundPath()
            : background.getLightBackgroundPath();
    return Scaffold(
      appBar: AppBar(title: const Text('主题与纸张')),
      body: LeftAlignedScrollView(
        bottomInset: 28,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionLabel('应用'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (mode, label) in const [
                    (ReaderThemeMode.light, '保持浅色'),
                    (ReaderThemeMode.dark, '保持深色'),
                    (ReaderThemeMode.auto, '跟随系统'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _ThemeModeTile(
                          mode: mode,
                          label: label,
                          selected: theme.themeMode == mode,
                          seed: appAccentSeed(accent) ?? colors.primary,
                          onTap:
                              () => settingsAction(
                                context,
                                () => context.read<ThemeCubit>().setThemeMode(
                                  mode,
                                ),
                              ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SettingsSwitch(
              icon: Icons.format_color_fill_outlined,
              title: '系统动态配色',
              description: '从系统主题提取应用颜色（Android 12+）',
              value: accent == 'system',
              onChanged:
                  Platform.isAndroid && sdk < 31
                      ? null
                      : (v) => settingsAction(
                        context,
                        () => context.read<AppAccentCubit>().select(
                          v ? 'system' : 'iris',
                        ),
                      ),
            ),
            SettingsEntry(
              icon: Icons.palette_outlined,
              title: '应用配色',
              description: '预设颜色或自定义颜色',
              option:
                  accent == 'system'
                      ? '跟随系统'
                      : appAccentColors[accent]?.$1 ?? '自定义颜色',
              filled: false,
              onTap: () => showAppColors(context),
              trailing: _ColorDot(colors.primary),
            ),
            SettingsSwitch(
              icon: Icons.nightlight_round,
              title: '纯黑深色主题',
              description: '深色模式使用更深的应用背景',
              value: preferences.blackTheme,
              onChanged:
                  (v) => settingsAction(
                    context,
                    () => context.read<SettingsPreferencesCubit>().update(
                      (s) => s.copyWith(blackTheme: v),
                    ),
                  ),
            ),
            if (Platform.isAndroid)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: LauncherIconSettings(),
              ),
            const SettingsSectionLabel('纸张'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('浅色纸张'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('深色纸张'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {darkPaper},
                onSelectionChanged: (v) => setState(() => darkPaper = v.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: paperColor,
                  image:
                      paperPath == null
                          ? null
                          : DecorationImage(
                            image: FileImage(File(paperPath)),
                            fit: BoxFit.cover,
                            opacity: background.state.opacity,
                          ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Text(
                  '在故事里，找到属于自己的片刻。\nEvery story begins with a page.',
                  style: TextStyle(
                    fontFamily: fonts.readerFamily,
                    fontFamilyFallback: const ['LXGWNeoZhiSongPlus'],
                    fontSize: 18,
                    height: 1.6,
                    color: inkColor,
                    locale: hanLocale(preferences.hanVariant),
                  ),
                ),
              ),
            ),
            SettingsSwitch(
              icon: Icons.wallpaper_outlined,
              title: '背景图片',
              description: '使用内置纸张或自行导入图片',
              value: background.state.enabled,
              onChanged:
                  (v) =>
                      settingsAction(context, () => background.setEnabled(v)),
            ),
            if (background.state.enabled) ...[
              SettingsEntry(
                icon: Icons.texture_outlined,
                title: '图片来源',
                filled: false,
                option: background.state.builtin ? '内置纸张' : '自定义图片',
                onTap: () async {
                  final v = await chooseSetting(context, '图片来源', {
                    true: '内置纸张',
                    false: '自定义图片',
                  }, background.state.builtin);
                  if (v != null && context.mounted) {
                    await settingsAction(
                      context,
                      () => background.setBuiltin(v),
                    );
                  }
                },
              ),
              if (!background.state.builtin)
                SettingsEntry(
                  icon: Icons.add_photo_alternate_outlined,
                  title: '选择${darkPaper ? '深色' : '浅色'}背景',
                  filled: false,
                  option: paperPath == null ? '尚未选择' : '已保存在应用中',
                  onTap:
                      () => settingsAction(
                        context,
                        darkPaper
                            ? background.updateDarkBackground
                            : background.updateLightBackground,
                      ),
                  trailing:
                      paperPath == null
                          ? const Icon(Icons.add)
                          : IconButton(
                            tooltip: '恢复纯色纸张',
                            icon: const Icon(Icons.close),
                            onPressed:
                                () => settingsAction(
                                  context,
                                  darkPaper
                                      ? background.deleteDarkBackground
                                      : background.deleteLightBackground,
                                ),
                          ),
                ),
              SettingsValueSlider(
                title: '图片强度',
                value: background.state.opacity * 100,
                min: 0,
                max: 100,
                suffix: '%',
                onSaved: (v) => background.updateOpacity(v / 100),
              ),
            ],
            SettingsEntry(
              icon: Icons.format_color_fill_outlined,
              title: '背景颜色',
              filled: false,
              description: '自定义阅读纸张颜色',
              trailing: _ColorDot(paperColor),
              onTap: () async {
                final value = await pickSettingsColor(
                  context,
                  '背景颜色',
                  paperColor,
                );
                if (value == null || !context.mounted) return;
                await settingsAction(
                  context,
                  () =>
                      darkPaper
                          ? context
                              .read<ThemeCubit>()
                              .updateDarkBackgroundColor(value)
                          : context
                              .read<ThemeCubit>()
                              .updateLightBackgroundColor(value),
                );
              },
            ),
            const SettingsSectionLabel('文本'),
            SettingsEntry(
              icon: Icons.format_color_text_outlined,
              title: '文本颜色',
              filled: false,
              description: '自定义阅读文字颜色',
              trailing: _ColorDot(inkColor),
              onTap: () async {
                final value = await pickSettingsColor(
                  context,
                  '文本颜色',
                  inkColor,
                );
                if (value == null || !context.mounted) return;
                await settingsAction(
                  context,
                  () =>
                      darkPaper
                          ? context.read<ThemeCubit>().updateDarkTextColor(
                            value,
                          )
                          : context.read<ThemeCubit>().updateLightTextColor(
                            value,
                          ),
                );
              },
            ),
            SettingsEntry(
              icon: Icons.font_download_outlined,
              title: '文本字体',
              filled: false,
              description: '分别选择全局界面与阅读字体',
              option: fonts.reader?.name ?? '默认阅读字体',
              onTap: () => openSettingsPage(context, const FontSettingsPage()),
            ),
          ],
        ),
      ),
    );
  }
}

Future<Color?> pickSettingsColor(
  BuildContext context,
  String title,
  Color initial,
) {
  var value = initial;
  return showDialog<Color>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: initial,
              onColorChanged: (v) => value = v.withValues(alpha: 1),
              enableAlpha: false,
              hexInputBar: true,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('保存'),
            ),
          ],
        ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot(this.color);
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 26,
    height: 26,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(
        color: Theme.of(context).colorScheme.outline,
        width: 1.5,
      ),
    ),
  );
}

class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.seed,
    required this.onTap,
  });
  final ReaderThemeMode mode;
  final String label;
  final bool selected;
  final Color seed;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: label,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 116),
            child: AspectRatio(
              aspectRatio: 0.66,
              child: CustomPaint(
                painter: _ThemePreviewPainter(mode, seed, selected),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: selected ? Theme.of(context).colorScheme.primary : null,
              ),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
}

class _ThemePreviewPainter extends CustomPainter {
  const _ThemePreviewPainter(this.mode, this.seed, this.selected);
  final ReaderThemeMode mode;
  final Color seed;
  final bool selected;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 100;
    canvas.scale(scale);
    final height = size.height / scale;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, 98, height - 2),
      const Radius.circular(9),
    );
    canvas.save();
    canvas.clipRRect(rect);
    void preview(bool dark) {
      final scheme = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: dark ? Brightness.dark : Brightness.light,
      );
      final paint = Paint()..color = scheme.surface;
      canvas.drawRect(Rect.fromLTWH(0, 0, 100, height), paint);
      paint.color = scheme.secondaryContainer;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(10, 12, 29, 42),
          const Radius.circular(3),
        ),
        paint,
      );
      paint.color = scheme.onSurfaceVariant.withValues(alpha: 0.32);
      for (var i = 0; i < 4; i++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(47, 15 + i * 10, i == 3 ? 29 : 42, 5),
            const Radius.circular(3),
          ),
          paint,
        );
      }
      for (var i = 0; i < 5; i++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(10, 66 + i * 10, i.isEven ? 73 : 60, 4),
            const Radius.circular(3),
          ),
          paint,
        );
      }
      paint.color = scheme.primaryContainer;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(55, height - 28, 33, 14),
          const Radius.circular(7),
        ),
        paint,
      );
    }

    preview(mode == ReaderThemeMode.dark);
    if (mode == ReaderThemeMode.auto) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, height / 2, 100, height / 2));
      preview(true);
      canvas.restore();
    }
    canvas.restore();
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : 1
        ..color = selected ? seed : const Color(0xFF858080),
    );
  }

  @override
  bool shouldRepaint(_ThemePreviewPainter old) =>
      mode != old.mode || seed != old.seed || selected != old.selected;
}

class SettingsValueSlider extends StatefulWidget {
  const SettingsValueSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.suffix = '',
    this.decimals = 0,
    required this.onSaved,
  });
  final String title;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final int decimals;
  final Future<void> Function(double) onSaved;
  @override
  State<SettingsValueSlider> createState() => _SettingsValueSliderState();
}

class _SettingsValueSliderState extends State<SettingsValueSlider> {
  double? draft;
  @override
  void didUpdateWidget(SettingsValueSlider old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) draft = null;
  }

  @override
  Widget build(BuildContext context) {
    final value = (draft ?? widget.value).clamp(widget.min, widget.max);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.title)),
              Text('${value.toStringAsFixed(widget.decimals)}${widget.suffix}'),
            ],
          ),
          Slider(
            value: value,
            min: widget.min,
            max: widget.max,
            divisions:
                ((widget.max - widget.min) * (widget.decimals == 0 ? 1 : 10))
                    .round(),
            label: '${value.toStringAsFixed(widget.decimals)}${widget.suffix}',
            onChanged: (v) => setState(() => draft = v),
            onChangeEnd: (v) async {
              await settingsAction(context, () => widget.onSaved(v));
              if (mounted) setState(() => draft = null);
            },
          ),
        ],
      ),
    );
  }
}
