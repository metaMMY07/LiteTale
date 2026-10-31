import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_website.dart';
import 'package:wild/theme/material_you.dart';
import 'apple_glass_chrome.dart';
import 'platform_controls.dart';
import 'source_website.dart';

/// Choosing a source and opening its website are independent actions.
/// Dismissing this sheet never changes the current source or its account.
Future<SourceId?> showSourcePicker(
  BuildContext context, {
  required SourceId value,
  required List<SourceId> sources,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final host = context.read<ApiHostCubit?>()?.state;
  final choices = List<SourceId>.unmodifiable(sources);
  Widget sheet(BuildContext context) =>
      _SourceChoices(value: value, sources: choices, wenku8Host: host);
  if (usesAppleGlass) {
    return showCupertinoModalPopup<SourceId>(
      context: context,
      builder:
          (context) => SafeArea(
            top: false,
            child: AppleGlassCard(
              margin: EdgeInsets.zero,
              child: sheet(context),
            ),
          ),
    );
  }
  return showModalBottomSheet<SourceId>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: double.infinity),
    builder: sheet,
  );
}

class _SourceChoices extends StatelessWidget {
  const _SourceChoices({
    required this.value,
    required this.sources,
    this.wenku8Host,
  });
  final SourceId value;
  final List<SourceId> sources;
  final String? wenku8Host;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text('选择书源', style: theme.textTheme.titleLarge),
                  ),
                  AppIconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: sources.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final source = sources[index];
                  final active = source == value;
                  final uri = sourceWebsite(source, wenku8Host: wenku8Host);
                  final tile = InkWell(
                    onTap: () => Navigator.pop(context, source),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.local_library_outlined,
                                color:
                                    active
                                        ? colors.onSecondaryContainer
                                        : colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  source.label,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color:
                                        active
                                            ? colors.onSecondaryContainer
                                            : colors.onSurface,
                                  ),
                                ),
                              ),
                              if (uri != null)
                                AppIconButton(
                                  tooltip: '打开${source.label}原网站',
                                  onPressed:
                                      () => openSourceWebsite(context, uri),
                                  icon: const Icon(
                                    Icons.open_in_browser_rounded,
                                  ),
                                ),
                              if (active) const Icon(Icons.check_rounded),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            uri == null
                                ? (source.isRule ? '导入的书源 · 原网址未配置' : '本地书籍')
                                : '$uri',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color:
                                  active
                                      ? colors.onSecondaryContainer
                                      : colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                  return Semantics(
                    selected: active,
                    child:
                        usesAppleGlass
                            ? AppleGlassCard(
                              key: ValueKey('source-option-${source.name}'),
                              margin: EdgeInsets.zero,
                              color: active ? colors.secondaryContainer : null,
                              child: tile,
                            )
                            : Material(
                              key: ValueKey('source-option-${source.name}'),
                              color:
                                  active
                                      ? colors.secondaryContainer
                                      : materialSurface(
                                        colors,
                                        colors.surfaceContainerHigh,
                                        .08,
                                      ),
                              borderRadius: BorderRadius.circular(20),
                              clipBehavior: Clip.antiAlias,
                              child: tile,
                            ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
