import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
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

/// A projection of LiteTale's own preferences. Native UI owns layout/drafts;
/// existing cubits remain the only persistence and reader layout authority.
class ReaderSettingsBinding {
  ReaderSettingsBinding(
    BuildContext context, {
    this.onLayoutChanged,
    this.autoScroll,
  }) : _context = context,
       size = context.read<FontSizeCubit>(),
       line = context.read<LineHeightCubit>(),
       spacing = context.read<ParagraphSpacingCubit>(),
       left = context.read<LeftPaddingCubit>(),
       right = context.read<RightPaddingCubit>(),
       top = context.read<TopBarHeightCubit>(),
       bottom = context.read<BottomBarHeightCubit>(),
       theme = context.read<ThemeCubit>(),
       type = context.read<ReaderTypeCubit>(),
       volume = context.read<VolumeControlCubit>(),
       paper = context.read<ReaderBackgroundCubit>();

  final BuildContext _context;
  final FontSizeCubit size;
  final LineHeightCubit line;
  final ParagraphSpacingCubit spacing;
  final LeftPaddingCubit left;
  final RightPaddingCubit right;
  final TopBarHeightCubit top;
  final BottomBarHeightCubit bottom;
  final ThemeCubit theme;
  final ReaderTypeCubit type;
  final VolumeControlCubit volume;
  final ReaderBackgroundCubit paper;
  final AutoScrollConfigCubit? autoScroll;
  final Future<void> Function()? onLayoutChanged;
  final _pending = <String>{};

  Map<String, Object?> snapshot() {
    final colors = Theme.of(_context).colorScheme;
    Map<String, Object?> slider(
      String id,
      String icon,
      String title,
      String description,
      double value,
      double min,
      double max, {
      double step = 1,
      String unit = '点',
    }) => {
      'id': id,
      'kind': 'slider',
      'icon': icon,
      'title': title,
      'description': description,
      'value': value,
      'min': min,
      'max': max,
      'step': step,
      'unit': unit,
    };
    Map<String, Object?> row(
      String id,
      String kind,
      String icon,
      String title,
      String description,
      Object value, {
      List<String>? choices,
    }) => {
      'id': id,
      'kind': kind,
      'icon': icon,
      'title': title,
      'description': description,
      'value': value,
      if (choices != null) 'choices': choices,
    };
    return {
      'title': '阅读设置',
      'dark': colors.brightness == Brightness.dark,
      'accent': colors.primary.toARGB32(),
      'sections': [
        {
          'title': '排版',
          'rows': [
            slider(
              'size',
              'textformat.size',
              '字号',
              '小说正文的文字大小',
              size.state,
              10,
              40,
            ),
            slider(
              'line',
              'line.3.horizontal',
              '行高',
              '段落中的行间距',
              line.state,
              1,
              2.5,
              step: .1,
              unit: '倍',
            ),
            slider(
              'spacing',
              'paragraphsign',
              '段间距',
              '相邻段落之间的额外留白',
              spacing.state,
              0,
              60,
            ),
            slider(
              'left',
              'arrow.right.to.line',
              '左侧留白',
              '阅读内容左侧的页边距',
              left.state,
              0,
              80,
            ),
            slider(
              'right',
              'arrow.left.to.line',
              '右侧留白',
              '阅读内容右侧的页边距',
              right.state,
              0,
              80,
            ),
            slider(
              'top',
              'arrow.up.to.line',
              '上边距',
              '正文上方的留白',
              top.state,
              0,
              80,
            ),
            slider(
              'bottom',
              'arrow.down.to.line',
              '下边距',
              '正文下方的留白',
              bottom.state,
              0,
              80,
            ),
          ],
        },
        {
          'title': '阅读方式',
          'rows': [
            row(
              'mode',
              'choice',
              'book.pages',
              '阅读模式',
              '重新打开阅读器后生效',
              type.state == ReaderType.normal ? '分页' : '滚动',
              choices: ['分页', '滚动'],
            ),
            {
              ...row(
                'volume',
                'toggle',
                'speaker.wave.2',
                '音量键翻页',
                '上键上一页，下键下一页',
                volume.state,
              ),
              'enabled': volume.isSupported,
            },
          ],
        },
        {
          'title': '阅读器外观',
          'rows': [
            row(
              'theme',
              'choice',
              'circle.lefthalf.filled',
              '深浅色',
              '独立保存浅色和深色纸张',
              switch (theme.state.themeMode) {
                ReaderThemeMode.auto => '跟随系统',
                ReaderThemeMode.light => '浅色',
                ReaderThemeMode.dark => '深色',
              },
              choices: ['跟随系统', '浅色', '深色'],
            ),
            for (final dark in [false, true]) ...[
              row(
                dark ? 'darkBackground' : 'lightBackground',
                'color',
                'paintbrush',
                dark ? '深色背景' : '浅色背景',
                '选择正文页面的背景色',
                (dark
                        ? theme.state.darkBackgroundColor
                        : theme.state.lightBackgroundColor)
                    .toARGB32(),
              ),
              row(
                dark ? 'darkText' : 'lightText',
                'color',
                'textformat',
                dark ? '深色文字' : '浅色文字',
                '选择正文文字的颜色',
                (dark ? theme.state.darkTextColor : theme.state.lightTextColor)
                    .toARGB32(),
              ),
            ],
            row(
              'paper',
              'toggle',
              'photo',
              '背景图片',
              '显示已设置的纸张背景',
              paper.state.enabled,
            ),
            row(
              'lightPhoto',
              'photo',
              'photo.badge.plus',
              '浅色背景图片',
              '从相册选择图片',
              '选择',
            ),
            row(
              'darkPhoto',
              'photo',
              'photo.badge.plus',
              '深色背景图片',
              '从相册选择图片',
              '选择',
            ),
            slider(
              'opacity',
              'circle.lefthalf.filled',
              '背景浓度',
              '背景图片的不透明度',
              paper.state.opacity,
              0,
              1,
              step: .01,
              unit: '',
            ),
          ],
        },
        if (autoScroll != null)
          {
            'title': '自动滚动',
            'rows': [
              slider(
                'speed',
                'speedometer',
                '滚动速度',
                '自动滚动的速度',
                autoScroll!.state.scrollSpeed,
                .5,
                3,
                step: .1,
                unit: '倍',
              ),
              slider(
                'interval',
                'timer',
                '滚动间隔',
                '自动滚动的参考间隔',
                autoScroll!.state.scrollInterval.toDouble(),
                8,
                32,
                unit: 'ms',
              ),
            ],
          },
      ],
    };
  }

  Future<Map<String, Object?>> change(Map<Object?, Object?> event) async {
    final id = event['id'];
    if (!_context.mounted || id is! String || _pending.contains(id)) return {};
    final rows =
        (snapshot()['sections'] as List)
            .cast<Map>()
            .expand((s) => s['rows'] as List)
            .cast<Map>();
    final row = rows.where((r) => r['id'] == id).firstOrNull;
    if (row == null || row['enabled'] == false) return {};
    var value = event['value'];
    final kind = row['kind'];
    if (kind == 'slider') {
      if (value is! num || !value.toDouble().isFinite) return {};
      final min = row['min'] as double, max = row['max'] as double;
      final step = row['step'] as double;
      value = (min +
              ((value.toDouble().clamp(min, max) - min) / step).round() * step)
          .clamp(min, max);
    } else if (kind == 'toggle' && value is! bool ||
        kind == 'color' && (value is! int || value < 0 || value > 0xffffffff) ||
        kind == 'choice' && !(row['choices'] as List).contains(value) ||
        kind == 'photo' &&
            (value is! Uint8List ||
                value.isEmpty ||
                value.length > 64 * 1024 * 1024)) {
      return {};
    }
    _pending.add(id);
    String? error;
    try {
      switch (id) {
        case 'size':
          await size.updateFontSize(value as double);
        case 'line':
          await line.updateLineHeight(value as double);
        case 'spacing':
          await spacing.updateSpacing(value as double);
        case 'left':
          await left.updatePadding(value as double);
        case 'right':
          await right.updatePadding(value as double);
        case 'top':
          await top.updateHeight(value as double);
        case 'bottom':
          await bottom.updateHeight(value as double);
        case 'mode':
          await type.updateType(
            value == '分页' ? ReaderType.normal : ReaderType.html,
          );
        case 'volume':
          await volume.updateVolumeControl(value as bool);
        case 'theme':
          await theme.setThemeMode(
            value == '浅色'
                ? ReaderThemeMode.light
                : value == '深色'
                ? ReaderThemeMode.dark
                : ReaderThemeMode.auto,
          );
        case 'lightBackground':
          await theme.updateLightBackgroundColor(Color(value as int));
        case 'lightText':
          await theme.updateLightTextColor(Color(value as int));
        case 'darkBackground':
          await theme.updateDarkBackgroundColor(Color(value as int));
        case 'darkText':
          await theme.updateDarkTextColor(Color(value as int));
        case 'paper':
          await paper.setEnabled(value as bool);
        case 'lightPhoto':
          await paper.importBackgroundImage(value as Uint8List, dark: false);
        case 'darkPhoto':
          await paper.importBackgroundImage(value as Uint8List, dark: true);
        case 'opacity':
          await paper.updateOpacity(value as double);
        case 'speed':
          await autoScroll!.updateScrollSpeed(value as double);
        case 'interval':
          await autoScroll!.updateScrollInterval((value as double).round());
      }
      if (id != 'mode' && id != 'volume' && _context.mounted) {
        await onLayoutChanged?.call();
      }
    } catch (e) {
      error = '保存设置失败：$e';
    } finally {
      _pending.remove(id);
    }
    return {
      if (_context.mounted) 'configuration': snapshot(),
      if (error != null) 'error': error,
    };
  }
}
