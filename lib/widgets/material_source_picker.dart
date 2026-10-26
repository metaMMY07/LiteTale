import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/material_you.dart';

/// A full-width, scrollable card list. Opening or dismissing it never changes
/// the active provider; the owner commits only a returned selection.
class MaterialSourcePicker extends StatelessWidget {
  const MaterialSourcePicker({
    super.key,
    required this.value,
    required this.sources,
    required this.onChanged,
  });

  final SourceId value;
  final List<SourceId> sources;
  final ValueChanged<SourceId> onChanged;

  Future<void> _open(BuildContext context) async {
    final selected = await showModalBottomSheet<SourceId>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      builder: (context) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('选择书源', style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
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
                      return Semantics(
                        selected: active,
                        child: Material(
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
                          child: ListTile(
                            minVerticalPadding: 16,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                            ),
                            leading: Icon(
                              Icons.local_library_outlined,
                              color:
                                  active
                                      ? colors.onSecondaryContainer
                                      : colors.onSurfaceVariant,
                            ),
                            title: Text(
                              source.label,
                              style: TextStyle(
                                color:
                                    active
                                        ? colors.onSecondaryContainer
                                        : colors.onSurface,
                              ),
                            ),
                            subtitle:
                                source.isRule ? const Text('导入的书源') : null,
                            trailing:
                                active ? const Icon(Icons.check_rounded) : null,
                            onTap: () => Navigator.pop(context, source),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (context.mounted && selected != null && selected != value) {
      onChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: materialSurface(colors, colors.surfaceContainerHighest, .12),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const ValueKey('source-picker-button'),
        minVerticalPadding: 12,
        leading: const Icon(Icons.local_library_outlined),
        title: Text('当前书源', style: Theme.of(context).textTheme.labelMedium),
        subtitle: Text(
          value.label,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        trailing: const Icon(Icons.unfold_more_rounded),
        onTap: () => _open(context),
      ),
    );
  }
}
