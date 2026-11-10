import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

typedef _DockState = ({bool mounted, bool fullscreen, bool blocked});

/// Owns the selection independently of any one page in the Navigator.
class IosDockController extends NavigatorObserver {
  IosDockController({this.fullscreenRoutes = const {}});

  static const homeRouteName = '/home';

  final Set<String> fullscreenRoutes;
  final _routes = <Route<dynamic>>[];
  final _dismissing = <TransitionRoute<dynamic>>{};
  final _selection = ValueNotifier<int>(0);
  final _dock = ValueNotifier<_DockState>((
    mounted: false,
    fullscreen: false,
    blocked: false,
  ));
  bool _publishQueued = false;
  bool _disposed = false;

  ValueListenable<int> get selection => _selection;

  int get _homeIndex => _routes.lastIndexWhere(
    (route) =>
        route is PageRoute &&
        route.settings.name == homeRouteName &&
        route.isActive,
  );

  bool get _modal =>
      _dismissing.any((route) => route is PopupRoute) ||
      _routes.lastOrNull is! PageRoute;
  bool _isFullscreen(Route<dynamic> route) =>
      fullscreenRoutes.contains(route.settings.name);
  bool get _fullscreen =>
      _dismissing.any(_isFullscreen) || _routes.any(_isFullscreen);

  void select(int index) {
    final nav = navigator;
    final homeIndex = _homeIndex;
    if (_disposed ||
        index < 0 ||
        index >= 4 ||
        homeIndex < 0 ||
        nav == null ||
        nav.userGestureInProgress ||
        _modal ||
        _fullscreen) {
      return;
    }
    final home = _routes[homeIndex];
    _selection.value = index;
    if (home.isCurrent || homeIndex == _routes.length - 1) return;

    // Discard intervening pages without animating them all at once. Only the
    // visible top page slides away, revealing the already mounted home tab.
    final intermediate = _routes.sublist(homeIndex + 1, _routes.length - 1);
    for (final route in intermediate.reversed) {
      if (route.isActive) nav.removeRoute(route);
    }
    nav.popUntil((route) => identical(route, home));
  }

  void _publish() {
    if (_publishQueued || _disposed) return;
    _publishQueued = true;
    // Observer callbacks can also run while the Navigator is being built.
    scheduleMicrotask(() {
      _publishQueued = false;
      if (!_disposed) {
        _dock.value = (
          mounted: _homeIndex >= 0,
          fullscreen: _fullscreen,
          blocked: _modal || navigator?.userGestureInProgress == true,
        );
      }
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _publish();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    if (route is TransitionRoute<dynamic> &&
        (route is PopupRoute || _isFullscreen(route))) {
      _dismissing.add(route);
      unawaited(
        route.completed.then((_) {
          _dismissing.remove(route);
          _publish();
        }),
      );
    }
    _publish();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _publish();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) {
      _routes[index] = newRoute;
    } else if (index >= 0) {
      _routes.removeAt(index);
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _publish();
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) => _publish();

  @override
  void didStopUserGesture() => _publish();

  void dispose() {
    _disposed = true;
    _selection.dispose();
    _dock.dispose();
  }
}

/// Mounts the UIKit bar as a sibling of the Navigator so no page transition
/// can move, cover or reattach it. Pages use the remaining viewport.
class IosAppDockHost extends StatelessWidget {
  const IosAppDockHost({
    super.key,
    required this.controller,
    required this.child,
  });

  final IosDockController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_DockState>(
    valueListenable: controller._dock,
    child: child,
    builder: (context, state, child) {
      final media = MediaQuery.of(context);
      final visible = state.mounted && !state.fullscreen;
      final blocked = state.fullscreen || state.blocked;
      final extent = visible ? AppleGlassBottomBar.heightFor(media) : 0.0;
      final pageMedia =
          visible
              ? media.copyWith(
                size: Size(
                  media.size.width,
                  math.max(0.0, media.size.height - extent),
                ),
                padding: media.padding.copyWith(bottom: 0),
                viewPadding: media.viewPadding.copyWith(bottom: 0),
                viewInsets: media.viewInsets.copyWith(
                  bottom: math.max(0.0, media.viewInsets.bottom - extent),
                ),
                systemGestureInsets: media.systemGestureInsets.copyWith(
                  bottom: 0,
                ),
              )
              : media;
      return ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: MediaQuery(data: pageMedia, child: child!)),
            if (state.mounted)
              Offstage(
                offstage: state.fullscreen,
                child: IgnorePointer(
                  ignoring: blocked,
                  child: ExcludeSemantics(
                    excluding: blocked,
                    child: ExcludeFocus(
                      excluding: blocked,
                      child: ValueListenableBuilder<int>(
                        valueListenable: controller.selection,
                        builder:
                            (_, index, _) => AppleGlassBottomBar(
                              index: index,
                              onSelect: controller.select,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
