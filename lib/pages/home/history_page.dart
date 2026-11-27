import 'package:wild/widgets/book_cover_image.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/ios_solid_surface.dart';
import 'package:wild/widgets/ios_top_bar_backdrop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/sources/source_api.dart' as w8;
import 'package:wild/sources/book_source.dart';
import 'package:wild/services/read_request.dart';
import 'package:intl/intl.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/theme/ios_dock_insets.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/pages/novel/novel_info_page.dart';
import 'package:wild/pages/novel/reader_route.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/models/book_detail_hint.dart';

import 'history_cubit.dart';

String historyChapterCapsuleLabel(w8.ReadingHistory history) {
  final title = history.chapterTitle.trim();
  if (title.isNotEmpty) return title;
  if (history.progressPage > 0 &&
      history.progressPage != scrollReaderProgressPage) {
    return '第 ${history.progressPage} 页';
  }
  final cid = history.chapterId.trim();
  if (cid.isNotEmpty) return '章节 $cid';
  return '最近阅读';
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final apple = usesAppleGlass;
    final cubit = context.read<HistoryCubit>();
    final localOnly = context.select((HistoryCubit value) => value.localOnly);
    return IosTopBarScaffold(
      resetKey: localOnly,
      appBar: AppBar(
        title: const Text('阅读历史'),
        backgroundColor: apple ? Colors.transparent : null,
        surfaceTintColor: apple ? Colors.transparent : null,
        scrolledUnderElevation: apple ? 0 : null,
        actions: [
          AppIconButton(
            tooltip: '清空历史',
            icon: Icon(
              apple ? CupertinoIcons.trash : Icons.delete_outline_rounded,
            ),
            onPressed: () async {
              final source = cubit.historySource;
              final confirm = await showAdaptiveDialog<bool>(
                context: context,
                builder:
                    (context) => AlertDialog.adaptive(
                      title: const Text('清空历史'),
                      content: Text('确定要清空${source.label}的阅读历史吗？此操作不可恢复。'),
                      actions: [
                        AppButton.text(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        AppButton.text(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确定'),
                        ),
                      ],
                    ),
              );
              if (confirm == true) {
                await w8.deleteAllHistory(source: source);
                // 重新加载历史
                if (context.mounted) {
                  context.read<HistoryCubit>().load();
                }
              }
            },
          ),
        ],
        bottom:
            supportsLocalEpub
                ? PreferredSize(
                  preferredSize: Size.fromHeight(usesMaterialYou ? 64 : 56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: AppSegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(activeSource.value.label),
                        ),
                        const ButtonSegment(
                          value: true,
                          label: Text('本地 EPUB'),
                        ),
                      ],
                      selected: {localOnly},
                      onSelectionChanged:
                          (selection) => cubit.showLocal(selection.single),
                    ),
                  ),
                )
                : null,
      ),
      body: BlocBuilder<HistoryCubit, HistoryState>(
        builder: (context, state) {
          final topBarInset = apple ? MediaQuery.paddingOf(context).top : 0.0;
          if (state is HistoryLoading) {
            return Padding(
              padding: EdgeInsets.only(top: topBarInset),
              child: const CenteredLoadingIndicator(),
            );
          }
          if (state is HistoryError) {
            return Padding(
              padding: EdgeInsets.only(top: topBarInset),
              child: Center(child: Text('加载失败: ${state.message}')),
            );
          }
          if (state is HistoryLoaded) {
            if (state.histories.isEmpty) {
              return Padding(
                padding: EdgeInsets.only(top: topBarInset),
                child: const Center(child: Text('暂无阅读历史')),
              );
            }
            final indexes = {
              for (var i = 0; i < state.histories.length; i++)
                state.histories[i].novelId: i,
            };
            return RefreshIndicator(
              edgeOffset: topBarInset,
              onRefresh: () => context.read<HistoryCubit>().load(),
              child: ListView.builder(
                cacheExtent: apple ? 160 : null,
                padding:
                    apple
                        ? IosDockInsets.scrollPadding(
                          context,
                          EdgeInsets.only(top: topBarInset + 4, bottom: 12),
                        )
                        : null,
                itemCount: state.histories.length,
                findChildIndexCallback:
                    (key) =>
                        key is ValueKey<String> ? indexes[key.value] : null,
                itemBuilder: (context, index) {
                  final history = state.histories[index];
                  return _HistoryItem(
                    key: ValueKey(history.novelId),
                    history: history,
                  );
                },
              ),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  final w8.ReadingHistory history;

  const _HistoryItem({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    int asMsInt(Object? v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is BigInt) return v.toInt(); // 轉成 int 給 DateTime 用
      if (v is String) return int.parse(v); // 以防是字串
      throw ArgumentError('Unsupported type for timestamp: ${v.runtimeType}');
    }

    final lastReadAt = DateTime.fromMillisecondsSinceEpoch(
      asMsInt(history.lastReadAt),
    );
    final colorScheme = Theme.of(context).colorScheme;
    final historyCubit = context.read<HistoryCubit>();
    Future<void> open(Future<void> Function() navigate) async {
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final scope = bookNavigationScope(history.novelId);
      final source = historyCubit.historySource;
      await navigate();
      if (context.mounted &&
          ModalRoute.of(context)?.isCurrent != false &&
          source == historyCubit.historySource &&
          scope == bookNavigationScope(history.novelId)) {
        await historyCubit.load(keepContent: true);
      }
    }

    return IosSolidCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: usesMaterialYou ? Clip.antiAlias : Clip.none,
      pressFeedback: true,
      child: InkWell(
        onTap: () async {
          BookDetailHint.remember(
            history.novelId,
            history.novelName,
            history.cover,
          );
          await open(
            () => pushAndWaitForPageExit(
              context,
              novelInfoRoute(
                RouteSettings(
                  name: novelInfoRouteName,
                  arguments: history.novelId,
                ),
              ),
            ),
          );
        },
        onLongPress: () {
          showAdaptiveDialog(
            context: context,
            builder:
                (dialogContext) => AlertDialog.adaptive(
                  title: const Text('删除历史记录'),
                  content: Text('确定要删除《${history.novelName}》的阅读历史吗？'),
                  actions: [
                    AppButton.text(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('取消'),
                    ),
                    AppButton.text(
                      onPressed: () async {
                        Navigator.pop(dialogContext);
                        try {
                          await historyCubit.deleteHistory(history.novelId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已删除阅读历史'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('删除失败: $e'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        }
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sourceOf(history.novelId) == SourceId.localEpub &&
                  history.cover.isEmpty)
                Container(
                  width: 80,
                  height: 120,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.menu_book_rounded,
                    color: colorScheme.onPrimaryContainer,
                  ),
                )
              else
                BookCoverImage(
                  url: history.cover,
                  source: sourceOf(history.novelId),
                  width: 80,
                  height: 120,
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.circular(4),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      history.novelName,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '作者：${history.author}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '最后阅读：${dateFormat.format(lastReadAt)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (context) {
                        Future<void> resumeChapter() async {
                          try {
                            final detail = await historyCubit.loadDetail(
                              history.novelId,
                            );
                            final novelInfo = detail.info,
                                volumes = detail.volumes;

                            if (!context.mounted) return;

                            await open(
                              () => pushNovelReader(
                                context,
                                RouteSettings(
                                  name: novelReaderRouteName,
                                  arguments: {
                                    'novelId': history.novelId,
                                    'chapterId': history.chapterId,
                                    'title': history.chapterTitle,
                                    'volumes': volumes,
                                    'novelInfo': novelInfo,
                                    'initialPage': history.progressPage,
                                    if (history.novelId.startsWith('epub:') ||
                                        history.progressPage ==
                                            scrollReaderProgressPage)
                                      'initialTextOffset': history.progress,
                                  },
                                ),
                                fromDetail: false,
                              ),
                            );
                          } catch (e) {
                            if (e is ReadCancelled) return;
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('加载失败: $e'),
                                duration: const Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                                margin: const EdgeInsets.only(bottom: 16),
                              ),
                            );
                          }
                        }

                        if (usesAppleGlass) {
                          final chapterLabel = historyChapterCapsuleLabel(
                            history,
                          );
                          return Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: IosAccentGlassCapsuleButton(
                              key: ValueKey(
                                'history-chapter-capsule-${history.novelId}',
                              ),
                              glassKey: ValueKey(
                                'history-chapter-glass-${history.novelId}',
                              ),
                              label: chapterLabel,
                              minHeight: 36,
                              fontSize: 14,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              semanticsLabel: '继续阅读：$chapterLabel',
                              onPressed: resumeChapter,
                            ),
                          );
                        }

                        return InkWell(
                          onTap: resumeChapter,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer.withValues(
                                alpha: 0.3,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: RichText(
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              text: TextSpan(
                                children: [
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Icon(
                                      Icons.book,
                                      size: 16,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                  const TextSpan(text: ' '),
                                  TextSpan(
                                    text: '继续阅读 - ${history.chapterTitle}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: colorScheme.primary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
