import 'package:flutter/material.dart';
import 'package:wild/theme/material_you.dart';

/// Filled, separated choices instead of the older outlined segmented control.
/// Keeps the same enabled, single/multiple-selection and empty-selection rules.
class MaterialChoiceBar<T> extends StatelessWidget {
  const MaterialChoiceBar({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.style,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;
  final ButtonStyle? style;

  void _select(T value) {
    final next = multiSelectionEnabled ? {...selected} : <T>{};
    if (selected.contains(value)) {
      if (multiSelectionEnabled) next.remove(value);
      if (next.isEmpty && !emptySelectionAllowed) return;
    } else {
      next.add(value);
    }
    onSelectionChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: materialSurface(colors, colors.surfaceContainerHigh, .08),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final minimumWidth =
                64 * MediaQuery.textScalerOf(context).scale(14) / 14;
            final scroll =
                constraints.hasBoundedWidth &&
                constraints.maxWidth <
                    minimumWidth * segments.length + 4 * (segments.length - 1);
            final expand = constraints.hasBoundedWidth && !scroll;
            final row = Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                for (var i = 0; i < segments.length; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  if (expand)
                    Expanded(child: _choice(context, segments[i]))
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(minWidth: minimumWidth),
                      child: _choice(context, segments[i]),
                    ),
                ],
              ],
            );
            return scroll
                ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: row,
                )
                : row;
          },
        ),
      ),
    );
  }

  Widget _choice(BuildContext context, ButtonSegment<T> segment) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isSelected = selected.contains(segment.value);
    final enabled = segment.enabled && onSelectionChanged != null;
    final states = <WidgetState>{
      if (isSelected) WidgetState.selected,
      if (!enabled) WidgetState.disabled,
    };
    final foreground =
        style?.foregroundColor?.resolve(states) ??
        (enabled
            ? (isSelected
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant)
            : colors.onSurface.withValues(alpha: .38));
    final background =
        style?.backgroundColor?.resolve(states) ??
        (isSelected ? colors.secondaryContainer : Colors.transparent);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );
    Widget content = Semantics(
      button: true,
      selected: isSelected,
      enabled: enabled,
      child: Material(
        color: background,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => _select(segment.value) : null,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding:
                  style?.padding?.resolve(states) ??
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: DefaultTextStyle(
                style: (style?.textStyle?.resolve(states) ??
                        theme.textTheme.labelLarge ??
                        const TextStyle())
                    .copyWith(color: foreground),
                textAlign: TextAlign.center,
                child: IconTheme(
                  data: IconThemeData(color: foreground, size: 18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isSelected && showSelectedIcon)
                        const Icon(Icons.check_rounded)
                      else if (segment.icon != null)
                        segment.icon!,
                      if ((isSelected && showSelectedIcon ||
                              segment.icon != null) &&
                          segment.label != null)
                        const SizedBox(width: 6),
                      if (segment.label != null)
                        Flexible(child: segment.label!),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (segment.tooltip != null) {
      content = Tooltip(message: segment.tooltip!, child: content);
    }
    return content;
  }
}
