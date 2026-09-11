import 'package:flutter/material.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/novel_cover_card.dart';

/// Uses the same card grid, tabs and color scheme as the Wenku8 catalogue.
class ShelfCatalogPage extends StatefulWidget {
  const ShelfCatalogPage({super.key, required this.mode});
  final String mode;
  @override
  State<ShelfCatalogPage> createState() => _ShelfCatalogPageState();
}

class _ShelfCatalogPageState extends State<ShelfCatalogPage> {
  api.PageStatsNovelCover? _page;
  List<Map> _categories = [];
  int? _category;
  int _days = 7;
  bool _loading = false;
  String? _error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    final number = more ? _page!.currentPage + 1 : 1;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _page = null;
    });
    try {
      if (widget.mode == 'category' && _categories.isEmpty) {
        final categories = await api.shelfSource.categories();
        if (!mounted || request != _request) return;
        _categories = categories;
      }
      final result =
          widget.mode == 'rank'
              ? await api.shelfSource.rank(_days)
              : await api.shelfSource.list(page: number, category: _category);
      if (!mounted || request != _request) return;
      setState(() {
        _page = api.PageStatsNovelCover(
          currentPage: result.currentPage,
          maxPage: result.maxPage,
          records: [...(more ? _page?.records ?? [] : []), ...result.records],
        );
        _loading = false;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.mode == 'category')
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _category == null,
                onSelected: (_) {
                  _category = null;
                  _load();
                },
              ),
              ..._categories.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoiceChip(
                    label: Text('${c['Name']}'),
                    selected: _category == c['Id'],
                    onSelected: (_) {
                      _category = c['Id'] as int;
                      _load();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      if (widget.mode == 'rank')
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('日榜')),
              ButtonSegment(value: 7, label: Text('周榜')),
              ButtonSegment(value: 31, label: Text('月榜')),
            ],
            selected: {_days},
            onSelectionChanged: (s) {
              _days = s.first;
              _load();
            },
          ),
        ),
      if (widget.mode == 'all')
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('轻书架按分卷收录，此处展示全部书籍'),
        ),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(_error!, textAlign: TextAlign.center),
              TextButton(
                onPressed: () => _load(more: _page != null),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      Expanded(
        child:
            _page == null
                ? const SizedBox.shrink()
                : _page!.records.isEmpty
                ? const Center(child: Text('暂无书籍'))
                : RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const BookGridDelegate(
                      childAspectRatio: 207 / 307,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _page!.records.length,
                    itemBuilder:
                        (_, i) => NovelCoverCard(novel: _page!.records[i]),
                  ),
                ),
      ),
      if (_page != null && _page!.currentPage < _page!.maxPage)
        TextButton(
          onPressed: _loading ? null : () => _load(more: true),
          child: const Text('加载更多'),
        ),
    ],
  );
}
