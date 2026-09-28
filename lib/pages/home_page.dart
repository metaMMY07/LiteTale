import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/theme/material_you.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/more_page.dart';
import 'package:wild/pages/home/index_page.dart';
import 'package:wild/pages/home/history_cubit.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/widgets/fluid_navigation_bar.dart';

import 'home/bookshelf_page.dart';
import 'home/history_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  late final HistoryCubit _historyCubit;

  @override
  void initState() {
    super.initState();
    _historyCubit = HistoryCubit()..load();
    // 加载书架数据
    _loadBookshelf();
    activeSource.addListener(_sourceChanged);
    sourceRevision.addListener(_sourceChanged);
    // 自动签到
    _autoSign();
  }

  Future<void> _autoSign() async {
    if (activeSource.value != SourceId.wenku8 ||
        context.read<AuthCubit>().state.status != AuthStatus.authenticated) {
      return;
    }
    try {
      final signed = await autoSign();
      if (signed && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('今日已自动签到'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   SnackBar(
        //     content: Text('签到失败: $e'),
        //     duration: const Duration(seconds: 2),
        //   ),
        // );
      }
    }
  }

  @override
  void dispose() {
    activeSource.removeListener(_sourceChanged);
    sourceRevision.removeListener(_sourceChanged);
    _historyCubit.close();
    super.dispose();
  }

  void _loadBookshelf() {
    final shelf = context.read<BookshelfCubit>();
    if (activeSource.value == SourceId.wenku8 &&
        context.read<AuthCubit>().state.status != AuthStatus.authenticated) {
      shelf.resetForGuest();
    } else {
      shelf.loadBookcases();
    }
  }

  void _sourceChanged() {
    if (!mounted) return;
    setState(() {});
    _loadBookshelf();
    _historyCubit.load();
    _autoSign();
  }

  void _onDestinationSelected(int index) {
    if (_currentIndex != index) {
      setState(() {
        _currentIndex = index;
      });
      // 切换到历史页面时刷新数据
      if (index == 2) {
        _historyCubit.load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _historyCubit,
      child: BlocBuilder<UpdateCubit, UpdateState>(
        builder: (context, state) {
          final destinations = [
            FluidNavigationDestination(
              icon:
                  usesMaterialYou
                      ? Icons.explore_outlined
                      : Icons.home_outlined,
              selectedIcon:
                  usesMaterialYou ? Icons.explore_rounded : Icons.home,
              label: usesMaterialYou ? '发现' : '首页',
            ),
            const FluidNavigationDestination(
              icon: Icons.bookmarks_outlined,
              selectedIcon: Icons.bookmarks_rounded,
              label: '书架',
            ),
            const FluidNavigationDestination(
              icon: Icons.history_outlined,
              selectedIcon: Icons.history_rounded,
              label: '历史',
            ),
            FluidNavigationDestination(
              icon:
                  usesMaterialYou
                      ? Icons.person_outline_rounded
                      : Icons.more_horiz_outlined,
              selectedIcon:
                  usesMaterialYou ? Icons.person_rounded : Icons.more_horiz,
              label: usesMaterialYou ? '我的' : '更多',
              showBadge: state.updateInfo != null,
            ),
          ];
          return Scaffold(
            body: IndexedStack(
              index: _currentIndex,
              children: [
                TickerMode(
                  enabled: _currentIndex == 0,
                  child: IndexPage(
                    key: ValueKey(
                      'index:${activeSource.value}:${sourceRevision.value}',
                    ),
                  ),
                ),
                TickerMode(
                  enabled: _currentIndex == 1,
                  child: BookshelfPage(
                    key: ValueKey(
                      'shelf:${activeSource.value}:${sourceRevision.value}',
                    ),
                  ),
                ),
                TickerMode(
                  enabled: _currentIndex == 2,
                  child: HistoryPage(
                    key: ValueKey(
                      'history:${activeSource.value}:${sourceRevision.value}',
                    ),
                  ),
                ),
                TickerMode(
                  enabled: _currentIndex == 3,
                  child: MorePage(key: ValueKey(activeSource.value)),
                ),
              ],
            ),
            bottomNavigationBar:
                usesMaterialYou
                    ? FluidNavigationBar(
                      destinations: destinations,
                      selectedIndex: _currentIndex,
                      onDestinationSelected: _onDestinationSelected,
                    )
                    : NavigationBar(
                      selectedIndex: _currentIndex,
                      onDestinationSelected: _onDestinationSelected,
                      destinations: [
                        for (final destination in destinations)
                          NavigationDestination(
                            icon: Badge(
                              isLabelVisible: destination.showBadge,
                              label: const Text('新'),
                              child: Icon(destination.icon),
                            ),
                            selectedIcon: Badge(
                              isLabelVisible: destination.showBadge,
                              label: const Text('新'),
                              child: Icon(destination.selectedIcon),
                            ),
                            label: destination.label,
                          ),
                      ],
                    ),
          );
        },
      ),
    );
  }
}
