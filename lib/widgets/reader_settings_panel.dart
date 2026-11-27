import 'package:wild/theme/ios_system_colors.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/pages/novel/auto_scroll_config_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/settings_widgets.dart'
    show IosSettingsRow, IosSettingsSection, settingsAction, chooseSetting;
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_solid_surface.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_reader_panel.dart';
import 'package:wild/widgets/reader_curl_setting.dart';
import 'package:wild/widgets/reader_settings_binding.dart';
import 'package:wild/widgets/reader_draggable_sheet.dart';

enum _ReaderSheetSelection { marks, reloadChapter }

Future<bool> showReaderSettingsPanel(
  BuildContext context, {
  Future<void> Function()? onLayoutChanged,
  Future<void> Function()? onReloadChapter,
  bool localEpub = false,
  AutoScrollConfigCubit? autoScroll,
  bool includeMarks = false,
  SettingsPreferencesCubit? footerPreferences,
}) async {
  final canReloadChapter = onReloadChapter != null && !localEpub;
  if (usesAppleGlass && await AppleReaderPanel.available) {
    if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    final binding = ReaderSettingsBinding(
      context,
      onLayoutChanged: onLayoutChanged,
      autoScroll: autoScroll,
      includeMarks: includeMarks,
      includeReloadChapter: canReloadChapter,
      localEpub: localEpub,
      footerPreferences: footerPreferences,
    );
    final selection = await AppleReaderPanel.show(
      context,
      configuration: binding.snapshot,
      onChange: binding.change,
    );
    if (canReloadChapter && selection?['id'] == 'reloadChapter') {
      if (context.mounted && ModalRoute.of(context)?.isCurrent != false) {
        await onReloadChapter();
      }
      return false;
    }
    return includeMarks && selection?['id'] == 'marks';
  }
  if (!context.mounted) return false;
  final panel = MultiBlocProvider(
    providers: [
      BlocProvider.value(value: context.read<FontSizeCubit>()),
      BlocProvider.value(value: context.read<LineHeightCubit>()),
      BlocProvider.value(value: context.read<ParagraphSpacingCubit>()),
      BlocProvider.value(value: context.read<TopBarHeightCubit>()),
      BlocProvider.value(value: context.read<BottomBarHeightCubit>()),
      BlocProvider.value(value: context.read<LeftPaddingCubit>()),
      BlocProvider.value(value: context.read<RightPaddingCubit>()),
      BlocProvider.value(value: context.read<ReaderTypeCubit>()),
      BlocProvider.value(value: context.read<ThemeCubit>()),
      BlocProvider.value(value: context.read<ReaderBackgroundCubit>()),
      BlocProvider.value(value: context.read<ReaderCurlCubit>()),
      BlocProvider.value(value: context.read<VolumeControlCubit>()),
    ],
    child: ReaderDraggableSheet(
      handleKey: const ValueKey('reader-settings-drag-handle'),
      snapToPages: Theme.of(context).platform == TargetPlatform.android,
      initialChildSize: MediaQuery.sizeOf(context).height < 500 ? .9 : .55,
      builder:
          (context, controller, handle) => ReaderSettingsPanel(
            scrollController: controller,
            dragHandle: handle,
            onLayoutChanged: onLayoutChanged,
            localEpub: localEpub,
            autoScroll: autoScroll,
            includeMarks: includeMarks,
            includeReloadChapter: canReloadChapter,
            footerPreferences: footerPreferences,
          ),
    ),
  );
  final _ReaderSheetSelection? selection;
  if (usesAppleGlass) {
    selection = await showCupertinoModalPopup<_ReaderSheetSelection>(
      context: context,
      useRootNavigator: false,
      builder: (_) => Material(type: MaterialType.transparency, child: panel),
    );
  } else {
    selection = await showModalBottomSheet<_ReaderSheetSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      enableDrag: Theme.of(context).platform != TargetPlatform.android,
      elevation: 0,
      useSafeArea: true,
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
      builder: (_) => panel,
    );
  }
  if (canReloadChapter && selection == _ReaderSheetSelection.reloadChapter) {
    if (context.mounted && ModalRoute.of(context)?.isCurrent != false) {
      await onReloadChapter();
    }
    return false;
  }
  return includeMarks && selection == _ReaderSheetSelection.marks;
}

/// Shared preferences and ranges, with platform-specific surfaces and controls.
class ReaderSettingsPanel extends StatelessWidget {
  const ReaderSettingsPanel({
    super.key,
    this.scrollController,
    this.onLayoutChanged,
    this.localEpub = false,
    this.autoScroll,
    this.dragHandle,
    this.includeMarks = false,
    this.includeReloadChapter = false,
    this.footerPreferences,
    this.section,
  });
  final ScrollController? scrollController;
  final Future<void> Function()? onLayoutChanged;
  final bool localEpub;
  final AutoScrollConfigCubit? autoScroll;
  final Widget? dragHandle;
  final bool includeMarks;
  final bool includeReloadChapter;
  final SettingsPreferencesCubit? footerPreferences;
  final ReaderSettingsSection? section;

  Future<void> _save(BuildContext context, Future<void> Function() action) =>
      settingsAction(context, () async {
        await action();
        await onLayoutChanged?.call();
      });

  Future<void> _color(
    BuildContext context,
    Color initial,
    Future<void> Function(Color) save,
  ) async {
    var chosen = initial;
    final result = await showAdaptiveDialog<Color>(
      context: context,
      builder:
          (dialog) => AlertDialog.adaptive(
            title: const Text('选择颜色'),
            content: SingleChildScrollView(
              child: ColorPicker(
                pickerColor: initial,
                onColorChanged: (v) => chosen = v,
                enableAlpha: false,
                labelTypes: const [],
                pickerAreaHeightPercent: .7,
              ),
            ),
            actions: [
              AppButton.text(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              AppButton.text(
                onPressed: () => Navigator.pop(dialog, chosen),
                child: const Text('确定'),
              ),
            ],
          ),
    );
    if (result != null && context.mounted) {
      await _save(context, () => save(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (usesAppleGlass && !includeMarks && !includeReloadChapter) {
      final supported = AppleReaderPanel.knownSupport;
      if (supported == true) return _nativeForm(context);
      if (supported == null) {
        return FutureBuilder<bool>(
          future: AppleReaderPanel.available,
          builder:
              (context, available) =>
                  available.data == true
                      ? _nativeForm(context)
                      : _buildFlutter(context),
        );
      }
    }
    return _buildFlutter(context);
  }

  Widget _nativeForm(BuildContext context) {
    final binding = ReaderSettingsBinding(
      context,
      onLayoutChanged: onLayoutChanged,
      autoScroll: autoScroll,
      localEpub: localEpub,
      footerPreferences: footerPreferences,
      section: section,
    );
    return AppleReaderSettingsView(
      configuration: binding.snapshot,
      onChange: binding.change,
    );
  }

  Widget _buildFlutter(BuildContext context) {
    final includeAll = section == null;
    final colors = Theme.of(context).colorScheme;
    final background =
        usesAppleGlass
            ? IosSystemColors.color('background', Theme.of(context).brightness)
            : colors.surfaceContainerLow;
    Widget slider(
      String id,
      IconData icon,
      String title,
      String description,
      double value,
      double min,
      double max,
      Future<void> Function(double) save, {
      int decimals = 0,
      String unit = '点',
    }) {
      final formatted = value.toStringAsFixed(decimals);
      final compactValue = unit.isEmpty ? formatted : '$formatted $unit';
      return ReaderSettingSlider(
        key: ValueKey(id),
        icon: icon,
        title: title,
        description: '$description · $compactValue',
        unit: unit,
        value: value,
        min: min,
        max: max,
        decimals: decimals,
        onSaved: (v) => _save(context, () => save(v)),
      );
    }

    List<Widget> buildTypographySection() {
      final size = context.watch<FontSizeCubit>();
      final line = context.watch<LineHeightCubit>();
      final spacing = context.watch<ParagraphSpacingCubit>();
      final left = context.watch<LeftPaddingCubit>();
      final right = context.watch<RightPaddingCubit>();
      final top = context.watch<TopBarHeightCubit>();
      final bottom = context.watch<BottomBarHeightCubit>();
      return [
        if (includeAll) const ReaderSettingLabel('排版'),
        ReaderSettingGroup(
          children: [
            slider(
              'reader-font-size',
              Icons.text_fields,
              '字号',
              '小说正文的文字大小',
              size.state,
              10,
              40,
              size.updateFontSize,
            ),
            slider(
              'reader-line-height',
              Icons.format_line_spacing,
              '行高',
              '段落中的行间距',
              line.state,
              1,
              2.5,
              line.updateLineHeight,
              decimals: 1,
              unit: '倍',
            ),
            slider(
              'reader-paragraph-spacing',
              Icons.space_bar,
              '段间距',
              '相邻段落之间的额外留白',
              spacing.state,
              0,
              60,
              spacing.updateSpacing,
            ),
            slider(
              'reader-left-padding',
              Icons.format_indent_increase,
              '左侧留白',
              '阅读内容左侧的页边距',
              left.state,
              0,
              80,
              left.updatePadding,
            ),
            slider(
              'reader-right-padding',
              Icons.format_indent_decrease,
              '右侧留白',
              '阅读内容右侧的页边距',
              right.state,
              0,
              80,
              right.updatePadding,
            ),
            slider(
              'reader-top-padding',
              Icons.vertical_align_top,
              '上边距',
              '正文上方的留白',
              top.state,
              0,
              80,
              top.updateHeight,
            ),
            slider(
              'reader-bottom-padding',
              Icons.vertical_align_bottom,
              '下边距',
              '正文下方的留白',
              bottom.state,
              0,
              80,
              bottom.updateHeight,
            ),
          ],
        ),
      ];
    }

    List<Widget> buildReadingModeSection() {
      final type = context.watch<ReaderTypeCubit>();
      final volume = context.watch<VolumeControlCubit>();
      return [
        if (includeAll) const ReaderSettingLabel('阅读方式'),
        ReaderSettingGroup(
          children: [
            ReaderSettingRow(
              icon: Icons.chrome_reader_mode_outlined,
              title: '阅读模式',
              description: '重新打开阅读器后生效',
              trailing: AppButton.text(
                child: Text(
                  type.state == ReaderType.normal ? '分页' : '滚动',
                ),
                onPressed: () async {
                  final v = await chooseSetting(context, '阅读模式', const {
                    ReaderType.normal: '分页阅读',
                    ReaderType.html: '连续滚动',
                  }, type.state);
                  if (v != null && context.mounted) {
                    await settingsAction(
                      context,
                      () => type.updateType(v),
                    );
                  }
                },
              ),
            ),
            if (!localEpub ||
                defaultTargetPlatform == TargetPlatform.android)
              ReaderSettingRow(
                icon: Icons.auto_stories_outlined,
                title: '翻页效果',
                description:
                    defaultTargetPlatform == TargetPlatform.android
                        ? '用于分页阅读'
                        : '用于在线书源的分页阅读',
                trailing: ReaderCurlSetting(
                  enabled: type.state == ReaderType.normal,
                ),
              ),
            if (!usesAppleGlass)
              ReaderSettingRow(
                icon: Icons.volume_up_outlined,
                title: '音量键翻页',
                description:
                    volume.isSupported ? '上键上一页，下键下一页' : '仅支持 Android',
                trailing: AppSwitch(
                  key: const ValueKey('reader-volume-turn-setting'),
                  value: volume.state,
                  onChanged:
                      volume.isSupported
                          ? (v) => settingsAction(
                            context,
                            () => volume.updateVolumeControl(v),
                          )
                          : null,
                ),
              ),
          ],
        ),
      ];
    }

    List<Widget> buildAppearanceSection() {
      final theme = context.watch<ThemeCubit>();
      final paper = context.watch<ReaderBackgroundCubit>();
      return [
        if (includeAll) const ReaderSettingLabel('阅读器外观'),
        ReaderSettingGroup(
          children: [
            if (footerPreferences case final preferences?)
              BlocSelector<
                SettingsPreferencesCubit,
                SettingsPreferences,
                bool
              >(
                bloc: preferences,
                selector: (state) => state.showReaderFooter,
                builder:
                    (context, visible) => ReaderSettingRow(
                      icon: Icons.schedule_outlined,
                      title: '显示时间和进度',
                      description: '在阅读页底部显示时间和本章页码',
                      trailing: AppSwitch(
                        key: const ValueKey('reader-footer-setting'),
                        value: visible,
                        onChanged:
                            (value) => settingsAction(
                              context,
                              () => preferences.update(
                                (state) => state.copyWith(
                                  showReaderFooter: value,
                                ),
                              ),
                            ),
                      ),
                    ),
              ),
            ReaderSettingRow(
              icon: Icons.brightness_auto_outlined,
              title: '深浅色',
              description: '独立保存浅色和深色纸张',
              trailing: AppButton.text(
                child: Text(switch (theme.state.themeMode) {
                  ReaderThemeMode.auto => '自动',
                  ReaderThemeMode.light => '浅色',
                  ReaderThemeMode.dark => '深色',
                }),
                onPressed: () async {
                  final v = await chooseSetting(context, '深浅色', const {
                    ReaderThemeMode.auto: '跟随系统',
                    ReaderThemeMode.light: '浅色',
                    ReaderThemeMode.dark: '深色',
                  }, theme.state.themeMode);
                  if (v != null && context.mounted) {
                    await _save(context, () => theme.setThemeMode(v));
                  }
                },
              ),
            ),
            for (final dark in [false, true]) ...[
              ReaderSettingRow(
                icon: Icons.format_paint_outlined,
                title: dark ? '深色背景' : '浅色背景',
                description: '选择正文页面的背景色',
                trailing: _ColorButton(
                  color:
                      dark
                          ? theme.state.darkBackgroundColor
                          : theme.state.lightBackgroundColor,
                  onPressed:
                      () => _color(
                        context,
                        dark
                            ? theme.state.darkBackgroundColor
                            : theme.state.lightBackgroundColor,
                        dark
                            ? theme.updateDarkBackgroundColor
                            : theme.updateLightBackgroundColor,
                      ),
                ),
              ),
              ReaderSettingRow(
                icon: Icons.format_color_text,
                title: dark ? '深色文字' : '浅色文字',
                description: '选择正文文字的颜色',
                trailing: _ColorButton(
                  color:
                      dark
                          ? theme.state.darkTextColor
                          : theme.state.lightTextColor,
                  onPressed:
                      () => _color(
                        context,
                        dark
                            ? theme.state.darkTextColor
                            : theme.state.lightTextColor,
                        dark
                            ? theme.updateDarkTextColor
                            : theme.updateLightTextColor,
                      ),
                ),
              ),
            ],
            ReaderSettingRow(
              icon: Icons.image_outlined,
              title: '背景图片',
              description: '显示已设置的纸张背景',
              trailing: AppSwitch(
                value: paper.state.enabled,
                onChanged:
                    (v) => _save(context, () => paper.setEnabled(v)),
              ),
            ),
            for (final dark in [false, true])
              ReaderSettingRow(
                icon: Icons.add_photo_alternate_outlined,
                title: dark ? '深色背景图片' : '浅色背景图片',
                description: '从相册选择图片',
                trailing: AppButton.text(
                  child: const Text('选择'),
                  onPressed:
                      () => _save(
                        context,
                        dark
                            ? paper.updateDarkBackground
                            : paper.updateLightBackground,
                      ),
                ),
              ),
            slider(
              'reader-background-opacity',
              Icons.opacity,
              '背景浓度',
              '背景图片的不透明度',
              paper.state.opacity,
              0,
              1,
              paper.updateOpacity,
              decimals: 2,
              unit: '',
            ),
          ],
        ),
      ];
    }

    final listContent = ListView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, includeAll ? 8 : 12, 16, 24),
      children: [
        if (includeAll &&
            (Theme.of(context).platform != TargetPlatform.android ||
                dragHandle == null))
          dragHandle ??
              Center(
                child: Container(
                  key: const ValueKey('reader-settings-drag-handle'),
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: .3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
        if (includeAll && (includeMarks || (includeReloadChapter && !localEpub)))
          ReaderSettingGroup(
            children: [
              if (includeMarks)
                usesAppleGlass
                    ? IosSettingsRow(
                      key: const ValueKey('reader-settings-marks'),
                      icon: CupertinoIcons.bookmark,
                      title: '高亮与书签',
                      onTap:
                          () => Navigator.pop(
                            context,
                            _ReaderSheetSelection.marks,
                          ),
                    )
                    : ListTile(
                      key: const ValueKey('reader-settings-marks'),
                      leading: Icon(
                        Icons.bookmarks_outlined,
                        color: colors.primary,
                      ),
                      title: const Text('高亮与书签'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap:
                          () => Navigator.pop(
                            context,
                            _ReaderSheetSelection.marks,
                          ),
                    ),
              if (includeReloadChapter && !localEpub)
                usesAppleGlass
                    ? IosSettingsRow(
                      key: const ValueKey(
                        'reader-settings-reload-chapter',
                      ),
                      icon: CupertinoIcons.refresh,
                      title: '重新加载本章',
                      onTap:
                          () => Navigator.pop(
                            context,
                            _ReaderSheetSelection.reloadChapter,
                          ),
                    )
                    : ListTile(
                      key: const ValueKey(
                        'reader-settings-reload-chapter',
                      ),
                      leading: Icon(
                        Icons.refresh_rounded,
                        color: colors.primary,
                      ),
                      title: const Text('重新加载本章'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap:
                          () => Navigator.pop(
                            context,
                            _ReaderSheetSelection.reloadChapter,
                          ),
                    ),
            ],
          ),
        if (includeAll || section == ReaderSettingsSection.typography)
          ...buildTypographySection(),
        if (includeAll || section == ReaderSettingsSection.readingMode)
          ...buildReadingModeSection(),
        if (includeAll || section == ReaderSettingsSection.appearance)
          ...buildAppearanceSection(),
        if (includeAll && autoScroll != null) ...[
          const ReaderSettingLabel('自动滚动'),
          BlocBuilder<AutoScrollConfigCubit, AutoScrollConfig>(
            bloc: autoScroll,
            builder:
                (context, config) => ReaderSettingGroup(
                  children: [
                    slider(
                      'reader-scroll-speed',
                      Icons.speed,
                      '滚动速度',
                      '自动滚动的速度',
                      config.scrollSpeed,
                      .5,
                      3,
                      autoScroll!.updateScrollSpeed,
                      decimals: 1,
                      unit: '倍',
                    ),
                    slider(
                      'reader-scroll-interval',
                      Icons.timer_outlined,
                      '滚动间隔',
                      '自动滚动的参考间隔',
                      config.scrollInterval.toDouble(),
                      8,
                      32,
                      (v) => autoScroll!.updateScrollInterval(v.round()),
                      unit: 'ms',
                    ),
                  ],
                ),
          ),
        ],
      ],
    );

    if (!includeAll) {
      return ColoredBox(
        color: background,
        child: SafeArea(top: false, child: listContent),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(usesAppleGlass ? 36 : 28),
      ),
      child: ColoredBox(
        color: background,
        child: SafeArea(
          top: false,
          child: _ReaderSettingsViewport(
            pinnedHandle:
                Theme.of(context).platform == TargetPlatform.android
                    ? dragHandle
                    : null,
            child: listContent,
          ),
        ),
      ),
    );
  }
}

class _ReaderSettingsViewport extends StatelessWidget {
  const _ReaderSettingsViewport({
    required this.pinnedHandle,
    required this.child,
  });
  final Widget? pinnedHandle;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      pinnedHandle == null
          ? child
          : Column(
            children: [
              pinnedHandle!,
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(overscroll: false),
                  child: child,
                ),
              ),
            ],
          );
}

class ReaderSettingLabel extends StatelessWidget {
  const ReaderSettingLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 24, 14, 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class ReaderSettingGroup extends StatelessWidget {
  const ReaderSettingGroup({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            usesAppleGlass
                ? iosGroupedDivider(
                  context,
                  indent: const EdgeInsetsDirectional.only(
                    start: IosSettingsSection.titleStartIndent,
                  ),
                )
                : Padding(
                  padding: const EdgeInsets.only(left: 64, right: 18),
                  child: Divider(
                    height: 1,
                    thickness: .5,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .12),
                  ),
                ),
          children[i],
        ],
      ],
    );
    if (usesAppleGlass) {
      return IosGroupedCardSurface(
        color: IosSystemColors.color('surface', Theme.of(context).brightness),
        clipBehavior: Clip.antiAlias,
        child: content,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            usesMaterialYou
                ? materialRaisedSurface(Theme.of(context).colorScheme)
                : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(
          usesMaterialYou ? materialCardRadius : 24,
        ),
      ),
      child: content,
    );
  }
}

class ReaderSettingRow extends StatelessWidget {
  const ReaderSettingRow({
    super.key,
    required this.icon,
    required this.title,
    this.description = '',
    this.valueLabel,
    required this.trailing,
  });
  final IconData icon;
  final String title, description;
  final String? valueLabel;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    if (usesAppleGlass) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      Widget row = ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: IosSettingsRow.minRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 16, 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.4;
              final header = Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: stacked ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  if (valueLabel != null && valueLabel!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    ExcludeSemantics(
                      child: Text(
                        valueLabel!,
                        maxLines: 1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 15,
                          color: colors.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ],
              );
              return Row(
                crossAxisAlignment:
                    stacked
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: stacked ? 6 : 0, right: 16),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: Center(
                        child: ExcludeSemantics(
                          child: Icon(icon, size: 22, color: colors.onSurface),
                        ),
                      ),
                    ),
                  ),
                  if (stacked)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            header,
                            const SizedBox(height: 8),
                            trailing,
                          ],
                        ),
                      ),
                    )
                  else ...[
                    Expanded(child: header),
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .44,
                      ),
                      child: trailing,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
      if (valueLabel != null && valueLabel!.isNotEmpty) {
        row = Semantics(value: valueLabel, child: row);
      }
      return row;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final text = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          );
          final narrow =
              constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.4;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 16),
                child: Icon(icon, color: Theme.of(context).colorScheme.primary),
              ),
              if (narrow)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [text]),
                      const SizedBox(height: 12),
                      trailing,
                    ],
                  ),
                )
              else ...[
                text,
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * .43,
                  ),
                  child: trailing,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class ReaderSettingSlider extends StatefulWidget {
  const ReaderSettingSlider({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.onSaved,
    this.decimals = 0,
    this.unit = '点',
  });
  final IconData icon;
  final String title, description, unit;
  final double value, min, max;
  final int decimals;
  final Future<void> Function(double) onSaved;
  @override
  State<ReaderSettingSlider> createState() => _ReaderSettingSliderState();
}

class _ReaderSettingSliderState extends State<ReaderSettingSlider> {
  double? _draft;
  bool _saving = false;
  @override
  Widget build(BuildContext context) {
    final current = (_draft ?? widget.value).clamp(widget.min, widget.max);
    final formatted = current.toStringAsFixed(widget.decimals);
    final compactValue =
        widget.unit.isEmpty ? formatted : '$formatted ${widget.unit}';
    return ReaderSettingRow(
      icon: widget.icon,
      title:
          usesAppleGlass || _draft == null
              ? widget.title
              : '${widget.title} · ${_draft!.toStringAsFixed(widget.decimals)}',
      description: widget.description,
      valueLabel: usesAppleGlass ? compactValue : null,
      trailing: SizedBox(
        width: 240,
        child: Semantics(
          label: widget.title,
          value: compactValue,
          child: AppSlider(
            value: current,
            min: widget.min,
            max: widget.max,
            divisions: ((widget.max - widget.min) *
                    (widget.decimals == 0 ? 1 : 10))
                .round()
                .clamp(1, 100),
            onChanged: _saving ? null : (v) => setState(() => _draft = v),
            onChangeCancel: () => setState(() => _draft = null),
            onChangeEnd: (v) async {
              setState(() => _saving = true);
              try {
                await widget.onSaved(v);
              } finally {
                if (mounted) {
                  setState(() {
                    _saving = false;
                    _draft = null;
                  });
                }
              }
            },
          ),
        ),
      ),
    );
  }
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({required this.color, required this.onPressed});
  final Color color;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => AppIconButton(
    tooltip: '选择颜色',
    onPressed: onPressed,
    icon: Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );
}
