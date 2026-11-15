import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

typedef VoicePreview = Future<void> Function(ListeningVoiceSettings);

Future<T?> _voiceSheet<T>(BuildContext context, WidgetBuilder builder) async {
  ModalRoute<T>? route;
  final result = await showAppBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      route = ModalRoute.of<T>(context);
      return builder(context);
    },
  );
  await route?.completed;
  return result;
}

Future<ListeningVoiceSettings?> showListeningVoicePanel(
  BuildContext context,
  ListeningVoiceSettings settings,
  VoicePreview preview,
) => _voiceSheet(
  context,
  (context) => _VoiceSheetBody(
    title: '音色',
    children: [
      for (final (label, ios, android, source) in const [
        (
          '在线音色',
          CupertinoIcons.cloud,
          Icons.cloud_outlined,
          ListeningVoiceSource.online,
        ),
        (
          '自定义',
          CupertinoIcons.slider_horizontal_3,
          Icons.tune,
          ListeningVoiceSource.custom,
        ),
        (
          '系统音色',
          CupertinoIcons.speaker_2,
          Icons.record_voice_over_outlined,
          ListeningVoiceSource.system,
        ),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppleGlassCard(
            child: ListTile(
              leading: Icon(usesAppleGlass ? ios : android),
              title: Text(label),
              subtitle:
                  settings.voice.source == source
                      ? Text(settings.voice.name)
                      : null,
              trailing: Icon(
                usesAppleGlass
                    ? CupertinoIcons.chevron_right
                    : Icons.chevron_right,
              ),
              onTap: () async {
                final choice = await _voiceSheet<ListeningVoiceSettings>(
                  context,
                  (_) =>
                      source == ListeningVoiceSource.custom
                          ? _EndpointForm(settings: settings, preview: preview)
                          : _VoiceChoices(
                            source: source,
                            settings: settings,
                            preview: preview,
                          ),
                );
                if (choice != null && context.mounted) {
                  Navigator.of(context).pop(choice);
                }
              },
            ),
          ),
        ),
    ],
  ),
);

class _VoiceSheetBody extends StatelessWidget {
  const _VoiceSheetBody({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              AppIconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(usesAppleGlass ? CupertinoIcons.xmark : Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );
}

class _VoiceChoices extends StatefulWidget {
  const _VoiceChoices({
    required this.source,
    required this.settings,
    required this.preview,
  });
  final ListeningVoiceSource source;
  final ListeningVoiceSettings settings;
  final VoicePreview preview;

  @override
  State<_VoiceChoices> createState() => _VoiceChoicesState();
}

class _VoiceChoicesState extends State<_VoiceChoices> {
  bool get _online => widget.source == ListeningVoiceSource.online;
  late List<ListeningVoice> _voices =
      _online
          ? [
            ListeningVoice.female,
            ListeningVoice.male,
            if (widget.settings.voice.source == ListeningVoiceSource.online &&
                !widget.settings.voice.matches(ListeningVoice.female) &&
                !widget.settings.voice.matches(ListeningVoice.male))
              widget.settings.voice,
          ]
          : [ListeningVoice.system];
  bool _loading = false, _previewing = false, _expanded = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    if (!_online) _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final voices =
          _online
              ? [
                ListeningVoice.female,
                ListeningVoice.male,
                ...await ListeningVoiceSettings.onlineVoices(),
              ]
              : await _systemVoices();
      if (!mounted) return;
      setState(() {
        _voices = voices;
        _expanded = true;
        _message = null;
      });
    } catch (_) {
      if (mounted) setState(() => _message = '音色列表暂时无法加载，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<ListeningVoice>> _systemVoices() async {
    final info = await PlatformReaderSpeech.instance.initialize();
    final installed =
        info.voices
            .where(
              (voice) =>
                  ListeningVoiceSettings.isChinese(voice.language) &&
                  !voice.network,
            )
            .toList()
          ..sort((a, b) => b.quality.compareTo(a.quality));
    return [
      ListeningVoice.system,
      for (var i = 0; i < installed.length; i++)
        ListeningVoice(
          ListeningVoiceSource.system,
          installed[i].name == installed[i].id
              ? '中文音色 ${i + 1}'
              : installed[i].name,
          id: installed[i].id,
          language: installed[i].language,
        ),
    ];
  }

  ListeningVoiceSettings _settings(ListeningVoice voice) =>
      ListeningVoiceSettings(voice, endpoint: widget.settings.endpoint);

  Future<void> _preview(ListeningVoice voice) async {
    setState(() {
      _previewing = true;
      _message = null;
    });
    try {
      await widget.preview(_settings(voice));
    } catch (error) {
      if (mounted) setState(() => _message = _voiceError(error));
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) => _VoiceSheetBody(
    title: _online ? '在线音色' : '系统音色',
    children: [
      if (_online)
        const Padding(
          padding: EdgeInsets.only(left: 12, bottom: 10),
          child: Text('在线合成需要发送当前语段。'),
        ),
      for (final voice in _voices)
        ListTile(
          key: ValueKey((voice.source, voice.id)),
          title: Text(voice.name),
          subtitle: Text(voice.language),
          leading:
              widget.settings.voice.matches(voice)
                  ? Icon(
                    usesAppleGlass ? CupertinoIcons.check_mark : Icons.check,
                  )
                  : null,
          trailing: AppIconButton(
            tooltip: '试听',
            onPressed: _previewing ? null : () => _preview(voice),
            icon: Icon(
              usesAppleGlass ? CupertinoIcons.play : Icons.play_arrow_outlined,
            ),
          ),
          onTap: () => Navigator.of(context).pop(_settings(voice)),
        ),
      if (_loading) const LinearProgressIndicator(),
      if (!_expanded && !_loading)
        AppButton.text(
          onPressed: _load,
          child: Text(_online ? '获取更多在线音色' : '重新检测'),
        ),
      if (_message case final message?) Text(message),
    ],
  );
}

String _voiceError(Object error) =>
    error is PlatformException ? error.message ?? '试听失败，请重试' : '试听失败，请检查语音服务';

class _EndpointForm extends StatefulWidget {
  const _EndpointForm({required this.settings, required this.preview});
  final ListeningVoiceSettings settings;
  final VoicePreview preview;

  @override
  State<_EndpointForm> createState() => _EndpointFormState();
}

class _EndpointFormState extends State<_EndpointForm> {
  final _form = GlobalKey<FormState>();
  late final _url = TextEditingController(
    text: widget.settings.endpoint?.url.toString(),
  );
  late final _id = TextEditingController(
    text: widget.settings.endpoint?.id ?? ListeningVoice.female.id,
  );
  late final _name = TextEditingController(
    text: widget.settings.endpoint?.name ?? '自定义音色',
  );
  late final _language = TextEditingController(
    text: widget.settings.endpoint?.language ?? 'zh-CN',
  );
  late final _credential = TextEditingController(
    text: widget.settings.endpoint?.credential,
  );
  late ListeningVoiceAuth _auth =
      widget.settings.endpoint?.auth ?? ListeningVoiceAuth.none;
  String? _error;
  bool _previewing = false;

  Future<void> _apply({required bool preview}) async {
    if (_form.currentState?.validate() != true) return;
    final endpoint = ListeningVoiceEndpoint(
      url: ListeningVoiceEndpoint.parseUrl(_url.text)!,
      name: _name.text.trim(),
      id: _id.text.trim(),
      language: _language.text.trim(),
      auth: _auth,
      credential:
          _auth == ListeningVoiceAuth.none ? '' : _credential.text.trim(),
    );
    final settings = ListeningVoiceSettings(endpoint.voice, endpoint: endpoint);
    if (!preview) {
      Navigator.of(context).pop(settings);
      return;
    }
    setState(() {
      _previewing = true;
      _error = null;
    });
    try {
      await widget.preview(settings);
    } catch (error) {
      if (mounted) setState(() => _error = _voiceError(error));
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [_url, _id, _name, _language, _credential]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(
    TextEditingController controller,
    String name, {
    String? Function(String?)? validator,
    bool secret = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: AppTextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: name),
      keyboardType: keyboard,
      obscureText: secret,
      validator:
          validator ??
          (value) => value?.trim().isNotEmpty == true ? null : '请填写$name',
    ),
  );

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: _VoiceSheetBody(
      title: '自定义音色',
      children: [
        _field(
          _url,
          'HTTPS 合成地址',
          keyboard: TextInputType.url,
          validator:
              (value) =>
                  ListeningVoiceEndpoint.parseUrl(value ?? '') == null
                      ? '请输入有效的 HTTPS 地址'
                      : null,
        ),
        _field(_id, '音色 ID'),
        _field(_name, '显示名称'),
        _field(_language, '语言'),
        AppDropdownButtonFormField<ListeningVoiceAuth>(
          value: _auth,
          decoration: const InputDecoration(labelText: '认证方式'),
          items: const [
            DropdownMenuItem(
              value: ListeningVoiceAuth.none,
              child: Text('无认证'),
            ),
            DropdownMenuItem(
              value: ListeningVoiceAuth.azure,
              child: Text('Azure Key'),
            ),
            DropdownMenuItem(
              value: ListeningVoiceAuth.bearer,
              child: Text('Bearer'),
            ),
          ],
          onChanged: (auth) {
            if (auth != null) setState(() => _auth = auth);
          },
        ),
        if (_auth != ListeningVoiceAuth.none)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _field(
              _credential,
              _auth == ListeningVoiceAuth.azure ? 'Azure Key' : 'Bearer',
              secret: true,
            ),
          ),
        const SizedBox(height: 12),
        AppButton.filled(
          onPressed: _previewing ? null : () => _apply(preview: false),
          child: const Text('保存并使用'),
        ),
        AppButton.text(
          onPressed: _previewing ? null : () => _apply(preview: true),
          child: Text(_previewing ? '正在准备试听…' : '试听接口'),
        ),
        if (_error case final error?) Text(error),
      ],
    ),
  );
}
