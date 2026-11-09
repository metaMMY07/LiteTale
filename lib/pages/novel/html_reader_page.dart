import 'package:wild/widgets/reader_chapter_sheet.dart';
import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/widgets/reader_settings_panel.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:flutter/material.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/widgets/reader_illustration.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/source_website.dart';
import 'dart:math' as math;
import 'package:wild/models/reader_page.dart' show ReaderFragment;
import 'package:wild/models/reader_document.dart' show ReaderLength;
import 'package:wild/widgets/reader_styled_paragraph.dart';
import 'package:wild/services/reader_typography.dart';
import 'package:wild/widgets/reading_progress_scope.dart';
import 'package:wild/services/frame_auto_scroller.dart';
import 'package:wild/sources/book_source.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../src/rust/wenku8/models.dart';
import 'html_reader_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/pages/novel/fullscreen_cubit.dart';
import 'package:wild/cubits/screen_keep_on.dart';
import 'package:wild/pages/novel/auto_scroll_cubit.dart';
import 'package:wild/pages/novel/auto_scroll_config_cubit.dart';
import 'package:wild/utils/controller_event.dart';
import 'package:wild/widgets/reader_volume_turn_scope.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'dart:io';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/reading_session_scope.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'dart:async';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:wild/models/reader_mark.dart';
import 'package:wild/services/reader_mark_store.dart';
import 'package:wild/widgets/reader_mark_selection.dart';
import 'package:wild/widgets/reader_marks_panel.dart';
import 'package:wild/theme/ios_page_arrival.dart';

class HtmlReaderPage extends StatelessWidget {
  final NovelInfo novelInfo;
  final String initialAid;
  final String initialCid;
  final List<Volume> volumes;
  final ReaderMarkStore? markStore;

  const HtmlReaderPage({
    super.key,
    required this.novelInfo,
    required this.initialAid,
    required this.initialCid,
    required this.volumes,
    this.markStore,
  });

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create:
              (context) => HtmlReaderCubit(
                novelInfo: novelInfo,
                initialAid: initialAid,
                initialCid: initialCid,
                initialVolumes: volumes,
                initialRouteArrival: IosPageArrival.pendingOf(context),
              )..loadChapter(),
        ),
        BlocProvider(create: (context) => FullscreenCubit()),
        BlocProvider(create: (context) => AutoScrollCubit()),
        BlocProvider(
          create: (context) => AutoScrollConfigCubit()..loadConfig(),
        ),
      ],
      child: ReadingProgressScope(
        child: _HtmlReaderViewWrapper(bookId: initialAid, markStore: markStore),
      ),
    );
  }
}

class _HtmlReaderViewWrapper extends StatefulWidget {
  const _HtmlReaderViewWrapper({required this.bookId, this.markStore});
  final String bookId;
  final ReaderMarkStore? markStore;

  @override
  State<_HtmlReaderViewWrapper> createState() => _HtmlReaderViewWrapperState();
}

class _HtmlReaderViewWrapperState extends State<_HtmlReaderViewWrapper>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final ScrollController _scrollController;
  final _readingSessionKey = GlobalKey<ReadingSessionScopeState>();
  final _imageViewport = GlobalKey();
  final _markViewport = GlobalKey();
  late final _visibleImages = ReaderImageHitRegistry(_imageViewport);
  late final FrameAutoScroller _autoScroller;
  late final ReaderMarkSelection _marks;
  bool _selecting = false;
  int _jumpRevision = 0;
  ({ReaderMarkChapter chapter, int index, int revision})? _landing;

  @override
  void initState() {
    super.initState();
    setKeepScreenUpOnReading(true);
    _scrollController = ScrollController(keepScrollOffset: false);
    final cubit = context.read<HtmlReaderCubit>();
    _marks = ReaderMarkSelection(
      viewport: _markViewport,
      book: widget.bookId,
      store: widget.markStore,
      chapterText: (chapter, axis) {
        final state = cubit.state;
        if (axis != ReaderMarkAxis.text ||
            state is! HtmlReaderLoaded ||
            chapter.aid != state.aid ||
            chapter.cid != state.cid) {
          return null;
        }
        return (
          text: state.markContent ?? state.rawContent,
          encoded: state.sourceFont != null,
        );
      },
      canSelect:
          (group) =>
              mounted &&
              cubit.state is HtmlReaderLoaded &&
              ModalRoute.of(context)?.isCurrent != false,
      onStart: () {
        context.read<AutoScrollCubit>().stop();
        _stopAutoScroll();
        final fullscreen = context.read<FullscreenCubit>();
        if (!fullscreen.state) fullscreen.toggle();
      },
    )..addListener(_selectionChanged);
    _scrollController.addListener(_marks.clear);
    unawaited(_marks.store.load(_marks.book).catchError((Object _) {}));
    WidgetsBinding.instance.addObserver(this);
    _autoScroller = FrameAutoScroller(
      vsync: this,
      controller: _scrollController,
      pixelsPerSecond: () {
        final config = context.read<AutoScrollConfigCubit>().state;
        return config.scrollSpeed *
            1000 /
            (config.scrollInterval <= 0 ? 16 : config.scrollInterval);
      },
      onEnd: () {
        if (mounted) context.read<AutoScrollCubit>().stop();
      },
    );
  }

  @override
  void dispose() {
    setKeepScreenUpOnReading(false);
    setKeepScreenUpOnScroll(false);
    WidgetsBinding.instance.removeObserver(this);
    _autoScroller.dispose();
    _scrollController.dispose();
    _marks.dispose();

    super.dispose();
  }

  void _selectionChanged() {
    final selecting = _marks.value != null;
    if (selecting != _selecting && mounted) {
      setState(() => _selecting = selecting);
    }
  }

  double get _topInset =>
      context.read<TopBarHeightCubit>().state +
      MediaQueryData.fromView(View.of(context)).padding.top;

  Future<void> _showChapterList(BuildContext context) async {
    final cubit = context.read<HtmlReaderCubit>();
    final chapter = await showReaderChapterSheet(
      context,
      volumes: cubit.initialVolumes,
      currentAid: cubit.initialAid,
      currentCid: cubit.initialCid,
    );
    if (mounted && !cubit.isClosed && chapter != null) {
      _marks.clear();
      _landing = null;
      await cubit.loadChapter(aid: chapter.aid, cid: chapter.cid);
    }
  }

  Future<void> _showSettings(BuildContext context) async {
    final cubit = context.read<HtmlReaderCubit>();
    _marks.clear();
    final open = await showReaderSettingsPanel(
      context,
      localEpub: sourceOf(cubit.initialAid) == SourceId.localEpub,
      autoScroll: context.read<AutoScrollConfigCubit>(),
      includeMarks: cubit.state is HtmlReaderLoaded,
    );
    final state = cubit.state;
    if (!open ||
        !mounted ||
        !context.mounted ||
        state is! HtmlReaderLoaded ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final chapter = (aid: state.aid, cid: state.cid);
    final current =
        _marks.visiblePosition(0, _topInset) ??
        ReaderMarkLocation(
          chapter,
          state.title,
          ReaderMarkAxis.text,
          state.parsedContent.firstOrNull?.offset ?? 0,
        );
    final text = state.markContent ?? state.rawContent;
    final quote =
        current.offset < text.length
            ? readerMarkExcerpt(
              text.substring(current.offset).characters.take(72).toString(),
              encoded: state.sourceFont != null,
            )
            : '';
    final mark = await showReaderMarks(
      context,
      selection: _marks,
      current: current,
      bookmarkExcerpt: quote,
    );
    if (mark != null && mounted && !cubit.isClosed) {
      await _openMark(cubit, mark);
    }
  }

  Future<void> _openMark(HtmlReaderCubit cubit, ReaderMark mark) async {
    final target = mark.location, chapter = mark.location.chapter;
    final revision = ++_jumpRevision;
    _marks.clear();
    if (target.axis != ReaderMarkAxis.text) {
      showReaderMarkError(context, '请切回分页模式查看此书签');
      return;
    }
    var state = cubit.state;
    if (state is! HtmlReaderLoaded ||
        state.aid != chapter.aid ||
        state.cid != chapter.cid) {
      await cubit.loadChapter(aid: chapter.aid, cid: chapter.cid);
      state = cubit.state;
    }
    if (!mounted ||
        revision != _jumpRevision ||
        state is! HtmlReaderLoaded ||
        state.aid != chapter.aid ||
        state.cid != chapter.cid) {
      return;
    }
    final offset = mark.offsetIn(state.markContent ?? state.rawContent);
    if (offset == null || state.parsedContent.isEmpty) {
      showReaderMarkError(context, '未能定位该标记');
      return;
    }
    var index = 0;
    while (index + 1 < state.parsedContent.length &&
        state.parsedContent[index + 1].offset <= offset) {
      index++;
    }
    setState(
      () => _landing = (chapter: chapter, index: index, revision: revision),
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        revision != _jumpRevision ||
        !identical(cubit.state, state) ||
        !_scrollController.hasClients) {
      return;
    }
    final rendered = _marks.renderedPosition(target.at(offset));
    if (rendered != null) {
      final viewport = RenderAbstractViewport.maybeOf(rendered.box);
      if (viewport == null) return;
      final scroll = _scrollController.position;
      final y =
          viewport
              .getOffsetToReveal(rendered.box, 0, rect: rendered.rect)
              .offset;
      _scrollController.jumpTo(
        (y - _topInset).clamp(scroll.minScrollExtent, scroll.maxScrollExtent),
      );
    }
  }

  void _toggleAutoScroll(BuildContext context) {
    final autoScrollCubit = context.read<AutoScrollCubit>();
    final fullscreenCubit = context.read<FullscreenCubit>();

    if (!autoScrollCubit.state) {
      // Start auto-scroll
      fullscreenCubit.toggle();
      autoScrollCubit.start();
      _startAutoScroll();
    } else {
      // Stop auto-scroll
      autoScrollCubit.stop();
      _stopAutoScroll();
    }
  }

  void _startAutoScroll() {
    setKeepScreenUpOnScroll(true);
    _autoScroller.start();
  }

  void _stopAutoScroll() {
    setKeepScreenUpOnScroll(false);
    _autoScroller.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopAutoScroll();
    } else if (context.read<AutoScrollCubit>().state) {
      _startAutoScroll();
    }
  }

  void _onController(ReaderControllerEventArgs args) {
    if (!mounted || !_scrollController.hasClients || _selecting) return;
    _readingSessionKey.currentState?.recordActivity();
    context.read<AutoScrollCubit>().stop();
    _stopAutoScroll();

    if (args.key == "UP") {
      // 音量上键 - 向上滚动
      final currentOffset = _scrollController.offset;
      final minimum = _scrollController.position.minScrollExtent;
      if (currentOffset <= minimum) {
        // 已到达顶部，切换到上一章
        if (!settingsPreferencesOf(context, listen: false).boundaryChapters) {
          return;
        }
        context.read<HtmlReaderCubit>().goToPreviousChapter();
      } else {
        // 向上滚动一屏
        final screenHeight = _scrollController.position.viewportDimension;
        final targetOffset = (currentOffset - screenHeight * 0.8).clamp(
          minimum,
          _scrollController.position.maxScrollExtent,
        );
        _scrollController.jumpTo(targetOffset);
      }
    } else if (args.key == "DOWN") {
      // 音量下键 - 向下滚动
      final currentOffset = _scrollController.offset;
      final maxScrollExtent = _scrollController.position.maxScrollExtent;

      if (currentOffset >= maxScrollExtent - 10) {
        // 已到达底部，切换到下一章
        if (!settingsPreferencesOf(context, listen: false).boundaryChapters) {
          return;
        }
        context.read<HtmlReaderCubit>().goToNextChapter();
      } else {
        // 向下滚动一屏
        final screenHeight = _scrollController.position.viewportDimension;
        final targetOffset = (currentOffset + screenHeight * 0.8).clamp(
          0.0,
          maxScrollExtent,
        );
        _scrollController.jumpTo(targetOffset);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<HtmlReaderCubit>();
    return BlocBuilder<ThemeCubit, ReaderTheme>(
      builder: (context, theme) {
        final mediaQuery = MediaQuery.of(context);
        bool isDarkMode;
        if (theme.themeMode == ReaderThemeMode.dark) {
          isDarkMode = true;
        } else if (theme.themeMode == ReaderThemeMode.light) {
          isDarkMode = false;
        } else {
          isDarkMode = mediaQuery.platformBrightness == Brightness.dark;
        }

        final backgroundColor =
            isDarkMode ? theme.darkBackgroundColor : theme.lightBackgroundColor;
        final textColor =
            isDarkMode ? theme.darkTextColor : theme.lightTextColor;

        return BlocConsumer<HtmlReaderCubit, HtmlReaderState>(
          listenWhen:
              (previous, current) =>
                  current is! HtmlReaderLoaded ||
                  previous is! HtmlReaderLoaded ||
                  previous.cid != current.cid ||
                  previous.aid != current.aid,
          listener: (context, state) {
            _marks.clear();
            if (_landing != null &&
                (state is! HtmlReaderLoaded ||
                    _landing!.chapter != (aid: state.aid, cid: state.cid))) {
              setState(() => _landing = null);
            }
          },
          builder: (context, state) {
            return ReaderVolumeTurnScope(
              active: state is HtmlReaderLoaded && !_selecting,
              onTurn: _onController,
              child: BlocBuilder<FullscreenCubit, bool>(
                builder: (context, isFullscreen) {
                  return BlocListener<FullscreenCubit, bool>(
                    listener: (context, isFullscreen) {
                      if (!isFullscreen) {
                        // Exit fullscreen, stop auto-scroll
                        context.read<AutoScrollCubit>().stop();
                        _stopAutoScroll();
                      }
                    },
                    child: BlocBuilder<
                      ReaderBackgroundCubit,
                      ReaderBackgroundState
                    >(
                      builder: (context, backgroundState) {
                        String? backgroundImagePath;
                        if (isDarkMode) {
                          backgroundImagePath =
                              context
                                  .read<ReaderBackgroundCubit>()
                                  .getDarkBackgroundPath();
                        } else {
                          backgroundImagePath =
                              context
                                  .read<ReaderBackgroundCubit>()
                                  .getLightBackgroundPath();
                        }

                        return ReadingSessionScope(
                          key: _readingSessionKey,
                          bookId: cubit.initialAid,
                          title: cubit.novelInfo.title,
                          isReading: state is HtmlReaderLoaded,
                          child: PopScope(
                            canPop:
                                !_selecting &&
                                (!settingsPreferencesOf(context).preventBack ||
                                    !isFullscreen),
                            onPopInvokedWithResult: (didPop, result) {
                              if (!didPop && _marks.clear()) return;
                              if (!didPop && isFullscreen) {
                                context.read<FullscreenCubit>().toggle();
                              }
                            },
                            child: Scaffold(
                              backgroundColor: backgroundColor,
                              extendBodyBehindAppBar: true,
                              body: Stack(
                                key: _markViewport,
                                children: [
                                  // 背景图片
                                  if (backgroundImagePath != null)
                                    Positioned.fill(
                                      child: Image.file(
                                        File(backgroundImagePath),
                                        fit: BoxFit.cover,
                                        opacity: AlwaysStoppedAnimation(
                                          backgroundState.opacity,
                                        ),
                                      ),
                                    ),
                                  // 底层内容
                                  GestureDetector(
                                    key: _imageViewport,
                                    onTap: () {
                                      if (_marks.clear()) return;
                                      final fullscreen =
                                          context.read<FullscreenCubit>();
                                      if (!fullscreen.state ||
                                          !_visibleImages.hasVisibleImage) {
                                        fullscreen.toggle();
                                      }
                                    },
                                    child:
                                        state is HtmlReaderLoading
                                            ? SourceLoadingIndicator(
                                              source: sourceOf(
                                                context
                                                    .read<HtmlReaderCubit>()
                                                    .initialAid,
                                              ),
                                              requestKey: state,
                                            )
                                            : state is HtmlReaderError
                                            ? Center(
                                              child: SingleChildScrollView(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      state.error,
                                                      style: TextStyle(
                                                        color: textColor,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 16),
                                                    SourceWebsiteLink(
                                                      source: sourceOf(
                                                        context
                                                            .read<
                                                              HtmlReaderCubit
                                                            >()
                                                            .initialAid,
                                                      ),
                                                    ),
                                                    AppButton.elevated(
                                                      onPressed: () {
                                                        context
                                                            .read<
                                                              HtmlReaderCubit
                                                            >()
                                                            .loadChapter();
                                                      },
                                                      child: const Text('重试'),
                                                    ),
                                                    BiliRecoveryButton(
                                                      error: state.cause,
                                                      source: sourceOf(
                                                        context
                                                            .read<
                                                              HtmlReaderCubit
                                                            >()
                                                            .initialAid,
                                                      ),
                                                      onRecovered:
                                                          () =>
                                                              context
                                                                  .read<
                                                                    HtmlReaderCubit
                                                                  >()
                                                                  .loadChapter(),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            )
                                            : state is HtmlReaderLoaded
                                            ? ReaderImageHitScope(
                                              registry: _visibleImages,
                                              child: _ReaderContent(
                                                key: ValueKey((
                                                  state.aid,
                                                  state.cid,
                                                  _landing?.revision,
                                                )),
                                                parsedContent:
                                                    state.parsedContent,
                                                marks: _marks,
                                                markLocation:
                                                    ReaderMarkLocation(
                                                      (
                                                        aid: state.aid,
                                                        cid: state.cid,
                                                      ),
                                                      state.title,
                                                      ReaderMarkAxis.text,
                                                      0,
                                                    ),
                                                startIndex:
                                                    _landing?.chapter ==
                                                            (
                                                              aid: state.aid,
                                                              cid: state.cid,
                                                            )
                                                        ? _landing!.index
                                                        : 0,
                                                // The open book owns its image
                                                // policy, including on scroll.
                                                source: sourceOf(
                                                  context
                                                      .read<HtmlReaderCubit>()
                                                      .initialAid,
                                                ),
                                                onPreviousChapter:
                                                    cubit.goToPreviousChapter,
                                                onNextChapter:
                                                    cubit.goToNextChapter,
                                                scrollController:
                                                    _scrollController,
                                              ),
                                            )
                                            : const SizedBox.shrink(),
                                  ),
                                  // 顶部和底部导航按钮（仅在隐藏 AppBar 时显示）
                                  if (!isFullscreen)
                                    Positioned(
                                      top: 0,
                                      left: 0,
                                      right: 0,
                                      child: ReaderToolbar(
                                        title:
                                            state is HtmlReaderLoaded
                                                ? state.title
                                                : cubit.novelInfo.title,
                                        onBack: () => Navigator.pop(context),
                                        onCatalog:
                                            () => _showChapterList(context),
                                        onSettings:
                                            () => _showSettings(context),
                                        onAutoScroll:
                                            () => _toggleAutoScroll(context),
                                      ),
                                    ),
                                  if (state is HtmlReaderLoaded)
                                    Positioned.fill(
                                      child: ReaderMarkLayer(selection: _marks),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _ReaderContent extends StatelessWidget {
  final List<ParsedContent> parsedContent;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final ScrollController scrollController;
  final SourceId source;
  final ReaderMarkSelection marks;
  final ReaderMarkLocation markLocation;
  final int startIndex;

  const _ReaderContent({
    super.key,
    required this.parsedContent,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.scrollController,
    required this.source,
    required this.marks,
    required this.markLocation,
    this.startIndex = 0,
  });

  Widget _marked(
    ParsedContent content,
    String text,
    Widget child, {
    bool selectable = true,
  }) => ReaderMarkedRegion(
    selection: marks,
    group: 0,
    text: text,
    location: markLocation.at(content.offset),
    selectable: selectable,
    child: child,
  );

  Widget _buildContentWidget(
    BuildContext context,
    ParsedContent content, {
    required double fontSize,
    required double lineHeight,
    required double paragraphSpacing,
    required Color textColor,
    required String fontFamily,
  }) {
    if (content is ParsedStyledText) {
      return LayoutBuilder(
        builder: (context, constraints) {
          double resolve(ReaderLength length) => length
              .resolve(fontSize, referenceWidth: constraints.maxWidth)
              .clamp(0.0, 256.0);
          final previous = content.previousStyle;
          final gap = math.max(
            resolve(content.block.style.marginTop),
            previous == null
                ? 0.0
                : previous.hasMargins
                ? resolve(previous.marginBottom)
                : paragraphSpacing,
          );
          return _marked(
            content,
            content.block.text,
            ReaderStyledParagraph(
              fragment: ReaderFragment(
                block: content.block,
                start: 0,
                end: content.block.text.length,
                first: true,
                last: true,
                gapBefore: gap,
                gapAfter:
                    content.endOfTextRun
                        ? content.block.style.hasMargins
                            ? resolve(content.block.style.marginBottom)
                            : paragraphSpacing
                        : 0,
              ),
              style: readerBodyStyle(
                fontSize: fontSize,
                lineHeight: lineHeight,
                fontFamily: fontFamily,
                boldText: MediaQuery.boldTextOf(context),
              ).copyWith(color: textColor),
              textScaler: MediaQuery.textScalerOf(context),
            ),
          );
        },
      );
    } else if (content is ParsedText) {
      return Padding(
        padding: EdgeInsets.only(bottom: paragraphSpacing),
        child: _marked(
          content,
          content.text,
          Text(
            content.text,
            style: TextStyle(
              fontFamily: fontFamily,
              locale: readerHanLocale,
              fontFamilyFallback: const [appFontFamily],
              fontSize: fontSize,
              height: lineHeight,
              color: textColor,
            ),
          ),
        ),
      );
    } else if (content is ParsedImage) {
      return _marked(
        content,
        '',
        LayoutBuilder(
          builder: (context, constraints) {
            return Padding(
              padding: EdgeInsets.symmetric(vertical: paragraphSpacing),
              child: SizedBox(
                width: constraints.maxWidth,
                child: AspectRatio(
                  aspectRatio: 4 / 3, // 默认图片比例
                  child: ReaderIllustration(
                    image: ReaderImageRef(
                      source: source,
                      url: content.imageUrl,
                    ),
                    provider: CachedImageProvider(
                      content.imageUrl,
                      source: source,
                    ),
                    child: Image(
                      image: CachedImageProvider(
                        content.imageUrl,
                        source: source,
                      ),
                      fit: BoxFit.contain,
                      loadingBuilder:
                          (context, child, progress) =>
                              progress == null
                                  ? child
                                  : const CenteredLoadingIndicator(),
                      errorBuilder:
                          (_, _, _) => const Center(child: Text('图片加载失败')),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        selectable: false,
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final readerFamily = context.select(
      (FontSettingsCubit cubit) => cubit.state.readerFamily,
    );
    final reader = context.read<HtmlReaderCubit>().state;
    final fontFamily =
        reader is HtmlReaderLoaded
            ? reader.sourceFont ?? readerFamily
            : readerFamily;
    return BlocBuilder<ThemeCubit, ReaderTheme>(
      builder: (context, theme) {
        final mediaQuery = MediaQuery.of(context);
        bool isDarkMode;
        if (theme.themeMode == ReaderThemeMode.dark) {
          isDarkMode = true;
        } else if (theme.themeMode == ReaderThemeMode.light) {
          isDarkMode = false;
        } else {
          isDarkMode = mediaQuery.platformBrightness == Brightness.dark;
        }

        final textColor =
            isDarkMode ? theme.darkTextColor : theme.lightTextColor;

        return BlocBuilder<FontSizeCubit, double>(
          builder: (context, fontSize) {
            return BlocBuilder<LineHeightCubit, double>(
              builder: (context, lineHeight) {
                return BlocBuilder<ParagraphSpacingCubit, double>(
                  builder: (context, paragraphSpacing) {
                    return BlocBuilder<TopBarHeightCubit, double>(
                      builder: (context, topBarHeight) {
                        return BlocBuilder<BottomBarHeightCubit, double>(
                          builder: (context, bottomBarHeight) {
                            return BlocBuilder<FullscreenCubit, bool>(
                              builder: (context, isFullscreen) {
                                final topPad =
                                    MediaQueryData.fromView(
                                      View.of(context),
                                    ).padding.top;
                                final bottomPad =
                                    MediaQueryData.fromView(
                                      View.of(context),
                                    ).padding.bottom;

                                final footer = [
                                  ...[
                                    const SizedBox(height: 32),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        AppButton.text(
                                          onPressed: onPreviousChapter,
                                          child: Text(
                                            '上一章',
                                            style: TextStyle(color: textColor),
                                          ),
                                        ),
                                        AppButton.text(
                                          onPressed: onNextChapter,
                                          child: Text(
                                            '下一章',
                                            style: TextStyle(color: textColor),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 32),
                                  ],
                                ];

                                return BlocBuilder<LeftPaddingCubit, double>(
                                  builder: (context, leftPadding) {
                                    return BlocBuilder<
                                      RightPaddingCubit,
                                      double
                                    >(
                                      builder: (context, rightPadding) {
                                        return NotificationListener<
                                          ScrollStartNotification
                                        >(
                                          onNotification: (notification) {
                                            if (notification.dragDetails !=
                                                null) {
                                              context
                                                  .read<AutoScrollCubit>()
                                                  .stop();
                                            }
                                            return false;
                                          },
                                          child: _ReaderIndexedScroll(
                                            controller: scrollController,
                                            start: startIndex,
                                            count:
                                                parsedContent.length +
                                                footer.length,
                                            padding: EdgeInsets.only(
                                              left: leftPadding,
                                              right: rightPadding,
                                              top: topBarHeight + topPad,
                                              bottom:
                                                  bottomBarHeight + bottomPad,
                                            ),
                                            builder:
                                                (context, index) =>
                                                    index < parsedContent.length
                                                        ? _buildContentWidget(
                                                          context,
                                                          parsedContent[index],
                                                          fontSize: fontSize,
                                                          lineHeight:
                                                              lineHeight,
                                                          paragraphSpacing:
                                                              paragraphSpacing,
                                                          textColor: textColor,
                                                          fontFamily:
                                                              fontFamily,
                                                        )
                                                        : footer[index -
                                                            parsedContent
                                                                .length],
                                          ),
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Jump directly to a variable-height item without measuring every preceding
/// paragraph. Earlier content stays available above the new scroll origin.
class _ReaderIndexedScroll extends StatelessWidget {
  const _ReaderIndexedScroll({
    required this.controller,
    required this.start,
    required this.count,
    required this.padding,
    required this.builder,
  });
  final ScrollController controller;
  final int start, count;
  final EdgeInsets padding;
  final IndexedWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    if (start == 0) {
      return ListView.builder(
        controller: controller,
        padding: padding,
        itemCount: count,
        itemBuilder: builder,
      );
    }
    const center = ValueKey('reader-scroll-target');
    return CustomScrollView(
      controller: controller,
      center: center,
      slivers: [
        SliverPadding(
          padding: padding.copyWith(bottom: 0),
          sliver: SliverList.builder(
            itemCount: start,
            itemBuilder:
                (context, index) => builder(context, start - index - 1),
          ),
        ),
        SliverPadding(
          key: center,
          padding: padding.copyWith(top: 0),
          sliver: SliverList.builder(
            itemCount: count - start,
            itemBuilder: (context, index) => builder(context, start + index),
          ),
        ),
      ],
    );
  }
}
