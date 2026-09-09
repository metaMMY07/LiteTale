import 'package:flutter/material.dart';
import 'package:wild/theme/material_you.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/light_novel_shelf_browser_page.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/src/rust/wenku8/models.dart' as w8;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/novel_cover_card.dart';
import 'package:wild/widgets/novel_card.dart';

import 'recommend_cubit.dart';

class RecommendPage extends StatelessWidget {
  const RecommendPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create:
          (context) => RecommendCubit(
            loadShelf: usesMaterialYou ? (_) async => [] : null,
          )..load(),
      child: Scaffold(
        body: BlocBuilder<RecommendCubit, RecommendState>(
          builder: (context, state) {
            if (state is RecommendLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is RecommendError) {
              return Center(child: Text('加载失败: ${state.message}'));
            }
            if (state is RecommendLoaded) {
              return RefreshIndicator(
                onRefresh:
                    () =>
                        context.read<RecommendCubit>().load(forceRefresh: true),
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount:
                      state.blocks.length +
                      (state.lightNovelShelfBooks.isEmpty ? 0 : 1),
                  itemBuilder: (context, index) {
                    final hasShelfBooks = state.lightNovelShelfBooks.isNotEmpty;
                    if (hasShelfBooks && index == 0) {
                      return _LightNovelShelfBlock(
                        books: state.lightNovelShelfBooks,
                      );
                    }
                    final block = state.blocks[index - (hasShelfBooks ? 1 : 0)];
                    return _HomeBlockWidget(block: block);
                  },
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

class _LightNovelShelfBlock extends StatelessWidget {
  const _LightNovelShelfBlock({required this.books});

  final List<LightNovelShelfBook> books;

  void _open(BuildContext context, String url, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => LightNovelShelfBrowserPage(initialUrl: url, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '来自轻书架 · 详情与阅读需该站账号',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
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
                author: book.subtitle,
                onTap: () => _open(context, book.webUrl, book.title),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HomeBlockWidget extends StatelessWidget {
  final w8.HomeBlock block;

  const _HomeBlockWidget({required this.block});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            block.title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
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
      ],
    );
  }
}
