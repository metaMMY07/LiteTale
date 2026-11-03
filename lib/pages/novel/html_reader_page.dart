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

class HtmlReaderPage extends StatelessWidget {
  final NovelInfo novelInfo;
  final String initialAid;
  final String initialCid;
  final List<Volume> volumes;

  const HtmlReaderPage({
    super.key,
    required this.novelInfo,
    required this.initialAid,
    required this.initialCid,
    required this.volumes,
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
              )..loadChapter(),
        ),
        BlocProvider(create: (context) => FullscreenCubit()),
        BlocProvider(create: (context) => AutoScrollCubit()),
        BlocProvider(
          create: (context) => AutoScrollConfigCubit()..loadConfig(),
        ),
      ],
      child: const ReadingProgressScope(child: _HtmlReaderViewWrapper()),
    );
  }
}

class _HtmlReaderViewWrapper extends StatefulWidget {
  const _HtmlReaderViewWrapper();

  @override
  State<_HtmlReaderViewWrapper> createState() => _HtmlReaderViewWrapperState();
}

class _HtmlReaderViewWrapperState extends State<_HtmlReaderViewWrapper>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final ScrollController _scrollController;
  final _readingSessionKey = GlobalKey<ReadingSessionScopeState>();
  late final FrameAutoScroller _autoScroller;

  @override
  void initState() {
    super.initState();
    setKeepScreenUpOnReading(true);
    _scrollController = ScrollController();
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

    super.dispose();
  }

  Future<void> _showChapterList(BuildContext context) async {
    final cubit = context.read<HtmlReaderCubit>();
    final chapter = await showReaderChapterSheet(
      context,
      volumes: cubit.initialVolumes,
      currentAid: cubit.initialAid,
      currentCid: cubit.initialCid,
    );
    if (mounted && !cubit.isClosed && chapter != null) {
      await cubit.loadChapter(aid: chapter.aid, cid: chapter.cid);
    }
  }

  void _showSettings(BuildContext context) {
    showReaderSettingsPanel(
      context,
      localEpub:
          sourceOf(context.read<HtmlReaderCubit>().initialAid) ==
          SourceId.localEpub,
      autoScroll: context.read<AutoScrollConfigCubit>(),
    );
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
    if (!mounted || !_scrollController.hasClients) return;
    _readingSessionKey.currentState?.recordActivity();
    context.read<AutoScrollCubit>().stop();
    _stopAutoScroll();

    if (args.key == "UP") {
      // 音量上键 - 向上滚动
      final currentOffset = _scrollController.offset;
      if (currentOffset <= 0) {
        // 已到达顶部，切换到上一章
        if (!settingsPreferencesOf(context, listen: false).boundaryChapters) {
          return;
        }
        context.read<HtmlReaderCubit>().goToPreviousChapter();
      } else {
        // 向上滚动一屏
        final screenHeight = _scrollController.position.viewportDimension;
        final targetOffset = (currentOffset - screenHeight * 0.8).clamp(
          0.0,
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

        return BlocBuilder<HtmlReaderCubit, HtmlReaderState>(
          builder: (context, state) {
            return ReaderVolumeTurnScope(
              active: state is HtmlReaderLoaded,
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
                                !settingsPreferencesOf(context).preventBack ||
                                !isFullscreen,
                            onPopInvokedWithResult: (didPop, result) {
                              if (!didPop && isFullscreen) {
                                context.read<FullscreenCubit>().toggle();
                              }
                            },
                            child: Scaffold(
                              backgroundColor: backgroundColor,
                              extendBodyBehindAppBar: true,
                              body: Stack(
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
                                    onTap: () {
                                      context.read<FullscreenCubit>().toggle();
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
                                            ? _ReaderContent(
                                              parsedContent:
                                                  state.parsedContent,
                                              // The open book owns its image policy;
                                              // never read the global setting here.
                                              source: sourceOf(
                                                context
                                                    .read<HtmlReaderCubit>()
                                                    .initialAid,
                                              ),
                                              onPreviousChapter: () {
                                                context
                                                    .read<HtmlReaderCubit>()
                                                    .goToPreviousChapter();
                                              },
                                              onNextChapter: () {
                                                context
                                                    .read<HtmlReaderCubit>()
                                                    .goToNextChapter();
                                              },
                                              scrollController:
                                                  _scrollController,
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

  const _ReaderContent({
    required this.parsedContent,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.scrollController,
    required this.source,
  });

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
          return ReaderStyledParagraph(
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
          );
        },
      );
    } else if (content is ParsedText) {
      return Padding(
        padding: EdgeInsets.only(bottom: paragraphSpacing),
        child: Text(
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
      );
    } else if (content is ParsedImage) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: paragraphSpacing),
            child: SizedBox(
              width: constraints.maxWidth,
              child: AspectRatio(
                aspectRatio: 4 / 3, // 默认图片比例
                child: ReaderIllustration(
                  image: ReaderImageRef(source: source, url: content.imageUrl),
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
                                          child: ListView.builder(
                                            controller: scrollController,
                                            padding: EdgeInsets.only(
                                              left: leftPadding,
                                              right: rightPadding,
                                              top: topBarHeight + topPad,
                                              bottom:
                                                  bottomBarHeight + bottomPad,
                                            ),
                                            itemCount:
                                                parsedContent.length +
                                                footer.length,
                                            itemBuilder:
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
