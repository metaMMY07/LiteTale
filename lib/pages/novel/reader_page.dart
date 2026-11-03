import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/widgets/reader_settings_panel.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:flutter/material.dart';
import 'package:wild/services/hardware_turn_buffer.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/widgets/wenku8_recovery_button.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/services/reader_typography.dart';
import 'package:wild/widgets/reader_system_ui_scope.dart';
import 'package:wild/widgets/reader_paper_view.dart';
import 'package:wild/widgets/reader_footer.dart';
import 'package:wild/cubits/screen_keep_on.dart';
import 'package:wild/utils/controller_event.dart';
import 'package:wild/widgets/reader_volume_turn_scope.dart';
import 'dart:io';

import '../../src/rust/wenku8/models.dart';
import 'font_size_cubit.dart';
import 'line_height_cubit.dart';
import 'top_bar_height_cubit.dart';
import 'bottom_bar_height_cubit.dart';
import 'left_padding_cubit.dart';
import 'right_padding_cubit.dart';
import 'reader_type_cubit.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/widgets/reader_cover_view.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/widgets/page_curl_view.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/reading_session_scope.dart';

class ReaderPage extends StatelessWidget {
  final String aid;
  final String cid;
  final String initialTitle;
  final List<Volume> volumes;
  final NovelInfo novelInfo;
  final int? initialPage;
  final int? initialTextOffset;

  const ReaderPage({
    super.key,
    required this.aid,
    required this.cid,
    required this.initialTitle,
    required this.volumes,
    required this.novelInfo,
    this.initialPage,
    this.initialTextOffset,
  });

  @override
  Widget build(BuildContext context) {
    final fontSizeCubit = context.read<FontSizeCubit>();
    final paragraphSpacingCubit = context.read<ParagraphSpacingCubit>();
    final lineHeightCubit = context.read<LineHeightCubit>();
    final topBarHeightCubit = context.read<TopBarHeightCubit>();
    final bottomBarHeightCubit = context.read<BottomBarHeightCubit>();
    final leftPaddingCubit = context.read<LeftPaddingCubit>();
    final rightPaddingCubit = context.read<RightPaddingCubit>();
    final readerTypeCubit = context.read<ReaderTypeCubit>();

    return ReaderSystemUiScope(
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: fontSizeCubit),
          BlocProvider.value(value: paragraphSpacingCubit),
          BlocProvider.value(value: lineHeightCubit),
          BlocProvider.value(value: topBarHeightCubit),
          BlocProvider.value(value: bottomBarHeightCubit),
          BlocProvider.value(value: leftPaddingCubit),
          BlocProvider.value(value: rightPaddingCubit),
          BlocProvider.value(value: readerTypeCubit),
          BlocProvider(
            create:
                (context) => ReaderCubit(
                  novelInfo: novelInfo,
                  initialAid: aid,
                  initialCid: cid,
                  initialVolumes: volumes,
                  fontSizeCubit: fontSizeCubit,
                  paragraphSpacingCubit: paragraphSpacingCubit,
                  lineHeightCubit: lineHeightCubit,
                  topBarHeightCubit: topBarHeightCubit,
                  bottomBarHeightCubit: bottomBarHeightCubit,
                  leftPaddingCubit: leftPaddingCubit,
                  rightPaddingCubit: rightPaddingCubit,
                  fontSettingsCubit: context.read<FontSettingsCubit>(),
                  readerTheme: () => context.read<ThemeCubit>().state,
                  layoutReady: ReaderSystemUiScope.layoutReadyOf(context),
                )..loadChapter(
                  initialPage: initialPage,
                  initialTextOffset: initialTextOffset,
                ),
          ),
        ],
        child: BlocListener<FontSettingsCubit, FontSettingsState>(
          listenWhen:
              (previous, current) =>
                  previous.readerFamily != current.readerFamily,
          listener:
              (context, _) => context.read<ReaderCubit>().reloadCurrentPage(),
          child: BlocBuilder<ReaderCubit, ReaderState>(
            builder: (context, state) {
              if (state is ReaderLoading) {
                return Scaffold(
                  body: SourceLoadingIndicator(
                    source: sourceOf(aid),
                    requestKey: state,
                  ),
                );
              }
              if (state is ReaderError) {
                return Scaffold(
                  body: SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(state.error),
                          const SizedBox(height: 16),
                          SourceWebsiteLink(source: sourceOf(aid)),
                          AppButton.elevated(
                            onPressed:
                                () => context.read<ReaderCubit>().loadChapter(),
                            child: const Text('重试'),
                          ),
                          Wenku8RecoveryButton(
                            error: state.error,
                            source: sourceOf(aid),
                            onRecovered:
                                () => context.read<ReaderCubit>().loadChapter(),
                          ),
                          BiliRecoveryButton(
                            error: state.cause,
                            source: sourceOf(aid),
                            onRecovered:
                                () => context.read<ReaderCubit>().loadChapter(),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              if (state is ReaderLoaded) {
                // A new page list means new pagination. Recreate its controller at
                // the latest clamped position, cancelling any old turn safely.
                return ReadingSessionScope(
                  bookId: state.aid,
                  title: novelInfo.title,
                  active: !state.showControls,
                  child: _ReaderView(
                    key: ObjectKey(state.presentationKey ?? state.pages),
                    state: state,
                    title: state.title,
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }
}

class _ReaderView extends StatefulWidget {
  final ReaderLoaded state;
  final String title;

  const _ReaderView({super.key, required this.state, required this.title});

  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  late final _hardwareTurns = HardwareTurnBuffer(
    active:
        () =>
            mounted &&
            ModalRoute.of(context)?.isCurrent != false &&
            (WidgetsBinding.instance.lifecycleState == null ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.resumed) &&
            context.read<VolumeControlCubit>().state,
    busy: () => _isTurning,
    dispatch: _onController,
  );
  late ReaderCoverController _pageController;
  final _curlKey = GlobalKey<PageCurlViewState>();
  bool _wasCurlEnabled = false;
  Size? _lastLayoutSize;
  EdgeInsets? _lastLayoutPadding;
  TextScaler? _lastTextScaler;
  bool? _lastBoldText;
  String? _lastHanVariant;
  Color? _lastPaperColor, _lastTextColor;
  var preTime = 0;

  int get _viewIndex =>
      widget.state.layout.viewIndex(widget.state.currentPageIndex);
  int get _viewCount =>
      widget.state.layout.viewCount(widget.state.pages.length);

  void _onViewChanged(int index) => context.read<ReaderCubit>().onPageChanged(
    widget.state.layout.firstPage(index),
  );

  /// The open book owns its image policy. Read the book id from the cubit so a
  /// later source switch in settings cannot re-route this reader's images.
  SourceId get _bookSource => sourceOf(context.read<ReaderCubit>().initialAid);

  bool get _curlEnabled =>
      !Platform.isIOS &&
      _bookSource != SourceId.localEpub &&
      context.read<ReaderCurlCubit>().state &&
      !MediaQuery.of(context).disableAnimations;

  bool get _isTurning =>
      _curlEnabled
          ? (_curlKey.currentState?.isTurning ?? false)
          : _pageController.isTurning;

  @override
  void initState() {
    super.initState();
    _pageController = ReaderCoverController();
    setKeepScreenUpOnReading(true);
  }

  @override
  void dispose() {
    _hardwareTurns.dispose();
    _pageController.dispose();
    setKeepScreenUpOnReading(false);
    setKeepScreenUpOnScroll(false);

    super.dispose();
  }

  void _handleTap(TapUpDetails details) {
    if (!settingsPreferencesOf(context, listen: false).tapToTurn) {
      context.read<ReaderCubit>().toggleControls();
      return;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final tapX = details.globalPosition.dx;
    final tapY = details.globalPosition.dy;

    // 将屏幕分为左、中、右三个区域
    final leftArea = screenWidth * 0.3;
    final rightArea = screenWidth * 0.7;
    // 将屏幕分为上、中、下三个区域
    final topArea = screenHeight * 0.3;
    final bottomArea = screenHeight * 0.7;

    final spread = widget.state.layout.isSpread;
    if (tapX < leftArea || (!spread && tapY < topArea)) {
      // 点击左侧或上方区域，上一页
      if (_viewIndex > 0) {
        _turnPage(-1, startY: details.localPosition.dy);
      } else {
        _handleBoundaryTurn(-1);
      }
    } else if (tapX > rightArea || (!spread && tapY > bottomArea)) {
      // 点击右侧或下方区域，下一页
      if (_viewIndex < _viewCount - 1) {
        _turnPage(1, startY: details.localPosition.dy);
      } else {
        _handleBoundaryTurn(1);
      }
    } else {
      // 点击中央区域，切换菜单栏显示状态
      context.read<ReaderCubit>().toggleControls();
    }
  }

  void _handleBoundaryTurn(int direction) {
    if (_bookSource == SourceId.localEpub) {
      context.read<ReaderCubit>().turnBookBoundary(direction);
      return;
    }
    if (!settingsPreferencesOf(context, listen: false).boundaryChapters) return;
    if (direction < 0) {
      if (_viewIndex != 0) return;
      final currentVolumeIndex = _findCurrentVolumeIndex();
      final currentChapterIndex = _findCurrentChapterIndex();
      if (currentChapterIndex > 0 || currentVolumeIndex > 0) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - preTime > 2000) {
          preTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('再次点击加载上一章'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.only(bottom: 16),
            ),
          );
        } else {
          preTime = 0;
          context.read<ReaderCubit>().goToPreviousChapter();
        }
      }
      return;
    }
    if (_viewIndex != _viewCount - 1) {
      return;
    }
    final currentVolumeIndex = _findCurrentVolumeIndex();
    final currentChapterIndex = _findCurrentChapterIndex();
    if (currentVolumeIndex < 0) return;
    final volume = widget.state.volumes[currentVolumeIndex];
    if (currentChapterIndex < volume.chapters.length - 1 ||
        currentVolumeIndex < widget.state.volumes.length - 1) {
      context.read<ReaderCubit>().goToNextChapter();
    }
  }

  void _showChapterList() {
    final readerCubit = context.read<ReaderCubit>();
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return BlocProvider.value(
          value: readerCubit,
          child: DraggableScrollableSheet(
            initialChildSize: 0.9,
            maxChildSize: 0.9,
            minChildSize: 0.5,
            builder:
                (context, scrollController) => _ChapterList(
                  volumes: widget.state.volumes,
                  currentAid: widget.state.aid,
                  currentCid: widget.state.cid,
                  onChapterSelected: (aid, cid) {
                    Navigator.pop(context);
                    readerCubit.loadChapter(aid: aid, cid: cid);
                  },
                ),
          ),
        );
      },
    );
  }

  void _showSettings() {
    final cubit = context.read<ReaderCubit>();
    showReaderSettingsPanel(
      context,
      localEpub: _bookSource == SourceId.localEpub,
      onLayoutChanged: () async {
        if (!cubit.isClosed) await cubit.reloadCurrentPage();
      },
    );
  }

  void _turnPage(int direction, {double? startY}) {
    if (_curlEnabled) {
      _curlKey.currentState?.turn(direction, startY: startY);
    } else {
      _pageController.turn(direction);
    }
  }

  void _onController(ReaderControllerEventArgs args) {
    if (!mounted || _isTurning) return;
    ReadingSessionScope.recordActivity(context);
    if (args.key == "UP") {
      if (_bookSource == SourceId.localEpub && _viewIndex == 0) {
        context.read<ReaderCubit>().turnBookBoundary(-1);
        return;
      }
      // 音量上键 - 上一页
      if (_viewIndex > 0) {
        _turnPage(-1);
      } else {
        // 如果是第一页，尝试加载上一章
        if (!settingsPreferencesOf(context, listen: false).boundaryChapters) {
          return;
        }
        final currentVolumeIndex = _findCurrentVolumeIndex();
        final currentChapterIndex = _findCurrentChapterIndex();
        if (currentChapterIndex > 0 || currentVolumeIndex > 0) {
          context.read<ReaderCubit>().goToPreviousChapter();
        }
      }
    } else if (args.key == "DOWN") {
      if (_bookSource == SourceId.localEpub && _viewIndex == _viewCount - 1) {
        context.read<ReaderCubit>().turnBookBoundary(1);
        return;
      }
      // 音量下键 - 下一页
      if (_viewIndex < _viewCount - 1) {
        _turnPage(1);
      } else {
        // 如果是最后一页，尝试加载下一章
        if (!settingsPreferencesOf(context, listen: false).boundaryChapters) {
          return;
        }
        final currentVolumeIndex = _findCurrentVolumeIndex();
        final currentChapterIndex = _findCurrentChapterIndex();
        if (currentVolumeIndex < 0) return;
        final volume = widget.state.volumes[currentVolumeIndex];
        if (currentChapterIndex < volume.chapters.length - 1 ||
            currentVolumeIndex < widget.state.volumes.length - 1) {
          context.read<ReaderCubit>().goToNextChapter();
        }
      }
    }
  }

  Widget _buildReaderPage(BuildContext context, int index, Color textColor) {
    return ReaderPaperView(
      pages: widget.state.pages,
      viewIndex: index,
      layout: widget.state.layout,
      chapterTitle: widget.title,
      titleFontFamily: context.read<FontSettingsCubit>().state.readerFamily,
      source: _bookSource,
      textStyle: readerBodyStyle(
        fontFamily: widget.state.fontFamily,
        fontSize: context.read<FontSizeCubit>().state,
        lineHeight: context.read<LineHeightCubit>().state,
        boldText: widget.state.layout.boldText,
        color: textColor,
      ),
      paragraphSpacing: context.read<ParagraphSpacingCubit>().state,
    );
  }

  void _syncCurlMode(bool enabled) {
    if (_wasCurlEnabled && !enabled) {
      final old = _pageController;
      _pageController = ReaderCoverController();
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    _wasCurlEnabled = enabled;
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final preferences = settingsPreferencesOf(context);
    final hanChanged =
        _lastHanVariant != null && _lastHanVariant != preferences.hanVariant;
    _lastHanVariant = preferences.hanVariant;
    if (hanChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ReaderCubit>().reloadCurrentPage();
      });
    }
    final metricsChanged =
        widget.state.layout.viewportSize != mediaQuery.size ||
        widget.state.layout.systemPadding != mediaQuery.padding ||
        widget.state.layout.textScaler != mediaQuery.textScaler ||
        widget.state.layout.boldText != mediaQuery.boldText;
    if (metricsChanged &&
        (_lastLayoutSize != mediaQuery.size ||
            _lastLayoutPadding != mediaQuery.padding ||
            _lastTextScaler != mediaQuery.textScaler ||
            _lastBoldText != mediaQuery.boldText)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ReaderCubit>().reloadCurrentPage();
      });
    }
    _lastLayoutSize = mediaQuery.size;
    _lastLayoutPadding = mediaQuery.padding;
    _lastTextScaler = mediaQuery.textScaler;
    _lastBoldText = mediaQuery.boldText;

    final ThemeCubit themeCubit = context.read<ThemeCubit>();
    bool isDarkMode;
    if (themeCubit.state.themeMode == ReaderThemeMode.dark) {
      isDarkMode = true;
    } else if (themeCubit.state.themeMode == ReaderThemeMode.light) {
      isDarkMode = false;
    } else {
      isDarkMode = mediaQuery.platformBrightness == Brightness.dark;
    }
    final backgroundColor =
        isDarkMode
            ? themeCubit.state.darkBackgroundColor
            : themeCubit.state.lightBackgroundColor;
    final textColor =
        isDarkMode
            ? themeCubit.state.darkTextColor
            : themeCubit.state.lightTextColor;
    if (widget.state.pages.first.cssPage != null &&
        _lastPaperColor != null &&
        (_lastPaperColor != backgroundColor || _lastTextColor != textColor)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ReaderCubit>().reloadCurrentPage();
      });
    }
    _lastPaperColor = backgroundColor;
    _lastTextColor = textColor;

    // Never squeeze pages laid out for the previous orientation into half a
    // leaf. Repagination creates a fresh view and cancels any active curl.
    if (metricsChanged) {
      return Scaffold(
        backgroundColor: backgroundColor,
        body: const CenteredLoadingIndicator(),
      );
    }

    var viewer = BlocBuilder<ReaderCubit, ReaderState>(
      builder: (BuildContext context, state) {
        return BlocBuilder<ReaderBackgroundCubit, ReaderBackgroundState>(
          builder: (context, backgroundState) {
            String? backgroundImagePath;
            if (isDarkMode) {
              backgroundImagePath =
                  context.read<ReaderBackgroundCubit>().getDarkBackgroundPath();
            } else {
              backgroundImagePath =
                  context
                      .read<ReaderBackgroundCubit>()
                      .getLightBackgroundPath();
            }

            final paperDecoration = BoxDecoration(
              color: backgroundColor.withValues(alpha: 1),
              image:
                  backgroundImagePath == null
                      ? null
                      : DecorationImage(
                        image: FileImage(File(backgroundImagePath)),
                        fit: BoxFit.cover,
                        opacity: backgroundState.opacity,
                      ),
            );

            return Scaffold(
              backgroundColor: backgroundColor,
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
                  // 阅读内容
                  Positioned.fill(
                    child: BlocBuilder<ReaderCurlCubit, bool>(
                      builder: (context, enabled) {
                        final curlEnabled =
                            !Platform.isIOS &&
                            _bookSource != SourceId.localEpub &&
                            enabled &&
                            !mediaQuery.disableAnimations;
                        _syncCurlMode(curlEnabled);
                        if (curlEnabled) {
                          final curl = PageCurlView(
                            leafCount: widget.state.pages.length,
                            key: _curlKey,
                            pageCount: _viewCount,
                            index: _viewIndex,
                            isSpread: widget.state.layout.isSpread,
                            tapToTurn: preferences.tapToTurn,
                            paperDecoration: paperDecoration,
                            paperColor: backgroundColor,
                            onCenterTap:
                                context.read<ReaderCubit>().toggleControls,
                            onBoundaryTurn: _handleBoundaryTurn,
                            pageBuilder:
                                (context, index) =>
                                    _buildReaderPage(context, index, textColor),
                            onPageChanged: _onViewChanged,
                          );
                          return Platform.isAndroid
                              ? curl
                              : GestureDetector(
                                onTapUp: _handleTap,
                                child: curl,
                              );
                        }
                        return GestureDetector(
                          onTapUp: _handleTap,
                          child: ReaderCoverView(
                            controller: _pageController,
                            index: _viewIndex,
                            pageCount: _viewCount,
                            leafCount: widget.state.pages.length,
                            isSpread: widget.state.layout.isSpread,
                            active: !state.showControls,
                            revision: Object.hash(
                              widget.state.presentationKey ??
                                  widget.state.pages,
                              paperDecoration,
                              widget.title,
                            ),
                            paperDecoration: paperDecoration,
                            onPageChanged: _onViewChanged,
                            onBoundaryTurn: _handleBoundaryTurn,
                            pageBuilder:
                                (context, index) =>
                                    _buildReaderPage(context, index, textColor),
                          ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ReaderFooter(
                      layout: widget.state.layout,
                      pageLabel: context.read<ReaderCubit>().footerPageLabel,
                      color: textColor,
                      fontFamily:
                          context.read<FontSettingsCubit>().state.readerFamily,
                    ),
                  ),
                  if (state.showControls) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ReaderToolbar(
                        title: widget.title,
                        onBack: () => Navigator.pop(context),
                        onCatalog: _showChapterList,
                        onSettings: _showSettings,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Builder(
                        builder: (context) {
                          final cubit = context.read<ReaderCubit>();
                          final progress = cubit.chapterProgress;
                          return ReaderPageScrubber(
                            index: progress.index,
                            count: progress.count,
                            revision: progress.revision,
                            onSeek: (page) async {
                              try {
                                await cubit.seekChapterPage(page);
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('未能跳转到该页，请重试'),
                                    ),
                                  );
                                }
                              }
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
    return ReaderVolumeTurnScope(
      onTurn: _hardwareTurns.add,
      child: PopScope(
        canPop: !preferences.preventBack || widget.state.showControls,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !widget.state.showControls) {
            context.read<ReaderCubit>().toggleControls();
          }
        },
        child: viewer,
      ),
    );
  }

  int _findCurrentVolumeIndex() {
    for (var i = 0; i < widget.state.volumes.length; i++) {
      final volume = widget.state.volumes[i];
      if (volume.chapters.any(
        (chapter) =>
            chapter.aid == widget.state.aid && chapter.cid == widget.state.cid,
      )) {
        return i;
      }
    }
    return -1;
  }

  int _findCurrentChapterIndex() {
    final volumeIndex = _findCurrentVolumeIndex();
    if (volumeIndex == -1) return -1;
    final volume = widget.state.volumes[volumeIndex];
    for (var i = 0; i < volume.chapters.length; i++) {
      final chapter = volume.chapters[i];
      if (chapter.aid == widget.state.aid && chapter.cid == widget.state.cid) {
        return i;
      }
    }
    return -1;
  }
}

class _ChapterList extends StatefulWidget {
  final List<Volume> volumes;
  final String currentAid;
  final String currentCid;
  final Function(String aid, String cid) onChapterSelected;

  const _ChapterList({
    required this.volumes,
    required this.currentAid,
    required this.currentCid,
    required this.onChapterSelected,
  });

  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  late ScrollController _scrollController;
  int _currentChapterGlobalIndex = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    // 计算当前章节的全局索引
    _currentChapterGlobalIndex = _calculateCurrentChapterIndex();
    // 在下一帧滚动到当前章节
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        // 估算每个章节的高度（包括标题和间距）
        const estimatedItemHeight = 56.0; // ListTile 的默认高度
        const estimatedVolumeTitleHeight = 48.0; // 卷标题的高度
        const estimatedSpacing = 16.0; // 间距

        // 计算目标滚动位置
        double targetScroll =
            _currentChapterGlobalIndex *
            (estimatedItemHeight + estimatedSpacing);
        // 加上之前所有卷标题的高度
        for (var i = 0; i < widget.volumes.length; i++) {
          if (i < _findCurrentVolumeIndex()) {
            targetScroll += estimatedVolumeTitleHeight + estimatedSpacing;
          } else {
            break;
          }
        }

        // 滚动到目标位置，并稍微向上偏移一点以显示上下文
        _scrollController.jumpTo(
          (targetScroll - 100)
              .clamp(
                _scrollController.position.minScrollExtent,
                _scrollController.position.maxScrollExtent,
              )
              .toDouble(),
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int _findCurrentVolumeIndex() {
    for (var i = 0; i < widget.volumes.length; i++) {
      final volume = widget.volumes[i];
      if (volume.chapters.any(
        (chapter) =>
            chapter.aid == widget.currentAid &&
            chapter.cid == widget.currentCid,
      )) {
        return i;
      }
    }
    return -1;
  }

  int _calculateCurrentChapterIndex() {
    int globalIndex = 0;
    for (var volume in widget.volumes) {
      for (var chapter in volume.chapters) {
        if (chapter.aid == widget.currentAid &&
            chapter.cid == widget.currentCid) {
          return globalIndex;
        }
        globalIndex++;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.menu_book),
                const SizedBox(width: 8),
                const Text(
                  '目录',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                AppButton.textIcon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  label: const Text('关闭'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: widget.volumes.length,
              itemBuilder: (context, volumeIndex) {
                final volume = widget.volumes[volumeIndex];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        volume.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ...volume.chapters.map((chapter) {
                      final isSelected =
                          chapter.aid == widget.currentAid &&
                          chapter.cid == widget.currentCid;
                      return Container(
                        color:
                            isSelected
                                ? Colors.grey.withAlpha(80)
                                : Colors.transparent,
                        child: ListTile(
                          onTap:
                              () => widget.onChapterSelected(
                                chapter.aid,
                                chapter.cid,
                              ),
                          title: Text(
                            chapter.title,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : null,
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
