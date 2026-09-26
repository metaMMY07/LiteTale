import 'package:flutter/material.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/sources/source_api.dart';
import '../widgets/novel_cover_card.dart';

typedef NovelSearch =
    Future<PageStatsNovelCover> Function({
      required String searchType,
      required String searchKey,
      required int page,
    });

class SearchPage extends StatefulWidget {
  final String? initialSearchType;
  final String? initialSearchKey;
  final NovelSearch? searcher;
  final Future<List<SearchHistory>> Function()? historyLoader;

  const SearchPage({
    super.key,
    this.initialSearchType,
    this.initialSearchKey,
    this.searcher,
    this.historyLoader,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _searchController = TextEditingController();
  late String _searchType;
  PageStatsNovelCover? _results;
  List<SearchHistory> _histories = [];
  bool _loading = false;
  String? _error;
  int _request = 0;
  String _submittedKey = '';
  String _submittedType = '';

  @override
  void initState() {
    super.initState();
    _searchType =
        widget.initialSearchType == 'author' &&
                activeSource.value != SourceId.lnovel
            ? 'author'
            : 'articlename';
    _searchController.text = widget.initialSearchKey ?? '';
    activeSource.addListener(_sourceChanged);
    sourceRevision.addListener(_sourceChanged);
    _loadHistories();
    if (_searchController.text.trim().isNotEmpty) _search();
  }

  @override
  void dispose() {
    activeSource.removeListener(_sourceChanged);
    sourceRevision.removeListener(_sourceChanged);
    _request++;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistories() async {
    final source = activeSource.value;
    final revision = sourceRevision.value;
    try {
      final values = await (widget.historyLoader ?? searchHistories)();
      if (mounted &&
          source == activeSource.value &&
          revision == sourceRevision.value) {
        setState(() => _histories = values);
      }
    } catch (_) {}
  }

  void _sourceChanged() {
    _searchController.clear();
    _searchType = 'articlename';
    _histories = [];
    _resetQuery();
    _loadHistories();
  }

  void _resetQuery() {
    _request++;
    setState(() {
      _loading = false;
      _results = null;
      _error = null;
    });
  }

  Future<void> _search({bool more = false}) async {
    final key = _searchController.text.trim();
    if (key.isEmpty) {
      _resetQuery();
      return;
    }
    if (more &&
        (_loading ||
            _results == null ||
            _results!.currentPage >= _results!.maxPage ||
            key != _submittedKey ||
            _searchType != _submittedType)) {
      return;
    }
    final type = _searchType;
    if (!more && _loading && key == _submittedKey && type == _submittedType) {
      return;
    }
    final page = more ? _results!.currentPage + 1 : 1;
    final request = ++_request;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _results = null;
      _submittedKey = key;
      _submittedType = type;
    });
    try {
      final result = await (widget.searcher ?? search)(
            searchType: type,
            searchKey: key,
            page: page,
          )
          .timeout(
            const Duration(seconds: 135),
            onTimeout: () => throw Exception('搜索超时，请检查网络后重试'),
          );
      if (!mounted || request != _request) return;
      setState(() {
        final records =
            more ? [..._results!.records, ...result.records] : result.records;
        final seen = <String>{};
        _results = PageStatsNovelCover(
          currentPage: result.currentPage,
          maxPage: result.maxPage,
          records: records.where((book) => seen.add(book.aid)).toList(),
        );
        _loading = false;
      });
      _loadHistories();
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Widget _body() {
    if (_loading && _results == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExpressiveLoadingIndicator(),
            SizedBox(height: 20),
            Text('正在搜索，请稍候…'),
            SizedBox(height: 8),
            Text('首次搜索可能需要较长时间'),
          ],
        ),
      );
    }
    if (_error != null && _results == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 40),
              const SizedBox(height: 16),
              const Text('搜索未完成'),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _search,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_results != null) {
      if (_results!.records.isEmpty && activeSource.value != SourceId.lnovel) {
        return const Center(child: Text('没有找到相关书籍，试试其他关键词'));
      }
      return Column(
        children: [
          if (activeSource.value == SourceId.lnovel)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '已查找目录第 ${_results!.currentPage} 页 · ${_results!.records.length} 本匹配\n'
                '${_results!.currentPage < _results!.maxPage ? '可继续查找后续目录' : '已到目录末页'}',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (activeSource.value != SourceId.lnovel &&
                    notification is ScrollEndNotification &&
                    notification.metrics.extentAfter < 200 &&
                    _error == null) {
                  _search(more: true);
                }
                return false;
              },
              child: GridView.builder(
                key: ValueKey('$_submittedType:$_submittedKey'),
                padding: const EdgeInsets.all(12),
                gridDelegate: const BookGridDelegate(
                  childAspectRatio: 207 / 307,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _results!.records.length,
                itemBuilder:
                    (context, i) => NovelCoverCard(novel: _results!.records[i]),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (!_loading && _results!.currentPage < _results!.maxPage)
            TextButton(
              onPressed: () => _search(more: true),
              child: Text(
                _error == null
                    ? (activeSource.value == SourceId.lnovel
                        ? '继续查找下一页目录'
                        : '加载更多')
                    : '加载失败，点击重试',
              ),
            ),
        ],
      );
    }
    if (_searchController.text.trim().isEmpty && _histories.isNotEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _histories.length,
        itemBuilder: (context, i) {
          final history = _histories[i];
          return ListTile(
            leading: Icon(
              history.searchType == 'author'
                  ? Icons.person_outline
                  : Icons.history,
            ),
            title: Text(history.searchKey),
            subtitle: Text(history.searchType == 'author' ? '作者搜索' : '书名搜索'),
            onTap: () {
              _searchController.text = history.searchKey;
              _searchType = history.searchType;
              _search();
            },
          );
        },
      );
    }
    return const Center(child: Text('输入关键词，点击搜索或键盘上的搜索键'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('搜索')),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          if (activeSource.value == SourceId.lnovel)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('原站搜索暂不可用，按目录逐页查找书名。请使用繁体关键词。'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: _searchType == 'author' ? '输入作者名' : '输入书名',
                prefixIcon: IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
                suffixIcon: IconButton(
                  tooltip: '执行搜索',
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: _search,
                ),
              ),
              onChanged: (_) => _resetQuery(),
              onSubmitted: (_) => _search(),
            ),
          ),
          if (MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom >
              280)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(value: 'articlename', label: Text('书名')),
                  ButtonSegment(
                    value: 'author',
                    label: const Text('作者'),
                    enabled: activeSource.value != SourceId.lnovel,
                  ),
                ],
                selected: {_searchType},
                onSelectionChanged: (selection) {
                  _searchType = selection.first;
                  _resetQuery();
                },
              ),
            ),
          const SizedBox(height: 12),
          Expanded(child: _body()),
        ],
      ),
    ),
  );
}
