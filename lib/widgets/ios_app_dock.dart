import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoModalPopupRoute;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/ios_dock_insets.dart';
import 'package:wild/theme/ios_page_arrival.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/app_launch_screen.dart';

typedef _DockState =
    ({
      bool mounted,
      bool fullscreen,
      bool blocked,
      Animation<double>? readerAnimation,
    });

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
    readerAnimation: null,
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
      fullscreenRoutes.contains(route.settings.name) ||
      (route is PageRoute && route.fullscreenDialog) ||
      route is ModalBottomSheetRoute ||
      route is CupertinoModalPopupRoute;
  bool get _fullscreen =>
      _dismissing.any(_isFullscreen) || _routes.any(_isFullscreen);

  Animation<double>? get _readerAnimation {
    final fullscreen = [..._routes, ..._dismissing].where(_isFullscreen);
    if (fullscreen.length != 1) return null;
    final route = fullscreen.single;
    if (route is PageRoute && fullscreenRoutes.contains(route.settings.name)) {
      return route.animation;
    }
    return null;
  }

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
          readerAnimation: _readerAnimation,
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

/// Keeps the UIKit bar mounted beside the Navigator, under a sliding reader
/// and above the regular pages that scroll under its translucent surface.
class IosAppDockHost extends StatelessWidget {
  const IosAppDockHost({
    super.key,
    required this.controller,
    required this.child,
    this.revealHomeOnStartup = false,
  });

  final IosDockController controller;
  final Widget child;
  final bool revealHomeOnStartup;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_DockState>(
    valueListenable: controller._dock,
    child: child,
    builder: (context, state, child) {
      final media = MediaQuery.of(context);
      final keyboard = media.viewInsets.bottom > 0;
      final reader = state.readerAnimation;
      final hidden = keyboard || (state.fullscreen && reader == null);
      final blocked = hidden || state.fullscreen || state.blocked;
      final direction = Directionality.of(context);
      final progress = reader ?? kAlwaysDismissedAnimation;
      final content = Stack(
        fit: StackFit.expand,
        children: [
          IosDockInsets(
            height:
                state.mounted && !keyboard
                    ? AppleGlassBottomBar.heightFor(media)
                    : 0,
            fullscreenRoutes: controller.fullscreenRoutes,
            child: child!,
          ),
          if (state.mounted)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedBuilder(
                animation: progress,
                // Platform views need to leave the painted scene when covered.
                // Keep the same Flutter element and native tab selection.
                builder:
                    (_, dock) => Offstage(
                      offstage: hidden || progress.value >= 1,
                      child: dock,
                    ),
                child: IgnorePointer(
                  ignoring: blocked,
                  child: ExcludeSemantics(
                    excluding: blocked,
                    child: ExcludeFocus(
                      excluding: blocked,
                      child: ClipPath(
                        clipBehavior:
                            reader == null ? Clip.none : Clip.antiAlias,
                        clipper: _ReaderDockClipper(
                          progress,
                          media.size.height,
                          direction,
                          radius:
                              media.disableAnimations
                                  ? BorderRadius.zero
                                  : iosSlidingPageRadius(
                                    media.size,
                                    textDirection: direction,
                                  ),
                        ),
                        child: SlideTransition(
                          position: progress.drive(_dockParallax),
                          textDirection: direction,
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
                ),
              ),
            ),
        ],
      );
      return revealHomeOnStartup
          ? IosStartupTransition(homeMounted: state.mounted, child: content)
          : content;
    },
  );
}

// The bottom bar travels with the page under the reader's Cupertino slide.
final _dockParallax = Tween<Offset>(
  begin: Offset.zero,
  end: const Offset(-1 / 3, 0),
);

class _ReaderDockClipper extends CustomClipper<Path> {
  _ReaderDockClipper(
    this.progress,
    this.viewportHeight,
    this.direction, {
    required this.radius,
  }) : super(reclip: progress);

  final Animation<double> progress;
  final double viewportHeight;
  final TextDirection direction;
  final BorderRadius radius;

  @override
  Path getClip(Size size) {
    final value = progress.value.clamp(0.0, 1.0);
    if (value == 1) return Path();
    final dock = Path()..addRect(Offset.zero & size);
    if (value == 0) return dock;
    final distance = size.width * (1 - value);
    final page = Rect.fromLTWH(
      direction == TextDirection.ltr ? distance : -distance,
      size.height - viewportHeight,
      size.width,
      viewportHeight,
    );
    return Path.combine(
      PathOperation.difference,
      dock,
      Path()..addRRect(radius.toRRect(page)),
    );
  }

  @override
  bool shouldReclip(_ReaderDockClipper oldClipper) =>
      oldClipper.progress != progress ||
      oldClipper.viewportHeight != viewportHeight ||
      oldClipper.direction != direction ||
      oldClipper.radius != radius;
}
