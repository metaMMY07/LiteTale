import 'package:flutter/material.dart';
import 'package:wild/services/launcher_icon_service.dart';

class LauncherIconSettings extends StatefulWidget {
  const LauncherIconSettings({
    super.key,
    this.service = const LauncherIconService(),
  });

  final LauncherIconService service;

  @override
  State<LauncherIconSettings> createState() => _LauncherIconSettingsState();
}

class _LauncherIconSettingsState extends State<LauncherIconSettings> {
  String? _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final selected = await widget.service.current();
      if (mounted) setState(() => _selected = selected);
    } catch (_) {
      if (mounted) setState(() => _selected = 'iris');
    }
  }

  Future<void> _choose(String name) async {
    if (_busy || _selected == name) return;
    setState(() => _busy = true);
    try {
      await widget.service.select(name);
      if (mounted) setState(() => _selected = name);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('应用图标切换失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('应用图标', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('选择桌面上的书本颜色，界面主题可以单独设置。'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final entry in launcherIconChoices.entries)
                Semantics(
                  button: true,
                  selected: _selected == entry.key,
                  label: '${entry.value}应用图标',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _busy ? null : () => _choose(entry.key),
                    child: Container(
                      width: 100,
                      padding: const EdgeInsets.fromLTRB(8, 9, 8, 10),
                      decoration: BoxDecoration(
                        color:
                            _selected == entry.key
                                ? colors.secondaryContainer
                                : colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color:
                              _selected == entry.key
                                  ? colors.primary
                                  : colors.outlineVariant,
                          width: _selected == entry.key ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            'assets/icon_previews/${entry.key}.png',
                            width: 62,
                            height: 62,
                            filterQuality: FilterQuality.medium,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            entry.value,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('部分桌面需要片刻刷新图标。', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
