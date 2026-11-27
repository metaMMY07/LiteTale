import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/qwen_reader_tts.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

Future<ListeningVoice?> showListeningVoicePanel(
  BuildContext context,
  ListeningVoice selected,
  Future<void> Function(ListeningVoice) preview, {
  VoidCallback? onQwenSettingsChange,
}) async {
  ModalRoute<ListeningVoice>? route;
  final result = await showAppBottomSheet<ListeningVoice>(
    context: context,
    isScrollControlled: true,
    useGlass: false,
    builder: (context) {
      route = ModalRoute.of<ListeningVoice>(context);
      return _ListeningVoicePanel(
        selected: selected,
        preview: preview,
        onQwenSettingsChange: onQwenSettingsChange,
      );
    },
  );
  await route?.completed;
  return result;
}

class _ListeningVoicePanel extends StatefulWidget {
  const _ListeningVoicePanel({
    required this.selected,
    required this.preview,
    this.onQwenSettingsChange,
  });
  final ListeningVoice selected;
  final Future<void> Function(ListeningVoice) preview;
  final VoidCallback? onQwenSettingsChange;

  @override
  State<_ListeningVoicePanel> createState() => _ListeningVoicePanelState();
}

class _ListeningVoicePanelState extends State<_ListeningVoicePanel> {
  List<ListeningVoice>? _extraVoices;
  late Future<QwenTtsSettings?> _qwenSettings = QwenTtsSettings.load();
  bool _loading = false, _previewing = false, _editing = false;
  String? _message;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final extra = await ListeningVoice.fetchOnline();
      if (!mounted) return;
      setState(() => _extraVoices = extra);
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

  Future<void> _configureQwen(QwenTtsSettings? current) async {
    if (_editing) return;
    _editing = true;
    try {
      final change = await showAdaptiveDialog<({QwenTtsSettings? settings})>(
        context: context,
        builder: (_) => _QwenSettingsDialog(region: current?.region),
      );
      if (!mounted || change == null) return;
      widget.onQwenSettingsChange?.call();
      final saved = change.settings;
      if (saved == null) {
        await QwenTtsSettings.remove();
      } else {
        await saved.save();
      }
      if (!mounted) return;
      if (saved == null && widget.selected.qwenVoice != null) {
        Navigator.pop(context, ListeningVoice.xiaoxiao);
      } else {
        setState(() {
          _qwenSettings = Future.value(saved);
          _message = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '百炼设置暂未保存，请重试');
    } finally {
      _editing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voices = [...ListeningVoice.defaults, ...?_extraVoices];
    if (widget.selected.qwenVoice == null &&
        !voices.any((voice) => voice.id == widget.selected.id)) {
      voices.add(widget.selected);
    }
    final rows = [
      for (final voice in voices) _voiceRow(voice),
      if (_extraVoices == null)
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
          FutureBuilder<QwenTtsSettings?>(
            future: _qwenSettings,
            builder: (context, snapshot) {
              final settings = snapshot.data;
              final title = settings == null ? '配置百炼 API Key' : '更换百炼 API Key';
              void configure() => _configureQwen(settings);
              final qwenRows = [
                for (final voice in ListeningVoice.qwenPresets)
                  _voiceRow(
                    voice,
                    configure: settings == null ? configure : null,
                  ),
                if (usesAppleGlass)
                  IosSettingsRow(
                    icon: CupertinoIcons.lock,
                    title: title,
                    onTap: configure,
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: Text(title),
                    onTap: configure,
                  ),
              ];
              return usesAppleGlass
                  ? IosSettingsSection(title: '千问在线音色', rows: qwenRows)
                  : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        child: Semantics(
                          header: true,
                          child: Text(
                            '千问在线音色',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      ),
                      SettingsTileGroup(children: qwenRows),
                    ],
                  );
            },
          ),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(message, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _voiceRow(ListeningVoice voice, {VoidCallback? configure}) {
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
          onPressed:
              _previewing || configure != null ? null : () => _preview(voice),
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
                onTap: configure ?? select,
              )
              : ListTile(
                selected: selected,
                leading: const Icon(Icons.graphic_eq),
                title: Text(voice.name),
                trailing: actions,
                onTap: configure ?? select,
              ),
    );
  }
}

class _QwenSettingsDialog extends StatefulWidget {
  const _QwenSettingsDialog({this.region});

  final QwenTtsRegion? region;

  @override
  State<_QwenSettingsDialog> createState() => _QwenSettingsDialogState();
}

class _QwenSettingsDialogState extends State<_QwenSettingsDialog> {
  final _key = TextEditingController();
  late QwenTtsRegion _region = widget.region ?? QwenTtsRegion.beijing;
  String? _error;

  void _save() {
    final apiKey = _key.text.trim();
    if (!QwenTtsSettings.acceptsApiKey(apiKey)) {
      setState(() => _error = '请输入有效的百炼 API Key');
      return;
    }
    Navigator.pop(context, (
      settings: QwenTtsSettings(region: _region, apiKey: apiKey),
    ));
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final regions = QwenTtsRegion.values;
    return AlertDialog.adaptive(
      title: const Text('百炼 API Key'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('选择密钥所属地域。使用千问音色时，朗读段落将发送至百炼合成并计入账户用量。'),
          const SizedBox(height: 12),
          if (usesAppleGlass)
            CupertinoSlidingSegmentedControl<QwenTtsRegion>(
              groupValue: _region,
              children: {
                for (final region in regions) region: Text(region.label),
              },
              onValueChanged: (region) {
                if (region != null) setState(() => _region = region);
              },
            )
          else
            SegmentedButton<QwenTtsRegion>(
              segments: [
                for (final region in regions)
                  ButtonSegment(value: region, label: Text(region.label)),
              ],
              selected: {_region},
              onSelectionChanged:
                  (regions) => setState(() => _region = regions.single),
            ),
          const SizedBox(height: 12),
          AppTextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: 'API Key',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        if (widget.region != null)
          AppButton.text(
            onPressed: () => Navigator.pop(context, (settings: null)),
            child: const Text('移除密钥'),
          ),
        AppButton.text(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        AppButton.text(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
