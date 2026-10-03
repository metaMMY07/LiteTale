import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/pages/shelf_catalog_page.dart';
import 'package:wild/settings/source_settings_page.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/book_grid_delegate.dart';
import 'package:wild/widgets/novel_cover_card.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';
import 'package:wild/widgets/theme_reveal_host.dart';

import '../../src/rust/api/database.dart';
import 'package:wild/sources/source_api.dart';
import 'category_page.dart';
import 'recommend_page.dart';
import '../search_page.dart';

class IndexPage extends StatefulWidget {
  const IndexPage({super.key});

  @override
  State<IndexPage> createState() => _IndexPageState();
}

class _IndexPageState extends State<IndexPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _themeButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _switchTheme() async {
    final target =
        Theme.of(context).brightness == Brightness.dark
            ? ReaderThemeMode.light
            : ReaderThemeMode.dark;
    final theme = context.read<ThemeCubit>();
    final reveal = ThemeRevealHost.maybeOf(context);
    if (reveal == null) {
      await theme.setThemeMode(target);
      return;
    }
    await reveal.revealFrom(
      triggerContext: _themeButtonKey.currentContext ?? context,
      changeTheme: () {
        unawaited(theme.setThemeMode(target));
      },
    );
  }

  Widget _buildDiscoveryTabs(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tabs = TabBar(
      controller: _tabController,
      indicatorPadding:
          usesMaterialYou ? const EdgeInsets.only(bottom: 5) : EdgeInsets.zero,
      tabs: [
        const Tab(text: '推荐'),
        const Tab(text: '分类'),
        const Tab(text: '排行'),
        Tab(text: activeSource.value == SourceId.wenku8 ? '完结' : '全部'),
      ],
    );
    if (!usesMaterialYou) return tabs;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(18),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Row(
                    children: [
                      for (var index = 0; index < 4; index++) ...[
                        const Expanded(child: SizedBox.shrink()),
                        if (index < 3)
                          Container(
                            width: 1,
                            height: 26,
                            color: colors.outline.withValues(alpha: 0.45),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              tabs,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = context.select<AuthCubit, bool>(
      (auth) => auth.state.status == AuthStatus.authenticated,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(usesMaterialYou ? '发现' : '轻小说文库'),
        actions: [
          if (usesMaterialYou)
            IconButton(
              key: _themeButtonKey,
              icon: Icon(
                Theme.of(context).brightness == Brightness.dark
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
              ),
              tooltip:
                  Theme.of(context).brightness == Brightness.dark
                      ? '切换浅色模式'
                      : '切换深色模式',
              onPressed: _switchTheme,
            )
          else
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: '搜索',
              onPressed: () {
                Navigator.push(
                  context,
                  HorizontalCoverPageRoute(
                    builder: (context) => const SearchPage(),
                  ),
                );
              },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(usesMaterialYou ? 132 : 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (usesMaterialYou)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Semantics(
                    button: true,
                    label:
                        activeSource.value == SourceId.lnovel
                            ? '按目录查找繁体书名'
                            : '搜索书名、作者',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(32),
                      onTap: () => Navigator.pushNamed(context, '/search'),
                      child: IgnorePointer(
                        child: SearchBar(
                          hintText:
                              activeSource.value == SourceId.lnovel
                                  ? '按目录查找繁体书名'
                                  : '搜索书名、作者',
                          leading: const Icon(Icons.search_rounded),
                          trailing: const [Icon(Icons.auto_stories_rounded)],
                          elevation: const WidgetStatePropertyAll(0),
                        ),
                      ),
                    ),
                  ),
                ),
              _buildDiscoveryTabs(context),
            ],
          ),
        ),
      ),
      body:
          activeSource.value == SourceId.wenku8 && !signedIn
              ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.auto_stories_outlined, size: 48),
                      const SizedBox(height: 16),
                      const Text('欢迎使用 LiteTale'),
                      const SizedBox(height: 8),
                      const Text(
                        '选择书源后即可开始；需要账号的书源可在同一页面登录。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed:
                            () => Navigator.push(
                              context,
                              HorizontalCoverPageRoute(
                                builder: (_) => const SourceSettingsPage(),
                              ),
                            ),
                        child: const Text('选择书源'),
                      ),
                    ],
                  ),
                ),
              )
              : TabBarView(
                controller: _tabController,
                children:
                    activeSource.value == SourceId.wenku8
                        ? const [
                          RecommendPage(),
                          CategoryPage(),
                          ToplistPage(),
                          ArticlelistPage(),
                        ]
                        : const [
                          RecommendPage(),
                          ShelfCatalogPage(mode: 'category'),
                          ShelfCatalogPage(mode: 'rank'),
                          ShelfCatalogPage(mode: 'all'),
                        ],
              ),
    );
  }
}

class ToplistPage extends StatefulWidget {
  const ToplistPage({super.key});

  @override
  State<ToplistPage> createState() => _ToplistPageState();
}

class _ToplistPageState extends State<ToplistPage> {
  static const _sortOptions = [
    ('更新', 'lastupdate'),
    ('发布', 'postdate'),
    ('总访问', 'allvisit'),
    ('总推荐', 'allvote'),
    ('总收藏', 'goodnum'),
    ('日访问', 'dayvisit'),
    ('日推荐', 'dayvote'),
    ('月访问', 'monthvisit'),
    ('月推荐', 'monthvote'),
    ('周访问', 'weekvisit'),
    ('周推荐', 'weekvote'),
    ('字数', 'size'),
    ('动画', 'anime'),
  ];

  String _selectedSort = 'lastupdate';
  PageStatsNovelCover? _currentPage;
  bool _isLoading = false;
  String? _errorMessage;
  static const _keySort = 'toplist_page_sort';

  @override
  void initState() {
    super.initState();
    _loadSavedState();
  }

  Future<void> _loadSavedState() async {
    try {
      final savedSort = await loadProperty(key: _keySort);
      if (savedSort.isNotEmpty) {
        setState(() {
          _selectedSort = savedSort;
        });
        _loadToplist(refresh: true);
      } else {
        _loadToplist(refresh: true);
      }
    } catch (e) {
      // 如果加载失败，使用默认值
      _loadToplist(refresh: true);
    }
  }

  Future<void> _saveState() async {
    try {
      await saveProperty(key: _keySort, value: _selectedSort);
    } catch (e) {
      // 如果保存失败，继续使用当前状态
    }
  }

  Future<void> _loadToplist({bool refresh = false}) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      if (refresh) {
        _currentPage = null;
        _errorMessage = null;
      }
    });

    try {
      final page = await toplist(
        sort: _selectedSort,
        page: refresh ? 1 : (_currentPage?.currentPage ?? 0) + 1,
      );
      setState(() {
        if (refresh) {
          _currentPage = page;
        } else {
          _currentPage = PageStatsNovelCover(
            currentPage: page.currentPage,
            maxPage: page.maxPage,
            records: [..._currentPage!.records, ...page.records],
          );
        }
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Sort selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children:
                  _sortOptions.map((option) {
                    final (label, value) = option;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(label),
                        selected: _selectedSort == value,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _selectedSort = value;
                              _errorMessage = null;
                            });
                            _loadToplist(refresh: true);
                            _saveState();
                          }
                        },
                      ),
                    );
                  }).toList(),
            ),
          ),
        ),
        // Novel grid or error state
        Expanded(
          child:
              _errorMessage != null
                  ? RefreshIndicator(
                    onRefresh: () => _loadToplist(refresh: true),
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
                                _errorMessage!,
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.start,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                  : _currentPage == null
                  ? const CenteredLoadingIndicator()
                  : NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollEndNotification &&
                          notification.metrics.pixels >=
                              notification.metrics.maxScrollExtent - 200 &&
                          !_isLoading &&
                          _currentPage!.currentPage < _currentPage!.maxPage) {
                        _loadToplist();
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

class ArticlelistPage extends StatefulWidget {
  const ArticlelistPage({super.key});

  @override
  State<ArticlelistPage> createState() => _ArticlelistPageState();
}

class _ArticlelistPageState extends State<ArticlelistPage> {
  PageStatsNovelCover? _currentPage;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadArticlelist(refresh: true);
  }

  Future<void> _loadArticlelist({bool refresh = false}) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      if (refresh) {
        _currentPage = null;
        _errorMessage = null;
      }
    });

    try {
      final page = await articlelist(
        fullflag: 1,
        page: refresh ? 1 : (_currentPage?.currentPage ?? 0) + 1,
      );
      setState(() {
        if (refresh) {
          _currentPage = page;
        } else {
          _currentPage = PageStatsNovelCover(
            currentPage: page.currentPage,
            maxPage: page.maxPage,
            records: [..._currentPage!.records, ...page.records],
          );
        }
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _errorMessage != null
        ? RefreshIndicator(
          onRefresh: () => _loadArticlelist(refresh: true),
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
                      _errorMessage!,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.start,
                    ),
                  ],
                ),
              ),
            ],
          ),
        )
        : _currentPage == null
        ? const CenteredLoadingIndicator()
        : NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollEndNotification &&
                notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 200 &&
                !_isLoading &&
                _currentPage!.currentPage < _currentPage!.maxPage) {
              _loadArticlelist();
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
                (_currentPage!.currentPage < _currentPage!.maxPage ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _currentPage!.records.length) {
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
        );
  }
}
