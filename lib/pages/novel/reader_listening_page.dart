import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/services/reader_listening_chapter.dart';
import 'package:wild/services/reader_mark_text.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/apple_reader_panel.dart';
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
    this.speechEngine,
  });
  final ReaderListeningRequest request;
  final ReadingProgressQueue? progress;
  final ValueChanged<ReadingProgress>? onPosition;
  final ReaderSpeechEngine? speechEngine;

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
  late final _menuReveal = _menu.drive(
    CurveTween(curve: readerPanelSlideCurve),
  );
  late final _online =
      widget.speechEngine == null ? OnlineReaderSpeech() : null;
  late final _speech = ReaderSpeechController(
    engine: widget.speechEngine ?? _online!,
  );
  final _selectedParagraph = ValueNotifier(-1);
  final _list = ItemScrollController();
  OnlineReaderSpeech? _previewOnline;
  ListeningVoice _voice = ListeningVoice.female;
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
    _speech.selectVoice(_voice.id);
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
    final saved = await ListeningVoice.load();
    if (!_valid ||
        _voicePanel ||
        _speech.playing ||
        _speech.hasSpoken ||
        revision != _voiceRevision) {
      return;
    }
    setState(() => _setVoice(saved));
  }

  void _setVoice(ListeningVoice voice) {
    _voice = voice;
    _speech.selectVoice(voice.id);
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

  Future<void> _directory(BuildContext context) async {
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

  Future<void> _rate(BuildContext context) async {
    const rates = [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final rate = await _choose(
      context,
      '播放倍速',
      {for (final value in rates) value: '${_rateLabel(value)}×'},
      _speech.rate,
      CupertinoIcons.speedometer,
    );
    if (rate is double && _valid) _speech.setRate(rate);
  }

  static String _rateLabel(double value) =>
      value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();

  Future<T?> _choose<T>(
    BuildContext context,
    String title,
    Map<T, String> options,
    T selected,
    IconData icon,
  ) async {
    if (usesAppleGlass && await AppleReaderPanel.available) {
      if (!context.mounted ||
          !_valid ||
          ModalRoute.of(context)?.isCurrent == false) {
        return null;
      }
      final colors = Theme.of(context).colorScheme;
      final choices = options.entries.toList(growable: false);
      final selection = await AppleReaderPanel.show(
        context,
        configuration:
            () => {
              'title': title,
              'dark': colors.brightness == Brightness.dark,
              'accent': colors.onSurface.toARGB32(),
              'sections': [
                {
                  'rows': [
                    for (var i = 0; i < choices.length; i++)
                      {
                        'id': '$i',
                        // Match the directory's native selection row and dismissal.
                        'kind': 'chapter',
                        'title': choices[i].value,
                        'value': choices[i].key == selected,
                      },
                  ],
                },
              ],
            },
      );
      final id = selection?['id'];
      final index = id is String ? int.tryParse(id) : null;
      return index != null && index >= 0 && index < choices.length
          ? choices[index].key
          : null;
    }
    if (!context.mounted || !_valid) return null;
    return showAppBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useGlass: false,
      builder:
          (context) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              if (usesAppleGlass)
                IosSettingsSection(
                  title: title,
                  rows: [
                    for (final entry in options.entries)
                      IosSettingsRow(
                        icon: icon,
                        title: entry.value,
                        trailing:
                            entry.key == selected
                                ? Icon(
                                  CupertinoIcons.check_mark,
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 17,
                                )
                                : null,
                        onTap: () => Navigator.of(context).pop(entry.key),
                      ),
                  ],
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                SettingsTileGroup(
                  children: [
                    for (final entry in options.entries)
                      ListTile(
                        title: Text(entry.value),
                        selected: entry.key == selected,
                        trailing:
                            entry.key == selected
                                ? const Icon(Icons.check)
                                : null,
                        onTap: () => Navigator.of(context).pop(entry.key),
                      ),
                  ],
                ),
              ],
            ],
          ),
    );
  }

  Future<void> _sleep(BuildContext context) async {
    final value = await _choose(
      context,
      '定时停止',
      {
        0: '关闭',
        for (final minutes in [5, 10, 15, 30, 45, 60]) minutes: '$minutes 分钟',
        -1: '本章结束',
      },
      _sleepChoice,
      CupertinoIcons.moon,
    );
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

  Future<void> _openVoices(BuildContext context) async {
    if (_voicePanel || !_valid) return;
    _voicePanel = true;
    var resumeAfterPreview = false;
    final resumeRevision = _resumeRevision;
    try {
      final choice = await showListeningVoicePanel(context, _voice, (voice) {
        resumeAfterPreview |= _speech.playing;
        return _preview(voice);
      });
      await _stopPreview();
      if (!_valid) return;
      if (choice != null) {
        _voiceRevision++;
        setState(() => _setVoice(choice));
        unawaited(
          choice.save().catchError((Object _) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('音色设置暂未保存')));
            }
          }),
        );
      }
      if (resumeAfterPreview &&
          _foreground &&
          !_speech.playing &&
          resumeRevision == _resumeRevision) {
        await _speech.play();
      }
    } finally {
      _voicePanel = false;
    }
  }

  Future<void> _preview(ListeningVoice voice) async {
    _speech.suspend();
    await _stopPreview();
    if (!_valid || !_voicePanel || !_foreground) return;
    final engine = _previewOnline = OnlineReaderSpeech();
    await engine.speak('preview', '你好，欢迎使用 LiteTale 听书。', 1, voice.id);
  }

  Future<void> _stopPreview() async {
    final online = _previewOnline;
    _previewOnline = null;
    await online?.dispose().catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) return _buildPage(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Theme(
      data: theme.copyWith(
        colorScheme: colors.copyWith(
          primary: colors.onSurface,
          secondary: colors.onSurface,
          onPrimary: colors.surface,
          onSecondary: colors.surface,
          onPrimaryContainer: colors.onSurface,
        ),
        cupertinoOverrideTheme: (theme.cupertinoOverrideTheme ??
                const CupertinoThemeData())
            .copyWith(primaryColor: colors.onSurface),
        progressIndicatorTheme: theme.progressIndicatorTheme.copyWith(
          color: colors.onSurface,
        ),
      ),
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
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
        body: LayoutBuilder(
          builder: (context, bounds) {
            final height = bounds.maxHeight;
            final menuHeight = (height * .30).clamp(180.0, 320.0);
            return Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _body(context, textStyle)),
                    if (_showMenu)
                      SizeTransition(
                        sizeFactor: _menuReveal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: height * .7),
                          child: _controls(context, menuHeight),
                        ),
                      ),
                  ],
                ),
                if (_showMenu)
                  Positioned(
                    left: 16,
                    top: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _exitButton(context),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _exitButton(BuildContext context) {
    void exit() => Navigator.of(context).pop();
    return usesAppleGlass
        ? SettingsCard(
          color: Theme.of(context).colorScheme.surface,
          margin: EdgeInsets.zero,
          child: AppIconButton(
            tooltip: '退出听书',
            onPressed: exit,
            icon: const Icon(CupertinoIcons.chevron_back),
          ),
        )
        : ReaderRoundAction(
          label: '退出听书',
          onPressed: exit,
          icon: Icons.arrow_back,
        );
  }

  Widget _body(BuildContext context, TextStyle style) {
    final paragraphs = _speech.paragraphs;
    final spacing = context.watch<ParagraphSpacingCubit>().state;
    final insets = MediaQuery.paddingOf(context);
    final colors = Theme.of(context).colorScheme;
    final highlight =
        usesMaterialYou
            ? colors.primaryContainer
            : style.color!.withValues(alpha: .09);
    final playingStyle =
        usesMaterialYou
            ? style.copyWith(color: colors.onPrimaryContainer)
            : style;
    final corners = BorderRadius.circular(usesMaterialYou ? 18 : 10);
    return ScrollablePositionedList.builder(
      key: ValueKey((_chapter.aid, _chapter.cid)),
      itemScrollController: _list,
      initialScrollIndex: _speech.paragraphIndex,
      initialAlignment: .12,
      padding: EdgeInsets.fromLTRB(
        18,
        insets.top + 64,
        18,
        (_showMenu ? 0 : insets.bottom) + 24,
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
                    color: selected == index ? highlight : Colors.transparent,
                    borderRadius: corners,
                    child: InkWell(
                      borderRadius: corners,
                      onTap:
                          _loading || !_showMenu || !_valid
                              ? null
                              : () => _selectParagraph(index, play: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Text(
                          paragraphs[index].text,
                          style: selected == index ? playingStyle : style,
                        ),
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

  Widget _controls(BuildContext context, double menuHeight) {
    final colors = Theme.of(context).colorScheme;
    final content = LayoutBuilder(
      builder:
          (_, bounds) => SingleChildScrollView(
            primary: false,
            child: _playerContent(menuHeight.clamp(0.0, bounds.maxHeight)),
          ),
    );
    if (usesAppleGlass) {
      return SafeArea(
        top: false,
        child: SettingsCard(
          color: colors.surface,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: content,
        ),
      );
    }
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(materialPanelRadius),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }

  Widget _playerContent(double menuHeight) {
    return Container(
      key: const ValueKey('reader-listening-controls'),
      constraints: BoxConstraints(minHeight: menuHeight),
      padding: EdgeInsets.symmetric(
        horizontal: usesMaterialYou ? 16 : 12,
        vertical: 12,
      ),
      child: ListenableBuilder(
        listenable: _speech,
        builder: (context, _) {
          final available = _valid && _foreground && _speech.ready && !_loading;
          final index = _speech.paragraphIndex;
          final retryChapter = _retryChapter;
          final previous =
              available && index > 0
                  ? () => _selectParagraph(index - 1, play: _speech.playing)
                  : null;
          final next =
              available && index + 1 < _speech.segmentCount
                  ? () => _selectParagraph(index + 1, play: _speech.playing)
                  : null;
          final play = available ? _togglePlayback : null;
          final playbackLabel = _speech.playing ? '暂停' : '播放';
          final sleepLabel = _sleepChoice == 0 ? '定时停止' : '定时已设置';
          return Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_speech.ready)
                ReaderPageScrubber(
                  embedded: true,
                  wavy: usesMaterialYou,
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
              if (usesMaterialYou) ...[
                const SizedBox(height: 4),
                _materialPlayback(context, previous, play, next, playbackLabel),
                const SizedBox(height: 10),
                _materialOptions(context, sleepLabel),
                const SizedBox(height: 4),
              ] else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Flexible(
                      child: AppButton.text(
                        onPressed: () => _rate(context),
                        child: Text('${_rateLabel(_speech.rate)}×'),
                      ),
                    ),
                    _icon(
                      '上一段',
                      CupertinoIcons.backward_end_fill,
                      Icons.skip_previous,
                      previous,
                    ),
                    _icon(
                      playbackLabel,
                      _speech.playing
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      _speech.playing ? Icons.pause : Icons.play_arrow,
                      play,
                      size: 38,
                    ),
                    _icon(
                      '下一段',
                      CupertinoIcons.forward_end_fill,
                      Icons.skip_next,
                      next,
                    ),
                    _icon(
                      sleepLabel,
                      _sleepChoice == 0
                          ? CupertinoIcons.moon
                          : CupertinoIcons.moon_fill,
                      _sleepChoice == 0
                          ? Icons.bedtime_outlined
                          : Icons.bedtime,
                      () => _sleep(context),
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
                    _valid ? () => _directory(context) : null,
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
                    () => _openVoices(context),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _materialPlayback(
    BuildContext context,
    VoidCallback? previous,
    VoidCallback? play,
    VoidCallback? next,
    String playbackLabel,
  ) {
    final theme = Theme.of(context);
    final skipStyle = IconButton.styleFrom(
      shape: const _ParagraphSkipBorder(),
      fixedSize: const Size.square(60),
      padding: EdgeInsets.zero,
      backgroundColor: theme.colorScheme.secondaryContainer,
      foregroundColor: theme.colorScheme.onSecondaryContainer,
    );
    return Row(
      spacing: 8,
      children: [
        IconButton.filledTonal(
          tooltip: '上一段',
          style: skipStyle,
          onPressed: previous,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        Expanded(
          child: Tooltip(
            message: playbackLabel,
            excludeFromSemantics: true,
            child: FilledButton.icon(
              onPressed: play,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 64),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: const StadiumBorder(),
                textStyle: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              icon: Icon(
                _speech.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(
                playbackLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          tooltip: '下一段',
          style: skipStyle,
          onPressed: next,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }

  Widget _materialOptions(BuildContext context, String sleepLabel) {
    final colors = Theme.of(context).colorScheme;
    final optionStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 48),
      backgroundColor: colors.surfaceContainerHighest,
      foregroundColor: colors.onSurface,
    );
    return Row(
      spacing: 8,
      children: [
        Expanded(
          child: Tooltip(
            message: '播放倍速',
            child: FilledButton.tonalIcon(
              onPressed: () => _rate(context),
              style: optionStyle,
              icon: const Icon(Icons.speed_rounded),
              label: Text('${_rateLabel(_speech.rate)}×'),
            ),
          ),
        ),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: () => _sleep(context),
            style:
                _sleepChoice == 0
                    ? optionStyle
                    : optionStyle.copyWith(
                      backgroundColor: WidgetStatePropertyAll(
                        colors.tertiaryContainer,
                      ),
                      foregroundColor: WidgetStatePropertyAll(
                        colors.onTertiaryContainer,
                      ),
                    ),
            icon: Icon(
              _sleepChoice == 0 ? Icons.bedtime_outlined : Icons.bedtime,
            ),
            label: Text(
              sleepLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _icon(
    String label,
    IconData ios,
    IconData android,
    VoidCallback? onPressed, {
    double size = 24,
  }) {
    if (usesMaterialYou) {
      return IconButton.filledTonal(
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(minimumSize: const Size(56, 44)),
        icon: Icon(android, size: size),
      );
    }
    return AppIconButton(
      tooltip: label,
      onPressed: onPressed,
      color:
          usesAppleGlass && onPressed == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : null,
      icon: Icon(usesAppleGlass ? ios : android, size: size),
    );
  }
}

class _ParagraphSkipBorder extends OutlinedBorder {
  const _ParagraphSkipBorder({super.side});

  static final _path = MaterialShapes.cookie9Sided.normalized().toPath();

  @override
  _ParagraphSkipBorder copyWith({BorderSide? side}) =>
      _ParagraphSkipBorder(side: side ?? this.side);

  @override
  _ParagraphSkipBorder scale(double t) => copyWith(side: side.scale(t));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final size = rect.shortestSide;
    final transform = Matrix4.diagonal3Values(size, size, 1)..setTranslationRaw(
      rect.center.dx - size / 2,
      rect.center.dy - size / 2,
      0,
    );
    return _path.transform(transform.storage);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect.deflate(side.width), textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.solid) {
      canvas.drawPath(
        getOuterPath(rect.deflate(side.width / 2)),
        side.toPaint(),
      );
    }
  }
}
