import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

Future<ListeningVoice?> showListeningVoicePanel(
  BuildContext context,
  ListeningVoice selected,
  Future<void> Function(ListeningVoice) preview,
) async {
  ModalRoute<ListeningVoice>? route;
  final result = await showAppBottomSheet<ListeningVoice>(
    context: context,
    isScrollControlled: true,
    useGlass: false,
    builder: (context) {
      route = ModalRoute.of<ListeningVoice>(context);
      return _ListeningVoicePanel(selected: selected, preview: preview);
    },
  );
  await route?.completed;
  return result;
}

class _ListeningVoicePanel extends StatefulWidget {
  const _ListeningVoicePanel({required this.selected, required this.preview});
  final ListeningVoice selected;
  final Future<void> Function(ListeningVoice) preview;

  @override
  State<_ListeningVoicePanel> createState() => _ListeningVoicePanelState();
}

class _ListeningVoicePanelState extends State<_ListeningVoicePanel> {
  late List<ListeningVoice> _voices = [
    ListeningVoice.female,
    ListeningVoice.male,
    if (widget.selected.id != ListeningVoice.female.id &&
        widget.selected.id != ListeningVoice.male.id)
      widget.selected,
  ];
  bool _loading = false, _expanded = false, _previewing = false;
  String? _message;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final extra = await ListeningVoice.fetchOnline();
      if (!mounted) return;
      setState(() {
        _voices = [
          ListeningVoice.female,
          ListeningVoice.male,
          ...extra,
          if (!_voices.take(2).any((voice) => voice.id == widget.selected.id) &&
              !extra.any((voice) => voice.id == widget.selected.id))
            widget.selected,
        ];
        _expanded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _message = '音色列表暂时无法加载，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _preview(ListeningVoice voice) async {
    setState(() {
      _previewing = true;
      _message = null;
    });
    try {
      await widget.preview(voice);
    } catch (error) {
      if (mounted) {
        setState(() {
          _message =
              error is PlatformException
                  ? error.message ?? '试听失败，请重试'
                  : '试听失败，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = [
      for (final voice in _voices) _voiceRow(voice),
      if (!_expanded)
        usesAppleGlass
            ? IosSettingsRow(
              icon: CupertinoIcons.cloud_download,
              title: '获取更多在线音色',
              trailing: _loading ? const CupertinoActivityIndicator() : null,
              onTap: _loading ? null : _load,
            )
            : ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('获取更多在线音色'),
              trailing: _loading ? const CircularProgressIndicator() : null,
              onTap: _loading ? null : _load,
            ),
    ];
    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          Row(
            children: [
              Expanded(child: Text('音色', style: theme.textTheme.titleLarge)),
              AppIconButton(
                tooltip: '关闭音色',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(usesAppleGlass ? CupertinoIcons.xmark : Icons.close),
              ),
            ],
          ),
          if (usesAppleGlass)
            IosSettingsSection(title: '在线音色', rows: rows)
          else
            SettingsTileGroup(children: rows),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(message, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _voiceRow(ListeningVoice voice) {
    final selected = voice.id == widget.selected.id;
    final color = Theme.of(context).colorScheme.primary;
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected)
          Icon(
            usesAppleGlass ? CupertinoIcons.check_mark : Icons.check,
            color: color,
            size: 16,
          ),
        AppIconButton(
          tooltip: '试听 ${voice.name}',
          onPressed: _previewing ? null : () => _preview(voice),
          icon: Icon(usesAppleGlass ? CupertinoIcons.play : Icons.play_arrow),
        ),
      ],
    );
    void select() => Navigator.of(context).pop(voice);
    return Semantics(
      selected: selected,
      child:
          usesAppleGlass
              ? IosSettingsRow(
                icon: CupertinoIcons.waveform,
                title: voice.name,
                trailing: actions,
                onTap: select,
              )
              : ListTile(
                selected: selected,
                leading: const Icon(Icons.graphic_eq),
                title: Text(voice.name),
                trailing: actions,
                onTap: select,
              ),
    );
  }
}
