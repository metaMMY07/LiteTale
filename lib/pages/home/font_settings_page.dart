import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/services/imported_fonts.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class FontSettingsPage extends StatelessWidget {
  const FontSettingsPage({super.key});

  void _notice(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _change(
    BuildContext context,
    FontScope scope, {
    bool reset = false,
  }) async {
    final cubit = context.read<FontSettingsCubit>();
    try {
      final applied =
          await (reset ? cubit.reset(scope) : cubit.importFont(scope));
      if (!context.mounted || !applied) return;
      _notice(context, reset ? '已恢复默认字体' : '字体已应用');
    } catch (error) {
      if (!context.mounted) return;
      _notice(
        context,
        error is FontImportException ? error.message : '字体导入失败，请重试',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('字体设置')),
    body: BlocBuilder<FontSettingsCubit, FontSettingsState>(
      builder: (context, state) {
        final colors = Theme.of(context).colorScheme;
        return LeftAlignedScrollView(
          topInset: 12,
          bottomInset: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '选择你喜欢的字形',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                '支持 TTF、OTF 字体（最大 64 MB）。导入后立即生效，重启后保留；两项设置相互独立。',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              if (state.restoreWarning != null) ...[
                const SizedBox(height: 12),
                Text(
                  state.restoreWarning!,
                  style: TextStyle(color: colors.error),
                ),
              ],
              for (final scope in FontScope.values) ...[
                const SizedBox(height: 20),
                Card.filled(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              scope == FontScope.app
                                  ? Icons.text_fields_rounded
                                  : Icons.menu_book_rounded,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                scope == FontScope.app ? '全局界面字体' : '小说阅读字体',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          state.fontFor(scope)?.name ??
                              (scope == FontScope.app
                                  ? '默认 · 系统界面字体'
                                  : '默认 · 霞鹜新致宋'),
                          key: ValueKey('font-name-${scope.name}'),
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            '山海有故事，字里有光。\nLiteTale · Aa Bb 0123456789',
                            key: ValueKey('font-preview-${scope.name}'),
                            style: TextStyle(
                              fontFamily:
                                  scope == FontScope.app
                                      ? state.appFamily
                                      : state.readerFamily,
                              fontFamilyFallback:
                                  scope == FontScope.reader ||
                                          state.appFamily != null
                                      ? const [appFontFamily]
                                      : null,
                              fontSize: 20,
                              height: 1.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              key: ValueKey('font-import-${scope.name}'),
                              onPressed:
                                  state.busy != null
                                      ? null
                                      : () => _change(context, scope),
                              icon:
                                  state.busy == scope
                                      ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.file_open_outlined),
                              label: Text(
                                state.busy == scope ? '正在处理…' : '导入字体',
                              ),
                            ),
                            TextButton(
                              key: ValueKey('font-reset-${scope.name}'),
                              onPressed:
                                  state.busy != null ||
                                          state.fontFor(scope) == null
                                      ? null
                                      : () =>
                                          _change(context, scope, reset: true),
                              child: const Text('恢复默认'),
                            ),
                          ],
                        ),
                        if (scope == FontScope.reader) ...[
                          const SizedBox(height: 8),
                          Text(
                            '用于分页和滚动阅读。文库8与轻小说百科支持自选字体；轻书架加密正文使用书源字体，章节标题使用这里选择的字体。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}
