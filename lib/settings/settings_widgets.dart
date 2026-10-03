import 'package:flutter/material.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/settings/app_logs.dart';

Color settingsSurfaceLayer(ColorScheme colors, Color role, double contrast) {
  // Older Android dynamic palettes omit the newer M3 surface roles. Their
  // Flutter fallback is the base surface, which erases the settings groups.
  return role == colors.surface
      ? Color.alphaBlend(
        colors.onSurface.withValues(alpha: contrast),
        colors.surface,
      )
      : role;
}

// Layout and grouping follow LightNovelReader 1.1.0 (Apache-2.0).
// See docs/LNR_SETTINGS_REFERENCE_REVIEW.md for the pinned reference.
void openSettingsPage(BuildContext context, Widget page) =>
    Navigator.push(context, HorizontalCoverPageRoute(builder: (_) => page));

Future<void> settingsAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (_) {
    await AppLogs.instance.record('error', '设置操作未能完成');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作未能完成，请重试')));
    }
  }
}

class SettingsGroup extends StatefulWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.initiallyExpanded = true,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  State<SettingsGroup> createState() => _SettingsGroupState();
}

class _SettingsGroupState extends State<SettingsGroup> {
  late bool expanded = widget.initiallyExpanded;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Material(
        color: settingsSurfaceLayer(colors, colors.surfaceContainerLow, 0.04),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => expanded = !expanded),
              child: Semantics(
                button: true,
                expanded: expanded,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: settingsSurfaceLayer(
                            colors,
                            colors.surfaceContainerHigh,
                            0.10,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          widget.icon,
                          color: colors.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    children: [
                      for (var i = 0; i < widget.children.length; i++) ...[
                        if (i > 0) const SizedBox(height: 6),
                        widget.children[i],
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SettingsEntry extends StatelessWidget {
  const SettingsEntry({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.option,
    this.trailing,
    this.onTap,
    this.filled = true,
  });
  final IconData icon;
  final String title;
  final String? description;
  final String? option;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color:
          filled
              ? settingsSurfaceLayer(colors, colors.surfaceContainer, 0.07)
              : colors.surface,
      child: ListTile(
        leading: Icon(icon, color: colors.onSurfaceVariant, size: 22),
        title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
        subtitle:
            description == null && option == null
                ? null
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (description != null)
                      Text(
                        description!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (option != null)
                      Text(
                        option!,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.primary),
                      ),
                  ],
                ),
        trailing: trailing,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        onTap: onTap,
      ),
    );
  }
}

class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    required this.value,
    required this.onChanged,
    this.filled = false,
  });
  final IconData icon;
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool filled;
  @override
  Widget build(BuildContext context) => SettingsEntry(
    icon: icon,
    title: title,
    description: description,
    filled: filled,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

Future<T?> chooseSetting<T>(
  BuildContext context,
  String title,
  Map<T, String> options,
  T selected,
) => showDialog<T>(
  context: context,
  builder:
      (context) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in options.entries)
                  RadioListTile<T>(
                    title: Text(entry.value),
                    value: entry.key,
                    groupValue: selected,
                    onChanged: (v) => Navigator.pop(context, v),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
);
