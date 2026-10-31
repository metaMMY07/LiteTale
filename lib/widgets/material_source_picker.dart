import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/material_you.dart';
import 'source_picker_sheet.dart';

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
    final selected = await showSourcePicker(
      context,
      value: value,
      sources: sources,
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
