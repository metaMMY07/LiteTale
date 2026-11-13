import 'package:wild/widgets/platform_controls.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/wenku8_recovery_button.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'package:wild/sources/book_source.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/widgets/book_details_view.dart';
import 'package:wild/models/book_detail_hint.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/search_page.dart';
import 'package:wild/widgets/cf_action_loader.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/pages/shelf_login_page.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

import 'novel_info_cubit.dart';
import 'reader_route.dart';
import 'package:wild/services/reading_progress.dart';

const novelInfoRouteName = '/novel/info';

PageRoute<void> novelInfoRoute(RouteSettings settings) =>
    HorizontalCoverPageRoute<void>(
      settings: settings,
      builder: (_) {
        final args = settings.arguments;
        return NovelInfoPage(
          novelId:
              args is Map<String, dynamic>
                  ? args['novelId'] as String
                  : args as String,
        );
      },
    );

bool _isCfError(dynamic e) {
  return shouldUseWenku8WebViewFallback(e);
}

class NovelInfoPage extends StatelessWidget {
  final String novelId;

  const NovelInfoPage({super.key, required this.novelId});

  @override
  Widget build(BuildContext context) {
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
      child: Scaffold(
        appBar: AppBar(
          title: const Text('小说详情'),
          actions: [
            if (w8.sourceSupportsComments(novelId))
              BlocBuilder<NovelInfoCubit, NovelInfoState>(
                buildWhen: _detailActionsChanged,
                builder: (context, state) {
                  if (state is! NovelInfoLoaded) return const SizedBox.shrink();
                  return AppIconButton(
                    key: const ValueKey('detail-comments'),
                    tooltip: '书评',
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    onPressed:
                        () => Navigator.pushNamed(
                          context,
                          '/novel/reviews',
                          arguments: {
                            'aid': novelId,
                            'title': state.novelInfo.title,
                          },
                        ),
                  );
                },
              ),
            if (sourceOf(novelId) == SourceId.wenku8)
              BlocBuilder<NovelInfoCubit, NovelInfoState>(
                buildWhen: _detailActionsChanged,
                builder: (context, state) {
                  if (state is! NovelInfoLoaded) {
                    return const SizedBox.shrink();
                  }
                  return AppIconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip:
                        sourceOf(novelId) == SourceId.wenku8
                            ? '离线下载'
                            : '此书源暂不支持离线下载',
                    onPressed:
                        sourceOf(novelId) == SourceId.wenku8
                            ? () => navigateToDownload(context)
                            : null,
                  );
                },
              ),
          ],
        ),
        body: BlocBuilder<NovelInfoCubit, NovelInfoState>(
          builder: (context, state) {
            if (state is NovelInfoLoading || state is NovelInfoLoaded) {
              return _NovelInfoContent(novelId: novelId, state: state);
            }
            if (state is NovelInfoError) {
              if (state.loginRequired) {
                return Center(
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
                );
              }
              return Center(
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
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

bool _detailActionsChanged(NovelInfoState previous, NovelInfoState current) {
  if (previous is NovelInfoLoaded && current is NovelInfoLoaded) {
    return previous.novelInfo.title != current.novelInfo.title;
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
    await pushAndWaitForPageExit(
      context,
      novelReaderRoute(
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
      ),
    );
    if (context.mounted &&
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
      onTag:
          source == SourceId.wenku8
              ? (tag) => Navigator.pushNamed(
                context,
                '/category',
                arguments: {'tag': tag},
              )
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
