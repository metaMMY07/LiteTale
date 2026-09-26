import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/light_novel_shelf_browser_page.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/src/rust/wenku8/models.dart' as w8;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/novel_cover_card.dart';
import 'package:wild/widgets/novel_card.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

import 'recommend_cubit.dart';

class RecommendPage extends StatelessWidget {
  const RecommendPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => RecommendCubit(loadShelf: (_) async => [])..load(),
      child: Scaffold(
        body: BlocBuilder<RecommendCubit, RecommendState>(
          builder: (context, state) {
            if (state is RecommendLoading) {
              return const CenteredLoadingIndicator();
            }
            if (state is RecommendError) {
              return Center(child: Text('加载失败: ${state.message}'));
            }
            if (state is RecommendLoaded) {
              return RefreshIndicator(
                onRefresh:
                    () =>
                        context.read<RecommendCubit>().load(forceRefresh: true),
                child: RecommendationFeed(
                  blocks: state.blocks,
                  lightNovelShelfBooks: state.lightNovelShelfBooks,
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

/// One viewport keeps offscreen covers out of layout and image decoding.
class RecommendationFeed extends StatelessWidget {
  const RecommendationFeed({
    super.key,
    required this.blocks,
    this.lightNovelShelfBooks = const [],
  });

  final List<w8.HomeBlock> blocks;
  final List<LightNovelShelfBook> lightNovelShelfBooks;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (lightNovelShelfBooks.isNotEmpty)
          ..._LightNovelShelfBlock.slivers(context, lightNovelShelfBooks),
        for (final block in blocks) ..._HomeBlockWidget.slivers(context, block),
      ],
    );
  }
}

class _LightNovelShelfBlock {
  static void _open(BuildContext context, String url, String title) {
    Navigator.of(context).push(
      HorizontalCoverPageRoute<void>(
        builder:
            (_) => LightNovelShelfBrowserPage(initialUrl: url, title: title),
      ),
    );
  }

  static List<Widget> slivers(
    BuildContext context,
    List<LightNovelShelfBook> books,
  ) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '轻书架近期录入',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed:
                    () => _open(
                      context,
                      LightNovelShelfService.catalogUrl,
                      '轻书架',
                    ),
                child: const Text('更多'),
              ),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '来自轻书架 · 详情与阅读需该站账号',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid.builder(
          gridDelegate: BookGridDelegate(
            sectionItemCount: books.length,
            childAspectRatio: 207 / 330,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            return NovelCard(
              title: book.title,
              coverUrl: book.coverUrl,
              source: SourceId.lightNovelShelf,
              author: book.subtitle,
              onTap: () => _open(context, book.webUrl, book.title),
            );
          },
        ),
      ),
    ];
  }
}

class _HomeBlockWidget {
  static List<Widget> slivers(BuildContext context, w8.HomeBlock block) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            block.title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid.builder(
          gridDelegate: BookGridDelegate(
            sectionItemCount: block.list.length,
            childAspectRatio: 207 / 307,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: block.list.length,
          itemBuilder: (context, index) {
            final novel = block.list[index];
            return NovelCoverCard(novel: novel);
          },
        ),
      ),
    ];
  }
}
