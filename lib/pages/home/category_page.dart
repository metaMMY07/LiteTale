import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/wenku8_recovery_button.dart';
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/src/rust/api/database.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/novel_cover_card.dart';
import 'package:wild/widgets/source_website.dart';
import 'package:wild/theme/material_you.dart';

class CategoryPage extends StatefulWidget {
  final String? initialTag;
  final Future<List<TagGroup>> Function()? tagsLoader;
  final Future<PageStatsNovelCover> Function({
    required String tag,
    required String v,
    required int pageNumber,
  })?
  pageLoader;
  final Future<String> Function(String)? preferenceLoader;
  final Future<void> Function(String, String)? preferenceSaver;

  const CategoryPage({
    super.key,
    this.initialTag,
    this.tagsLoader,
    this.pageLoader,
    this.preferenceLoader,
    this.preferenceSaver,
  });

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  List<TagGroup>? _tagGroups;
  String? _selectedTag;
  String _viewMode = "0"; // 默认按更新查看
  PageStatsNovelCover? _currentPage;
  bool _isLoading = false;
  Object? _tagError;
  Object? _pageError;
  int _tagRequest = 0;
  int _pageRequest = 0;
  int _choiceRevision = 0;
  Future<void> _preferenceWrites = Future.value();
  static const _keyTag = 'category_page_selected_tag';
  static const _keyViewMode = 'category_page_view_mode';

  @override
  void initState() {
    super.initState();
    _selectedTag = widget.initialTag;
    _loadSavedState();
    _loadTags();
  }

  @override
  void dispose() {
    _tagRequest++;
    _pageRequest++;
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final choice = _choiceRevision;
    String savedTag = '', savedMode = '';
    try {
      final values = await Future.wait([
        (widget.preferenceLoader ?? ((key) => loadProperty(key: key)))(_keyTag),
        (widget.preferenceLoader ?? ((key) => loadProperty(key: key)))(
          _keyViewMode,
        ),
      ]).timeout(const Duration(seconds: 2));
      savedTag = values[0];
      savedMode = values[1];
    } catch (_) {
      /* Preferences must not prevent a supplied tag loading. */
    }
    if (!mounted || choice != _choiceRevision) return;
    setState(() {
      _selectedTag ??= savedTag.isEmpty ? null : savedTag;
      if (const {'0', '1', '2', '3'}.contains(savedMode)) _viewMode = savedMode;
    });
    if (_selectedTag case final tag?) await _loadTagPage(tag, refresh: true);
  }

  Future<void> _saveState() {
    final tag = _selectedTag, mode = _viewMode;
    final save =
        widget.preferenceSaver ??
        ((String key, String value) => saveProperty(key: key, value: value));
    // Preserve the user's last choice even if storage completes out of order.
    return _preferenceWrites = _preferenceWrites.then((_) async {
      try {
        if (tag != null) await save(_keyTag, tag);
        await save(_keyViewMode, mode);
      } catch (_) {
        /* Keep the currently selected values on storage failure. */
      }
    });
  }

  Future<void> _loadTags() async {
    final request = ++_tagRequest;
    setState(() => _tagError = null);
    try {
      final groups = await (widget.tagsLoader ?? tags)().timeout(
        const Duration(seconds: 55),
      );
      if (!mounted || request != _tagRequest) return;
      if (groups.isEmpty) throw const FormatException('文库8分类列表为空，请重试。');
      setState(() => _tagGroups = groups);
    } catch (error) {
      if (mounted && request == _tagRequest) setState(() => _tagError = error);
    }
  }

  Future<void> _loadTagPage(String tag, {bool refresh = false}) async {
    if (!refresh &&
        (_isLoading ||
            _currentPage == null ||
            _currentPage!.currentPage >= _currentPage!.maxPage)) {
      return;
    }
    final request = ++_pageRequest;
    final mode = _viewMode;
    final previous = refresh ? null : _currentPage;
    setState(() {
      _isLoading = true;
      _pageError = null;
      if (refresh) _currentPage = null;
    });
    try {
      final page = await (widget.pageLoader ?? tagPage)(
            tag: tag,
            v: mode,
            pageNumber: (previous?.currentPage ?? 0) + 1,
          )
          .timeout(const Duration(seconds: 55));
      if (!mounted || request != _pageRequest) return;
      final seen = <String>{};
      setState(() {
        _currentPage = PageStatsNovelCover(
          currentPage: page.currentPage,
          maxPage: page.maxPage,
          records:
              [
                ...?previous?.records,
                ...page.records,
              ].where((book) => seen.add(book.aid)).toList(),
        );
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _pageRequest) return;
      setState(() {
        _isLoading = false;
        _pageError = error;
      });
    }
  }

  void _changeSelection({String? tag, String? mode}) {
    _choiceRevision++;
    setState(() {
      _selectedTag = tag ?? _selectedTag;
      _viewMode = mode ?? _viewMode;
    });
    if (_selectedTag case final selected?) {
      _loadTagPage(selected, refresh: true);
    }
    _saveState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top bar with view mode and category selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // View mode selector
              Expanded(
                child:
                    usesAppleGlass
                        ? AppleGlassChoiceBar(
                          labels: const ['更新', '热门', '完结', '动画'],
                          index: int.parse(_viewMode),
                          onSelect: (index) => _changeSelection(mode: '$index'),
                        )
                        : AppSegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: "0", label: Text('更新')),
                            ButtonSegment(value: "1", label: Text('热门')),
                            ButtonSegment(value: "2", label: Text('完结')),
                            ButtonSegment(value: "3", label: Text('动画')),
                          ],
                          selected: {_viewMode},
                          onSelectionChanged:
                              (selection) =>
                                  _changeSelection(mode: selection.first),
                        ),
              ),
              // Category selector
              if (_tagGroups != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child:
                      usesAppleGlass
                          ? AppleGlassMenu(
                            label: _selectedTag ?? '分类',
                            selected: _selectedTag,
                            items: [
                              for (final group in _tagGroups!)
                                for (final tag in group.tags)
                                  {
                                    'group': group.title,
                                    'label': tag,
                                    'value': tag,
                                  },
                            ],
                            onSelect: (tag) => _changeSelection(tag: tag),
                          )
                          : AppPopupMenuButton<String>(
                            tooltip: '分类',
                            constraints:
                                usesMaterialYou
                                    ? BoxConstraints.tightFor(
                                      width: (MediaQuery.sizeOf(context).width -
                                              32)
                                          .clamp(0.0, 320.0),
                                    )
                                    : null,
                            child: Container(
                              constraints:
                                  usesMaterialYou
                                      ? BoxConstraints(
                                        minHeight: 56,
                                        maxWidth:
                                            MediaQuery.sizeOf(context).width <
                                                    600
                                                ? 120
                                                : 200,
                                      )
                                      : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    usesMaterialYou
                                        ? materialSurface(
                                          Theme.of(context).colorScheme,
                                          Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHigh,
                                          .08,
                                        )
                                        : null,
                                border:
                                    usesMaterialYou
                                        ? null
                                        : Border.all(
                                          color: Theme.of(context).dividerColor,
                                        ),
                                borderRadius: BorderRadius.circular(
                                  usesMaterialYou ? 20 : 8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _selectedTag ?? '分类',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color:
                                            _selectedTag != null
                                                ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                                : null,
                                        fontWeight:
                                            _selectedTag != null
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.arrow_drop_down),
                                ],
                              ),
                            ),
                            itemBuilder: (context) {
                              final items = <PopupMenuEntry<String>>[];
                              for (final group in _tagGroups!) {
                                items.add(
                                  PopupMenuItem<String>(
                                    enabled: false,
                                    child: Text(
                                      group.title,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                );
                                for (final tag in group.tags) {
                                  items.add(
                                    PopupMenuItem<String>(
                                      value: tag,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          left: 16,
                                        ),
                                        child: Text(
                                          tag,
                                          style: TextStyle(
                                            fontSize: 14,
                                            color:
                                                _selectedTag == tag
                                                    ? Theme.of(
                                                      context,
                                                    ).colorScheme.primary
                                                    : null,
                                            fontWeight:
                                                _selectedTag == tag
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                if (group != _tagGroups!.last) {
                                  items.add(const PopupMenuDivider());
                                }
                              }
                              return items;
                            },
                            onSelected: (tag) => _changeSelection(tag: tag),
                          ),
                )
              else if (_tagError != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: AppButton.textIcon(
                    onPressed: _loadTags,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试加载分类'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        if (_tagError != null)
          Wenku8RecoveryButton(
            error: _tagError,
            source: SourceId.wenku8,
            onRecovered: _loadTags,
          ),
        // Novel grid or error state
        Expanded(
          child:
              _selectedTag == null
                  ? _tagError != null
                      ? const Center(
                        child: SourceWebsiteLink(source: SourceId.wenku8),
                      )
                      : _tagGroups == null
                      ? SourceLoadingIndicator(
                        source: SourceId.wenku8,
                        requestKey: ('tags', _tagRequest),
                      )
                      : const Center(child: Text('请选择分类'))
                  : _pageError != null && _currentPage == null
                  ? RefreshIndicator(
                    onRefresh: () => _loadTagPage(_selectedTag!, refresh: true),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height - 100,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                size: 48,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                '加载失败 (下拉刷新)',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _pageError.toString(),
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.start,
                              ),
                              const SourceWebsiteLink(source: SourceId.wenku8),
                              Wenku8RecoveryButton(
                                error: _pageError,
                                source: SourceId.wenku8,
                                onRecovered:
                                    () => _loadTagPage(
                                      _selectedTag!,
                                      refresh: true,
                                    ),
                              ),
                              AppButton.text(
                                onPressed:
                                    () => _loadTagPage(
                                      _selectedTag!,
                                      refresh: true,
                                    ),
                                child: const Text('重新加载分类书目'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                  : _currentPage == null
                  ? SourceLoadingIndicator(
                    source: SourceId.wenku8,
                    requestKey: _pageRequest,
                  )
                  : NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollEndNotification &&
                          notification.metrics.pixels >=
                              notification.metrics.maxScrollExtent - 200 &&
                          !_isLoading &&
                          _pageError == null &&
                          _currentPage!.currentPage < _currentPage!.maxPage) {
                        _loadTagPage(_selectedTag!);
                      }
                      return true;
                    },
                    child: GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate: const BookGridDelegate(
                        childAspectRatio: 207 / 307,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount:
                          _currentPage!.records.length +
                          (_currentPage!.currentPage < _currentPage!.maxPage
                              ? 1
                              : 0),
                      itemBuilder: (context, index) {
                        if (index >= _currentPage!.records.length) {
                          if (_pageError != null) {
                            return SingleChildScrollView(
                              child: Column(
                                children: [
                                  AppButton.text(
                                    onPressed:
                                        () => _loadTagPage(_selectedTag!),
                                    child: const Text('加载失败，点击重试'),
                                  ),
                                  const SourceWebsiteLink(
                                    source: SourceId.wenku8,
                                  ),
                                ],
                              ),
                            );
                          }
                          if (_isLoading) {
                            return SourceLoadingIndicator(
                              source: SourceId.wenku8,
                              requestKey: _pageRequest,
                              size: 24,
                            );
                          }
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16.0),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        final novel = _currentPage!.records[index];
                        return NovelCoverCard(novel: novel);
                      },
                    ),
                  ),
        ),
      ],
    );
  }
}
