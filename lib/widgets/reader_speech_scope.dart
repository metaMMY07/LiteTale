import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/platform_controls.dart';

class ReaderSpeechScope extends StatefulWidget {
  const ReaderSpeechScope({
    super.key,
    required this.chapter,
    required this.readText,
    required this.child,
  });

  final ({String aid, String cid})? chapter;
  final ({String text, bool encoded})? Function() readText;
  final Widget child;

  static VoidCallback? openOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ReaderSpeechAction>()?.open;

  @override
  State<ReaderSpeechScope> createState() => _ReaderSpeechScopeState();
}

class _ReaderSpeechScopeState extends State<ReaderSpeechScope>
    with WidgetsBindingObserver {
  final _speech = ReaderSpeechController();
  Animation<double>? _routeAnimation;
  ModalRoute<void>? _panelRoute;
  bool _panelOpen = false;
  bool _panelOutdated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    activeSource.addListener(_reset);
    sourceRevision.addListener(_reset);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation == animation) return;
    _routeAnimation?.removeStatusListener(_routeStatus);
    _routeAnimation = animation;
    animation?.addStatusListener(_routeStatus);
  }

  @override
  void didUpdateWidget(covariant ReaderSpeechScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapter != widget.chapter) _reset();
  }

  void _routeStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _reset();
  }

  void _reset() {
    _speech.reset(notify: false);
    _dismissPanel();
  }

  void _dismissPanel() {
    _panelOutdated = true;
    final route = _panelRoute;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _speech.suspend();
  }

  Future<void> _showControls() async {
    if (_panelOpen || widget.chapter == null) return;
    void prepare() {
      if (mounted && !_panelOutdated) {
        unawaited(_speech.prepare(widget.readText()));
      }
    }

    _panelOpen = true;
    _panelOutdated = false;
    prepare();
    try {
      await showAppBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) {
          _panelRoute = ModalRoute.of<void>(sheetContext);
          if (_panelOutdated || !mounted) {
            _dismissPanel();
            return const SizedBox.shrink();
          }
          return _ReaderSpeechPanel(speech: _speech, onRetry: prepare);
        },
      );
      await _panelRoute?.completed;
    } finally {
      _panelRoute = null;
      _panelOpen = false;
    }
  }

  @override
  void dispose() {
    activeSource.removeListener(_reset);
    sourceRevision.removeListener(_reset);
    _routeAnimation?.removeStatusListener(_routeStatus);
    WidgetsBinding.instance.removeObserver(this);
    _dismissPanel();
    _speech.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReaderSpeechAction(
    open:
        PlatformReaderSpeech.supported && widget.chapter != null
            ? _showControls
            : null,
    child: widget.child,
  );
}

class _ReaderSpeechAction extends InheritedWidget {
  const _ReaderSpeechAction({required this.open, required super.child});
  final VoidCallback? open;

  @override
  bool updateShouldNotify(_ReaderSpeechAction oldWidget) =>
      open != oldWidget.open;
}

class _ReaderSpeechPanel extends StatelessWidget {
  const _ReaderSpeechPanel({required this.speech, required this.onRetry});

  final ReaderSpeechController speech;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: speech,
    builder:
        (context, _) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '朗读',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    AppIconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (speech.loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: AppLoadingIndicator(size: 24)),
                  ),
                if (speech.message case final message?)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(message),
                  ),
                if (speech.canRetryInitialization)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppButton.text(
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                  ),
                if (speech.ready) ...[
                  const SizedBox(height: 12),
                  Text(
                    speech.finished
                        ? '本章朗读完成'
                        : '第 ${speech.currentSegment} 段 / ${speech.segmentCount} 段',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      AppButton.filled(
                        onPressed: speech.playing ? speech.pause : speech.play,
                        child: Text(
                          speech.playing
                              ? '暂停'
                              : speech.paused
                              ? '继续'
                              : '开始朗读',
                        ),
                      ),
                      AppButton.text(
                        onPressed: speech.stop,
                        child: const Text('停止'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('语速 ${speech.rate.toStringAsFixed(1)}×'),
                  AppSlider(
                    min: .5,
                    max: 2,
                    divisions: 15,
                    value: speech.rate,
                    onChanged: speech.playing ? null : speech.setRate,
                  ),
                  AppDropdownButtonFormField<String>(
                    value: speech.voice ?? '',
                    decoration: const InputDecoration(labelText: '音色'),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('系统中文音色')),
                      for (final voice in speech.voices)
                        DropdownMenuItem(
                          value: voice.id,
                          child: Text(
                            '${voice.name} · ${voice.language}${voice.network ? ' · 联网' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged:
                        speech.playing
                            ? null
                            : (value) =>
                                speech.setVoice(value == '' ? null : value),
                  ),
                ],
              ],
            ),
          ),
        ),
  );
}
