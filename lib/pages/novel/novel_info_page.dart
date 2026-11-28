import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/android_detail_insets.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_top_bar_backdrop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/wenku8_recovery_button.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'package:wild/sources/book_source.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/widgets/book_details_view.dart';
import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/models/book_detail_hint.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/search_page.dart';
import 'package:wild/widgets/cf_action_loader.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/pages/shelf_login_page.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/material_you.dart';

import 'novel_info_cubit.dart';
import 'reader_route.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/services/reader_listening_chapter.dart';

const novelInfoRouteName = '/novel/info';

PageRoute<void> novelInfoRoute(RouteSettings settings) =>
    HorizontalCoverPageRoute<void>(
      settings: settings,
      builder: (_) {
        final args = settings.arguments;
        final page = NovelInfoPage(
          novelId:
              args is Map<String, dynamic>
                  ? args['novelId'] as String
                  : args as String,
          listening:
              args is Map<String, dynamic>
                  ? args['listening'] as ReaderListeningRequest?
                  : null,
        );
        return usesMaterialYou ? AndroidDetailInsets(child: page) : page;
      },
    );

bool _isCfError(dynamic e) {
  return shouldUseWenku8WebViewFallback(e);
}

class NovelInfoPage extends StatelessWidget {
  final String novelId;
  final ReaderListeningRequest? listening;

  const NovelInfoPage({super.key, required this.novelId, this.listening});

  @override
  Widget build(BuildContext context) {
    if (!supportsLocalEpub && novelId.startsWith('epub:')) {
      return Scaffold(
        appBar: AppBar(title: const Text('小说详情')),
        body: const Center(child: Text('此设备无法打开本地 EPUB')),
      );
    }
    Future<void> navigateToDownload(BuildContext context) async {
      final state = context.read<NovelInfoCubit>().state;
      if (state is! NovelInfoLoaded) return;

      try {
        final downloadInfo = await w8.existsDownload(novelId: novelId);
        if (!context.mounted) return;

        await Navigator.pushNamed(
          context,
          '/novel/downloading',
          arguments: {
            'novelId': novelId,
            'existsDownload': downloadInfo,
            'novelInfo': state.novelInfo,
            'volumes': state.volumes,
          },
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取下载信息失败: $e')));
      }
    }

    return BlocProvider(
      create: (context) => NovelInfoCubit(novelId)..load(),
      child: _IosNovelInfoScaffold(
        novelId: novelId,
        listening: listening,
        onDownload: navigateToDownload,
      ),
    );
  }
}

class _IosNovelInfoScaffold extends StatelessWidget {
  const _IosNovelInfoScaffold({
    required this.novelId,
    required this.listening,
    required this.onDownload,
  });

  final String novelId;
  final ReaderListeningRequest? listening;
  final Future<void> Function(BuildContext context) onDownload;

  @override
  Widget build(BuildContext context) {
    final apple = usesAppleGlass;
    final bodyContent = _ListeningDetailEntry(
      request: listening,
      child: BlocBuilder<NovelInfoCubit, NovelInfoState>(
        buildWhen: (previous, current) {
          if (previous is NovelInfoLoaded && current is NovelInfoLoaded) {
            return !identical(previous.novelInfo, current.novelInfo) ||
                !identical(previous.volumes, current.volumes) ||
                previous.readingHistory?.chapterId !=
                    current.readingHistory?.chapterId;
          }
          return true;
        },
        builder: (context, state) {
          if (state is NovelInfoLoading || state is NovelInfoLoaded) {
            return _NovelInfoContent(novelId: novelId, state: state);
          }
          if (state is NovelInfoError) {
            final topInset = apple ? MediaQuery.paddingOf(context).top : 0.0;
            if (state.loginRequired) {
              return Padding(
                padding: EdgeInsets.only(top: topInset),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(state.message, textAlign: TextAlign.center),
                        SourceWebsiteLink(source: sourceOf(novelId)),
                        const SizedBox(height: 16),
                        AppButton.filled(
                          onPressed: () async {
                            final loggedIn = await Navigator.of(
                              context,
                            ).push<bool>(
                              HorizontalCoverPageRoute(
                                builder: (_) => const ShelfLoginPage(),
                              ),
                            );
                            if (loggedIn == true && context.mounted) {
                              context.read<NovelInfoCubit>().load();
                            }
                          },
                          child: const Text('登录轻书架'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return Padding(
              padding: EdgeInsets.only(top: topInset),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '加载失败: ${state.message}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      AppButton.filledIcon(
                        onPressed: () => context.read<NovelInfoCubit>().load(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新加载'),
                      ),
                      SourceWebsiteLink(source: sourceOf(novelId)),
                      Wenku8RecoveryButton(
                        error: state.cause ?? state.message,
                        source: sourceOf(novelId),
                        onRecovered:
                            () => context.read<NovelInfoCubit>().load(),
                      ),
                      BiliRecoveryButton(
                        error: state.cause,
                        source: sourceOf(novelId),
                        onRecovered:
                            () => context.read<NovelInfoCubit>().load(),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );

    return IosTopBarScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('小说详情', maxLines: 1),
        centerTitle: apple ? true : null,
        backgroundColor: apple ? Colors.transparent : null,
        surfaceTintColor: apple ? Colors.transparent : null,
        scrolledUnderElevation: apple ? 0 : null,
        leadingWidth: apple ? 60 : null,
        leading:
            apple && (ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
                ? Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16),
                  child: Center(
                    child: IosReaderBackButton(
                      onPressed: () => Navigator.maybePop(context),
                      keepGlassInSheets: true,
                      keepGlassInHorizontalCover: true,
                    ),
                  ),
                )
                : null,
        actions: [
          BlocBuilder<NovelInfoCubit, NovelInfoState>(
            buildWhen: _detailActionsChanged,
            builder: (context, state) {
              if (state is! NovelInfoLoaded) return const SizedBox.shrink();
              final wenku8 = sourceOf(novelId) == SourceId.wenku8;
              final actionColor =
                  apple ? Theme.of(context).colorScheme.onSurface : null;
              final hasComments = w8.sourceSupportsComments(novelId);
              final tags = BookDetailTagsButton(
                tags: state.novelInfo.tags,
                color: actionColor,
                iconSize: apple ? AppleGlassActions.defaultIconSize : null,
                onTag:
                    wenku8
                        ? (tag) => Navigator.pushNamed(
                          context,
                          '/category',
                          arguments: {'tag': tag},
                        )
                        : null,
              );
              final hasTags = state.novelInfo.tags.any(
                (tag) => tag.trim().isNotEmpty,
              );
              void openComments() => Navigator.pushNamed(
                context,
                '/novel/reviews',
                arguments: {'aid': novelId, 'title': state.novelInfo.title},
              );
              void download() => onDownload(context);
              final actions = [
                if (hasTags) tags,
                if (hasComments)
                  AppIconButton(
                    key: const ValueKey('detail-comments'),
                    tooltip: '书评',
                    color: actionColor,
                    iconSize: apple ? AppleGlassActions.defaultIconSize : null,
                    icon: Icon(
                      apple
                          ? CupertinoIcons.chat_bubble
                          : Icons.chat_bubble_outline_rounded,
                    ),
                    onPressed: openComments,
                  ),
                if (wenku8)
                  AppIconButton(
                    color: actionColor,
                    iconSize: apple ? AppleGlassActions.defaultIconSize : null,
                    icon: Icon(
                      apple
                          ? CupertinoIcons.arrow_down_to_line
                          : Icons.download_outlined,
                    ),
                    tooltip: '离线下载',
                    onPressed: download,
                  ),
              ];
              if (actions.isEmpty) return const SizedBox.shrink();
              final buttons = Row(
                mainAxisSize: MainAxisSize.min,
                children: actions,
              );
              if (!apple) return buttons;
              return Padding(
                padding: const EdgeInsetsDirectional.only(end: 16),
                child: Center(
                  child: AppleGlassActions(
                    keepGlassInSheets: true,
                    keepGlassInHorizontalCover: true,
                    actions: [
                      if (hasTags)
                        AppleGlassAction(
                          id: 'tags',
                          label: '书籍标签',
                          symbol: 'tag',
                          fallbackIcon: CupertinoIcons.tag,
                          onPressed: () => tags.showTags(context),
                        ),
                      if (hasComments)
                        AppleGlassAction(
                          id: 'comments',
                          label: '书评',
                          symbol: 'bubble.left',
                          fallbackIcon: CupertinoIcons.chat_bubble,
                          onPressed: openComments,
                        ),
                      if (wenku8)
                        AppleGlassAction(
                          id: 'download',
                          label: '离线下载',
                          symbol: 'arrow.down.to.line',
                          fallbackIcon: CupertinoIcons.arrow_down_to_line,
                          onPressed: download,
                        ),
                    ],
                    fallback: buttons,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: bodyContent,
    );
  }
}

class _ListeningDetailEntry extends StatefulWidget {
  const _ListeningDetailEntry({required this.request, required this.child});
  final ReaderListeningRequest? request;
  final Widget child;

  @override
  State<_ListeningDetailEntry> createState() => _ListeningDetailEntryState();
}

class _ListeningDetailEntryState extends State<_ListeningDetailEntry> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final request = widget.request;
    if (_started || request == null) return;
    _started = true;
    final scope = bookNavigationScope(request.chapter.aid);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !await waitForPageArrival(context) ||
          !mounted ||
          scope != bookNavigationScope(request.chapter.aid)) {
        return;
      }
      final cubit = context.read<NovelInfoCubit>();
      await openReaderListening(
        context,
        request,
        onPosition: cubit.acceptListeningPosition,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

bool _detailActionsChanged(NovelInfoState previous, NovelInfoState current) {
  if (previous is NovelInfoLoaded && current is NovelInfoLoaded) {
    return !identical(previous.novelInfo, current.novelInfo);
  }
  return (previous is NovelInfoLoaded) != (current is NovelInfoLoaded);
}

class _NovelInfoContent extends StatelessWidget {
  final String novelId;
  final NovelInfoState state;

  const _NovelInfoContent({required this.novelId, required this.state});

  Future<void> _navigateToReader(
    BuildContext context,
    String novelId,
    String chapterId,
    String title,
  ) async {
    final currentState = context.read<NovelInfoCubit>().state;
    if (currentState is! NovelInfoLoaded) return;

    // 获取阅读历史中的页码
    int? initialPage;
    if (currentState.readingHistory != null &&
        currentState.readingHistory!.chapterId == chapterId) {
      initialPage = currentState.readingHistory!.progressPage;
    }

    if (ModalRoute.of(context)?.isCurrent == false) return;
    final cubit = context.read<NovelInfoCubit>();
    final scope = bookNavigationScope(novelId);
    var listened = false;
    await pushNovelReader(
      context,
      RouteSettings(
        name: novelReaderRouteName,
        arguments: {
          'novelId': novelId,
          'chapterId': chapterId,
          'title': title,
          'volumes': currentState.volumes,
          'novelInfo': currentState.novelInfo,
          'initialPage': initialPage,
          if ((novelId.startsWith('epub:') ||
                  initialPage == scrollReaderProgressPage) &&
              currentState.readingHistory?.chapterId == chapterId)
            'initialTextOffset': currentState.readingHistory!.progress,
        },
      ),
      onListeningPosition: (progress) {
        listened = true;
        cubit.acceptListeningPosition(progress);
      },
    );
    if (!listened &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent != false &&
        scope == bookNavigationScope(novelId)) {
      await cubit.loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    final source = sourceOf(novelId);
    final key = ValueKey('book-details-$novelId');
    final hint = BookDetailHint.lookup(novelId);
    if (state is! NovelInfoLoaded) {
      return BookDetailsView.loading(
        key: key,
        source: source,
        hint: hint,
        loading: SourceLoadingIndicator(source: source, requestKey: state),
      );
    }
    final novelInfo = state.novelInfo;
    final inShelf = context.select<BookshelfCubit, bool>(
      (cubit) => cubit.state.isBookInBookshelf(novelId),
    );
    return BookDetailsView(
      key: key,
      info: novelInfo,
      hint: hint,
      volumes: state.volumes,
      source: source,
      resumeChapterId: state.readingHistory?.chapterId,
      inShelf: inShelf,
      onBookmark:
          source == SourceId.localEpub
              ? null
              : () => _toggleBookShelf(context, novelId),
      onComments:
          w8.sourceSupportsComments(novelId)
              ? () => Navigator.pushNamed(
                context,
                '/novel/reviews',
                arguments: {'aid': novelId, 'title': novelInfo.title},
              )
              : null,
      onAuthor:
          w8.sourceSupportsAuthorSearch(source) &&
                  novelInfo.author.trim().isNotEmpty
              ? () async {
                if (ModalRoute.of(context)?.isCurrent == false) return;
                final cubit = context.read<NovelInfoCubit>();
                final scope = bookNavigationScope(novelId);
                await pushAndWaitForPageExit(
                  context,
                  HorizontalCoverPageRoute<void>(
                    settings: RouteSettings(
                      name: '/search',
                      arguments: {
                        'searchType': 'author',
                        'searchKey': novelInfo.author,
                      },
                    ),
                    builder:
                        (_) => SearchPage(
                          initialSearchType: 'author',
                          initialSearchKey: novelInfo.author,
                        ),
                  ),
                );
                if (context.mounted &&
                    ModalRoute.of(context)?.isCurrent != false &&
                    scope == bookNavigationScope(novelId)) {
                  await cubit.loadHistory();
                }
              }
              : null,
      onRead:
          (chapter) => _navigateToReader(
            context,
            chapter.aid,
            chapter.cid,
            novelInfo.title,
          ),
    );
  }
}

Future<void> _toggleBookShelf(BuildContext context, String novelId) async {
  final bookshelfCubit = context.read<BookshelfCubit>();
  final isInBookshelf = bookshelfCubit.state.isBookInBookshelf(novelId);

  try {
    if (isInBookshelf) {
      await bookshelfCubit.removeFromBookshelf(novelId);
    } else {
      await bookshelfCubit.addToBookshelf(novelId);
    }
  } catch (e) {
    if (!context.mounted) return;
    if (_isCfError(e)) {
      final apiHost = context.read<ApiHostCubit>().state;
      String actionPath;
      if (isInBookshelf) {
        final bid = bookshelfCubit.state.getBookBid(novelId);
        if (bid == null) return;
        actionPath = '/modules/article/bookcase.php?delid=$bid';
      } else {
        actionPath = '/modules/article/addbookcase.php?bid=$novelId';
      }
      showAdaptiveDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (ctx) => Dialog.fullscreen(
              child: CfActionLoader(
                apiHost: apiHost,
                actionPath: actionPath,
                successUrlKeyword: 'bookcase.php',
                successBodyKeyword: '处理成功',
                onSuccess: () {
                  Navigator.of(ctx).pop();
                  bookshelfCubit.loadBookcases();
                },
                onError: (err) {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('操作失敗: $err')));
                },
              ),
            ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败: $e')));
    }
  }
}
