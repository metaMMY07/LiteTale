import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/sources/book_source.dart';
import 'package:flutter/material.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/novel_cover_card.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/bili_recovery_button.dart';
import 'package:wild/sources/rule_book_source.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

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
  Object? _error;
  bool _errorMore = false;
  int _request = 0;
  final _source = activeSource.value;
  @override
  void initState() {
    super.initState();
    if (_source == SourceId.bili) _days = 31;
    _load();
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    final revision = sourceRevision.value;
    bool currentBiliRequest() =>
        mounted &&
        request == _request &&
        _source == SourceId.bili &&
        activeSource.value == SourceId.bili &&
        sourceRevision.value == revision;
    final number = more ? _page!.currentPage + 1 : 1;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _page = null;
    });
    try {
      if (_source == SourceId.bili) {
        if (widget.mode == 'category') {
          _categories =
              api.biliSource
                  .categories()
                  .map((c) => {'Id': c.id, 'Name': c.name})
                  .toList();
        }
        final result = await api.biliSource.listPage(
          number,
          mode:
              widget.mode == 'category' && _category == null
                  ? 'all'
                  : widget.mode,
          category: _category,
          rank: _days == 7 ? 'weekvisit' : 'monthvisit',
        );
        if (!currentBiliRequest()) return;
        setState(() {
          _page = api.PageStatsNovelCover(
            currentPage: result.currentPage,
            maxPage: result.maxPage,
            records: [...(more ? _page?.records ?? [] : []), ...result.records],
          );
          _loading = false;
        });
        return;
      }
      if (_source.isRule) {
        if (widget.mode != 'all') {
          setState(() {
            _loading = false;
            _error =
                '此书源未提供${widget.mode == 'rank' ? '排行' : '分类'}，请使用“推荐”或“全部”浏览。';
          });
          return;
        }
        final result = await (api.sourceAdapter(_source) as RuleBookSource)
            .listPage(number);
        if (!mounted || request != _request) return;
        setState(() {
          _page = api.PageStatsNovelCover(
            currentPage: result.currentPage,
            maxPage: result.maxPage,
            records: [...(more ? _page?.records ?? [] : []), ...result.records],
          );
          _loading = false;
        });
        return;
      }
      if (widget.mode == 'category' && _categories.isEmpty) {
        final categories =
            await (_source == SourceId.lnovel
                ? api.lnovelSource.categories()
                : api.shelfSource.categories());
        if (!mounted || request != _request) return;
        _categories = categories;
      }
      final result =
          _source == SourceId.lnovel
              ? await api.lnovelSource.list(
                page: number,
                category: _category,
                popular: widget.mode == 'rank',
              )
              : widget.mode == 'rank'
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
        if (_source == SourceId.bili && !currentBiliRequest()) return;
        setState(() {
          _loading = false;
          _error = _source == SourceId.bili ? e : e.toString();
          _errorMore = more;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.mode == 'category')
        if (usesAppleGlass)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppleGlassMenu(
                label: '分类',
                selected: _category?.toString() ?? 'all',
                items: [
                  const {'label': '全部', 'value': 'all'},
                  for (final category in _categories)
                    {
                      'label': '${category['Name']}',
                      'value': '${category['Id']}',
                    },
                ],
                onSelect: (value) {
                  _category = value == 'all' ? null : int.tryParse(value);
                  _load();
                },
              ),
            ),
          )
        else
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
      if (widget.mode == 'rank' && _source == SourceId.lightNovelShelf)
        if (usesAppleGlass)
          AppleGlassFilterBar(
            labels: const ['日榜', '周榜', '月榜'],
            index: const [1, 7, 31].indexOf(_days),
            onSelect: (index) {
              _days = const [1, 7, 31][index];
              _load();
            },
          )
        else
          Padding(
            padding: const EdgeInsets.all(12),
            child: AppSegmentedButton<int>(
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
      if (widget.mode == 'rank' && _source == SourceId.lnovel)
        const Padding(padding: EdgeInsets.all(12), child: Text('按原站阅读人气排序')),
      if (_source == SourceId.bili && widget.mode == 'rank')
        if (usesAppleGlass)
          AppleGlassFilterBar(
            labels: const ['周点击榜', '月点击榜'],
            index: _days == 31 ? 1 : 0,
            onSelect: (index) {
              _days = index == 1 ? 31 : 7;
              _load();
            },
          )
        else
          Padding(
            padding: const EdgeInsets.all(12),
            child: AppSegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 7, label: Text('周点击榜')),
                ButtonSegment(value: 31, label: Text('月点击榜')),
              ],
              selected: {_days},
              onSelectionChanged: (selection) {
                _days = selection.first;
                _load();
              },
            ),
          ),
      if (widget.mode == 'all' && _source == SourceId.lightNovelShelf)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('轻书架按分卷收录，此处展示全部书籍'),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(_error!.toString(), textAlign: TextAlign.center),
              BiliRecoveryButton(
                error: _error,
                source: _source,
                onRecovered: () => _load(more: _errorMore),
              ),
              AppButton.text(
                onPressed: () => _load(more: _page != null),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      Expanded(
        child:
            _loading && _page == null
                ? const CenteredLoadingIndicator()
                : _page == null
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
      if (_loading && _page != null)
        const SizedBox(
          height: 48,
          child: Center(child: AppLoadingIndicator(size: 24)),
        ),
      if (!_loading && _page != null && _page!.currentPage < _page!.maxPage)
        AppButton.text(
          onPressed: _loading ? null : () => _load(more: true),
          child: const Text('加载更多'),
        ),
    ],
  );
}
