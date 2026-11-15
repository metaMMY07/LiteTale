import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/services/reader_listening_chapter.dart';
import 'package:wild/services/reader_mark_text.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_chapter_sheet.dart';
import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/widgets/reader_draggable_sheet.dart';
import 'package:wild/widgets/reader_listening_voice_panel.dart';
import 'package:wild/widgets/reader_speech_scope.dart';

import 'font_size_cubit.dart';
import 'line_height_cubit.dart';
import 'paragraph_spacing_cubit.dart';
import 'reader_route.dart';
import 'theme_cubit.dart';

class ReaderListeningPage extends StatefulWidget {
  const ReaderListeningPage({
    super.key,
    required this.request,
    this.progress,
    this.onPosition,
  });
  final ReaderListeningRequest request;
  final ReadingProgressQueue? progress;
  final ValueChanged<ReadingProgress>? onPosition;

  @override
  State<ReaderListeningPage> createState() => _ReaderListeningPageState();
}

class _ReaderListeningPageState extends State<ReaderListeningPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late ReaderListeningChapter _chapter = widget.request.chapter;
  late final _chapters =
      widget.request.volumes.expand((volume) => volume.chapters).toList();
  late final _session = bookNavigationScope(widget.request.chapter.aid);
  late final _progress = widget.progress ?? ReadingProgressQueue.instance;
  ReadingProgress? _lastProgress;
  late final _menu = AnimationController(
    vsync: this,
    duration: readerPanelSlideDuration,
  );
  late final _slide = Tween(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).chain(CurveTween(curve: readerPanelSlideCurve)).animate(_menu);
  late final _speech = ReaderSpeechController();
  final _selectedParagraph = ValueNotifier(-1);
  final _list = ItemScrollController();
  OnlineReaderSpeech? _online, _previewOnline;
  ReaderSpeechEngine? _previewEngine;
  String? _previewId;
  int _previewSequence = 0;
  ListeningVoiceSettings _voices = const ListeningVoiceSettings(
    ListeningVoice.female,
  );
  ReadRequest? _chapterRequest;
  Chapter? _retryChapter;
  Timer? _timer;
  int _sleepChoice = 0, _followRevision = 0, _resumeRevision = 0;
  int _voiceRevision = 0;
  bool _showMenu = false,
      _closing = false,
      _loading = false,
      _voicePanel = false;
  bool _foreground = true, _autoplayAfterChapter = true;
  bool _finished = false;
  String? _chapterError;

  bool get _valid =>
      mounted &&
      !_closing &&
      _session == bookNavigationScope(widget.request.chapter.aid);

  @override
  void initState() {
    super.initState();
    _session;
    _foreground = switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed => true,
      _ => false,
    };
    _setVoice(_voices);
    _speech.loadPlan(
      ReaderSpeechPlan(_chapter.text, 240),
      widget.request.offset,
    );
    _selectedParagraph.value = _speech.ready ? _speech.paragraphIndex : -1;
    _speech.addListener(_speechChanged);
    WidgetsBinding.instance.addObserver(this);
    activeSource.addListener(_sourceChanged);
    sourceRevision.addListener(_sourceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _enter());
  }

  Future<void> _enter() async {
    if (!mounted) return;
    unawaited(_restoreVoice());
    if (!await waitForListeningArrival(context) || !mounted || _closing) return;
    setState(() => _showMenu = true);
    if (MediaQuery.disableAnimationsOf(context)) {
      _menu.value = 1;
    } else {
      unawaited(_menu.forward());
    }
  }

  Future<void> _restoreVoice() async {
    final revision = _voiceRevision;
    final saved = await ListeningVoiceSettings.load();
    if (!_valid ||
        _voicePanel ||
        _speech.playing ||
        _speech.hasSpoken ||
        revision != _voiceRevision) {
      return;
    }
    setState(() => _setVoice(saved));
  }

  void _setVoice(ListeningVoiceSettings settings) {
    final previous = _online;
    _voices = settings;
    final voice = settings.voice;
    if (voice.source == ListeningVoiceSource.system) {
      _online = null;
      _speech.selectEngine(PlatformReaderSpeech.instance, voice.id);
    } else {
      _online = OnlineReaderSpeech(
        endpoint:
            voice.source == ListeningVoiceSource.custom
                ? settings.endpoint
                : null,
      );
      _speech.selectEngine(_online!, voice.id);
    }
    if (previous != null) {
      unawaited(previous.dispose().catchError((Object _) {}));
    }
  }

  void _sourceChanged() {
    _resumeRevision++;
    _chapterRequest?.cancel();
    _speech.suspend();
    unawaited(_stopPreview());
    if (mounted && !_closing) {
      setState(() {
        _loading = false;
        _retryChapter = null;
        _chapterError = '书源已变化，请返回详情后重新打开';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _resumeRevision++;
      _autoplayAfterChapter = false;
      _speech.suspend();
      unawaited(_stopPreview());
    }
  }

  void _rememberPosition() {
    if (_speech.hasSpoken) {
      _lastProgress = widget.request.progress(_chapter, _speech.spokenOffset);
    }
  }

  void _leave({bool returning = false}) {
    if (_closing) return;
    _rememberPosition();
    _closing = true;
    _timer?.cancel();
    _chapterRequest?.cancel();
    _speech.suspend();
    unawaited(_stopPreview());
    final progress = _lastProgress;
    if (progress == null) return;
    final session = _session;
    final aid = widget.request.chapter.aid;
    _progress.enqueue(
      progress,
      isValid: () => bookNavigationScope(aid) == session,
    );
    if (returning && bookNavigationScope(aid) == session) {
      widget.onPosition?.call(progress);
    }
    unawaited(_progress.flushBounded());
  }

  @override
  void dispose() {
    _speech.removeListener(_speechChanged);
    _leave();
    activeSource.removeListener(_sourceChanged);
    sourceRevision.removeListener(_sourceChanged);
    WidgetsBinding.instance.removeObserver(this);
    _speech.dispose();
    unawaited(_online?.dispose().catchError((Object _) {}));
    _selectedParagraph.dispose();
    _menu.dispose();
    super.dispose();
  }

  void _speechChanged() {
    if (!_valid || !_speech.ready) return;
    final index = _speech.paragraphIndex;
    if (_selectedParagraph.value != index) {
      _selectedParagraph.value = index;
      _follow(index);
    }
    if (_speech.finished && !_finished) {
      _follow(_speech.segmentCount);
      if (_sleepChoice == -1) setState(() => _sleepChoice = 0);
    }
    _finished = _speech.finished;
  }

  void _follow(int index) {
    final revision = ++_followRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_valid || !_list.isAttached || revision != _followRevision) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _list.jumpTo(index: index, alignment: .15);
      } else {
        unawaited(
          _list.scrollTo(
            index: index,
            alignment: .15,
            duration: readerMenuMotionDuration,
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  Chapter? _neighbor(int delta) {
    final current = _chapters.indexWhere(
      (item) => item.aid == _chapter.aid && item.cid == _chapter.cid,
    );
    final next = current + delta;
    return current >= 0 && next >= 0 && next < _chapters.length
        ? _chapters[next]
        : null;
  }

  Future<void> _openChapter(Chapter item) async {
    if (!_valid) return;
    _rememberPosition();
    _speech.suspend();
    _chapterRequest?.cancel();
    final request = _chapterRequest = ReadRequest();
    final targetSession = readerSessionGeneration(item.aid);
    bool current() =>
        _valid &&
        identical(_chapterRequest, request) &&
        targetSession == readerSessionGeneration(item.aid);
    _autoplayAfterChapter = _foreground;
    setState(() {
      _loading = true;
      _chapterError = null;
      _retryChapter = null;
    });
    try {
      final data = await ReadRequest.run(
        request,
        () => request.wait(
          readerChapter(aid: item.aid, cid: item.cid, isCurrent: current),
        ),
      );
      if (!current()) return;
      final next = ReaderListeningChapter(
        aid: item.aid,
        cid: item.cid,
        title: item.title,
        text: readerMarkText(data.content, data.document),
        encoded: data.fontFamily != null,
      );
      final plan = ReaderSpeechPlan(next.encoded ? '' : next.text, 240);
      _followRevision++;
      setState(() {
        _chapter = next;
        _loading = false;
        _finished = false;
      });
      _selectedParagraph.value = plan.paragraphs.isEmpty ? -1 : 0;
      _speech.loadPlan(plan, 0);
      if (_autoplayAfterChapter) await _speech.play();
    } catch (error) {
      if (current() && error is! ReadCancelled) {
        setState(() {
          _chapterError = '章节加载失败，请重试';
          _retryChapter = item;
          _loading = false;
        });
      }
    }
  }

  void _selectParagraph(int index, {required bool play}) {
    if (!_valid || !_showMenu || !_foreground || _loading || !_speech.ready) {
      return;
    }
    _speech.seekParagraph(index, autoplay: play);
    _follow(index);
  }

  Future<void> _togglePlayback() async {
    if (!_valid || !_foreground || _loading) return;
    if (_speech.playing) {
      await _speech.pause();
      return;
    }
    _follow(_speech.paragraphIndex);
    await _speech.play();
  }

  Future<void> _directory() async {
    final item = await showReaderChapterSheet(
      context,
      volumes: widget.request.volumes,
      currentAid: _chapter.aid,
      currentCid: _chapter.cid,
    );
    if (item != null &&
        _valid &&
        (item.cid != _chapter.cid || item.aid != _chapter.aid)) {
      await _openChapter(item);
    }
  }

  Future<void> _rate() async {
    const rates = [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final rate = await _choose('播放倍速', {
      for (final value in rates) value: '${_rateLabel(value)}×',
    });
    if (rate is double && _valid) _speech.setRate(rate);
  }

  static String _rateLabel(double value) =>
      value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();

  Future<T?> _choose<T>(String title, Map<T, String> options) =>
      showAppBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        builder:
            (context) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                for (final entry in options.entries)
                  ListTile(
                    title: Text(entry.value),
                    onTap: () => Navigator.of(context).pop(entry.key),
                  ),
              ],
            ),
      );

  Future<void> _sleep() async {
    final value = await _choose('定时停止', {
      0: '关闭',
      for (final minutes in [5, 10, 15, 30, 45, 60]) minutes: '$minutes 分钟',
      -1: '本章结束',
    });
    if (value == null || !_valid) return;
    _timer?.cancel();
    setState(() => _sleepChoice = value);
    if (value > 0) {
      _timer = Timer(Duration(minutes: value), () {
        if (!_valid) return;
        _resumeRevision++;
        _autoplayAfterChapter = false;
        _speech.suspend();
        unawaited(_stopPreview());
        setState(() => _sleepChoice = 0);
      });
    }
  }

  Future<void> _openVoices() async {
    if (_voicePanel || !_valid) return;
    _voicePanel = true;
    final playing = _speech.playing;
    final resumeRevision = _resumeRevision;
    try {
      final choice = await showListeningVoicePanel(context, _voices, _preview);
      await _stopPreview();
      if (!_valid) return;
      if (choice != null) {
        _voiceRevision++;
        setState(() => _setVoice(choice));
        unawaited(
          choice.save().catchError((Object _) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('音色设置暂未保存')));
            }
          }),
        );
      }
      if (playing &&
          _foreground &&
          !_speech.playing &&
          resumeRevision == _resumeRevision) {
        await _speech.play();
      }
    } finally {
      _voicePanel = false;
    }
  }

  Future<void> _preview(ListeningVoiceSettings settings) async {
    _speech.suspend();
    await _stopPreview();
    if (!_valid || !_voicePanel || !_foreground) return;
    final voice = settings.voice;
    final engine =
        voice.source == ListeningVoiceSource.system
            ? PlatformReaderSpeech.instance
            : _previewOnline = OnlineReaderSpeech(
              endpoint:
                  voice.source == ListeningVoiceSource.custom
                      ? settings.endpoint
                      : null,
            );
    final id = 'preview-${++_previewSequence}';
    _previewId = id;
    _previewEngine = engine;
    await engine.initialize();
    if (_previewId != id || !_valid) return;
    await engine.speak(id, '你好，欢迎使用 LiteTale 听书。', 1, voice.id);
  }

  Future<void> _stopPreview() async {
    final id = _previewId;
    final engine = _previewEngine;
    final online = _previewOnline;
    _previewId = null;
    _previewEngine = null;
    _previewOnline = null;
    try {
      if (id != null) await engine?.stop(id);
    } catch (_) {
      // A failed preview can already have released its audio session.
    } finally {
      await online?.dispose().catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = context.watch<ThemeCubit>().state;
    final dark = switch (paper.themeMode) {
      ReaderThemeMode.dark => true,
      ReaderThemeMode.light => false,
      ReaderThemeMode.auto =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    final color = dark ? paper.darkTextColor : paper.lightTextColor;
    final background =
        dark ? paper.darkBackgroundColor : paper.lightBackgroundColor;
    final textStyle = TextStyle(
      color: color,
      fontFamily: context.watch<FontSettingsCubit>().state.readerFamily,
      fontSize: context.watch<FontSizeCubit>().state,
      height: context.watch<LineHeightCubit>().state,
    );
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _leave(returning: true);
      },
      child: Scaffold(
        backgroundColor: background,
        body: Stack(
          children: [
            Positioned.fill(child: _body(textStyle)),
            if (_showMenu)
              Positioned(
                left: 16,
                top: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ReaderRoundAction(
                      label: '退出听书',
                      onPressed: () => Navigator.of(context).pop(),
                      icon:
                          usesAppleGlass
                              ? CupertinoIcons.chevron_back
                              : Icons.arrow_back,
                    ),
                  ),
                ),
              ),
            if (_showMenu)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SlideTransition(position: _slide, child: _controls()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(TextStyle style) {
    final paragraphs = _speech.paragraphs;
    final spacing = context.watch<ParagraphSpacingCubit>().state;
    final insets = MediaQuery.paddingOf(context);
    return ScrollablePositionedList.builder(
      key: ValueKey((_chapter.aid, _chapter.cid)),
      itemScrollController: _list,
      initialScrollIndex: _speech.paragraphIndex,
      initialAlignment: .12,
      padding: EdgeInsets.fromLTRB(
        18,
        insets.top + 64,
        18,
        insets.bottom + 200,
      ),
      itemCount: paragraphs.length + 1,
      itemBuilder: (context, index) {
        if (index == paragraphs.length) return _chapterLinks();
        return ValueListenableBuilder(
          valueListenable: _selectedParagraph,
          builder:
              (context, selected, _) => Padding(
                padding: EdgeInsets.only(bottom: spacing),
                child: Semantics(
                  button: true,
                  selected: selected == index,
                  child: Material(
                    color:
                        selected == index
                            ? style.color!.withValues(alpha: .09)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap:
                          _loading || !_showMenu || !_valid
                              ? null
                              : () => _selectParagraph(index, play: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Text(paragraphs[index].text, style: style),
                      ),
                    ),
                  ),
                ),
              ),
        );
      },
    );
  }

  Widget _chapterLinks() {
    final previous = _neighbor(-1), next = _neighbor(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_speech.ready)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_chapter.encoded ? '当前章节的专用字形暂不可朗读' : '本章没有可朗读的文字'),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            AppButton.text(
              onPressed:
                  !_valid || !_showMenu || _loading || previous == null
                      ? null
                      : () => _openChapter(previous),
              child: const Text('上一章'),
            ),
            AppButton.text(
              onPressed:
                  !_valid || !_showMenu || _loading || next == null
                      ? null
                      : () => _openChapter(next),
              child: const Text('下一章'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _controls() {
    final content = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListenableBuilder(
          listenable: _speech,
          builder: (context, _) {
            final available =
                _valid && _foreground && _speech.ready && !_loading;
            final index = _speech.paragraphIndex;
            final retryChapter = _retryChapter;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_speech.ready)
                  ReaderPageScrubber(
                    embedded: true,
                    unit: '段',
                    label: '第',
                    index: index,
                    count: _speech.segmentCount,
                    revision: (_chapter.aid, _chapter.cid),
                    active: available,
                    onSeek:
                        (next) => _selectParagraph(next, play: _speech.playing),
                  ),
                if (_loading)
                  const LinearProgressIndicator()
                else if ((_chapterError ?? _speech.message) case final message?)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      AppButton.text(
                        onPressed:
                            retryChapter != null
                                ? () => _openChapter(retryChapter)
                                : available
                                ? _speech.play
                                : null,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Flexible(
                      child: AppButton.text(
                        onPressed: _rate,
                        child: Text('${_rateLabel(_speech.rate)}×'),
                      ),
                    ),
                    _icon(
                      '上一段',
                      CupertinoIcons.backward_end_fill,
                      Icons.skip_previous,
                      available && index > 0
                          ? () =>
                              _selectParagraph(index - 1, play: _speech.playing)
                          : null,
                    ),
                    _icon(
                      _speech.playing ? '暂停' : '播放',
                      _speech.playing
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      _speech.playing ? Icons.pause : Icons.play_arrow,
                      available ? _togglePlayback : null,
                      size: 32,
                    ),
                    _icon(
                      '下一段',
                      CupertinoIcons.forward_end_fill,
                      Icons.skip_next,
                      available && index + 1 < _speech.segmentCount
                          ? () =>
                              _selectParagraph(index + 1, play: _speech.playing)
                          : null,
                    ),
                    _icon(
                      _sleepChoice == 0 ? '定时停止' : '定时已设置',
                      _sleepChoice == 0
                          ? CupertinoIcons.moon
                          : CupertinoIcons.moon_fill,
                      _sleepChoice == 0
                          ? Icons.bedtime_outlined
                          : Icons.bedtime,
                      _sleep,
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _icon(
                      '章节目录',
                      CupertinoIcons.list_bullet,
                      Icons.list,
                      _valid ? _directory : null,
                    ),
                    Semantics(
                      label: '听书模式',
                      child: Icon(
                        usesAppleGlass
                            ? CupertinoIcons.headphones
                            : Icons.headphones,
                        size: 24,
                      ),
                    ),
                    _icon(
                      '音色',
                      CupertinoIcons.waveform,
                      Icons.graphic_eq,
                      _openVoices,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
    return usesAppleGlass
        ? AppleGlassSurface(child: content)
        : Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: content,
        );
  }

  Widget _icon(
    String label,
    IconData ios,
    IconData android,
    VoidCallback? onPressed, {
    double size = 24,
  }) => AppIconButton(
    tooltip: label,
    onPressed: onPressed,
    icon: Icon(usesAppleGlass ? ios : android, size: size),
  );
}
