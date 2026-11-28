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
      bool folderSheet,
      int overlayRevision,
      Animation<double>? readerAnimation,
    });

/// Owns the selection independently of any one page in the Navigator.
class IosDockController extends NavigatorObserver {
  IosDockController({this.fullscreenRoutes = const {}});

  static const homeRouteName = '/home';

  final Set<String> fullscreenRoutes;
  final _routes = <Route<dynamic>>[];
  final _dismissing = <TransitionRoute<dynamic>, Set<Route<dynamic>>>{};
  final _selection = ValueNotifier<int>(0);
  int _overlayRevision = 0;
  final _dock = ValueNotifier<_DockState>((
    mounted: false,
    fullscreen: false,
    blocked: false,
    folderSheet: false,
    overlayRevision: 0,
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
      _dismissing.keys.any((route) => route is PopupRoute) ||
      _routes.lastOrNull is! PageRoute;
  bool _isFullscreen(Route<dynamic> route) =>
      fullscreenRoutes.contains(route.settings.name) ||
      (route is PageRoute && route.fullscreenDialog) ||
      route is ModalBottomSheetRoute ||
      route is CupertinoModalPopupRoute;
  bool get _fullscreen =>
      _dismissing.keys.any(_isFullscreen) || _routes.any(_isFullscreen);

  Animation<double>? get _readerAnimation {
    final fullscreen = [..._routes, ..._dismissing.keys].where(_isFullscreen);
    if (fullscreen.length != 1) return null;
    final route = fullscreen.single;
    if (route is PageRoute && fullscreenRoutes.contains(route.settings.name)) {
      return route.animation;
    }
    return null;
  }

  bool _hasRouteAbove(ModalRoute<dynamic> route) {
    final index = _routes.lastIndexOf(route);
    if (index >= 0 && index < _routes.length - 1) return true;
    return _dismissing.entries.any((entry) => entry.value.contains(route));
  }

  bool get _folderSheetVisible =>
      _routes.any(
        (route) => route.settings.name == bookshelfFolderSheetRouteName,
      ) ||
      _dismissing.keys.any(
        (route) => route.settings.name == bookshelfFolderSheetRouteName,
      );

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
        _overlayRevision++;
        _dock.value = (
          mounted: _homeIndex >= 0,
          fullscreen: _fullscreen,
          blocked: _modal || navigator?.userGestureInProgress == true,
          folderSheet: _folderSheetVisible,
          overlayRevision: _overlayRevision,
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
      _dismissing[route] = _routes.toSet();
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

  /// Whether another route still paints above [route]. Drawing no longer parks
  /// native glass, but this keeps interaction and semantics blocked until a
  /// dismissing modal has fully left the screen.
  static bool coveredAboveOf(BuildContext context, ModalRoute<dynamic> route) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_IosOverlayScope>();
    return scope?.controller._hasRouteAbove(route) ?? false;
  }

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
          _IosOverlayScope(
            controller: controller,
            revision: state.overlayRevision,
            child: IosDockInsets(
              height:
                  state.mounted && !keyboard
                      ? AppleGlassBottomBar.heightFor(media)
                      : 0,
              fullscreenRoutes: controller.fullscreenRoutes,
              child: child!,
            ),
          ),
          if (state.mounted)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _DockReveal(
                hidden: hidden,
                blocked: blocked,
                folderSheet: state.folderSheet,
                child: AnimatedBuilder(
                  animation: progress,
                  // Platform views need to leave the painted scene when covered.
                  // Keep the same Flutter element and native tab selection.
                  builder:
                      (_, dock) =>
                          Offstage(offstage: progress.value >= 1, child: dock),
                  child: ClipPath(
                    clipBehavior: reader == null ? Clip.none : Clip.antiAlias,
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

/// Hides the dock immediately for a keyboard sheet, then reveals the same live
/// native bar with a clipped upward move after the marked bookshelf folder
/// panel has completed and the keyboard is gone.
class _DockReveal extends StatefulWidget {
  const _DockReveal({
    required this.hidden,
    required this.blocked,
    required this.folderSheet,
    required this.child,
  });

  final bool hidden;
  final bool blocked;
  final bool folderSheet;
  final Widget child;

  @override
  State<_DockReveal> createState() => _DockRevealState();
}

class _DockRevealState extends State<_DockReveal>
    with SingleTickerProviderStateMixin {
  late final _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final _slide = Tween<Offset>(
    begin: const Offset(0, .18),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _reveal, curve: Curves.easeOutCubic));
  bool _restoreAfterFolderSheet = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _restoreAfterFolderSheet = widget.folderSheet && widget.hidden;
    if (widget.hidden) _reveal.value = 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion == _reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (_reduceMotion && _reveal.value < 1) _reveal.value = 1;
  }

  @override
  void didUpdateWidget(covariant _DockReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.folderSheet && widget.hidden) {
      _restoreAfterFolderSheet = true;
    }
    if (widget.hidden) {
      if (!oldWidget.hidden) {
        _reveal.stop();
        _reveal.value = 0;
      }
      return;
    }
    if (oldWidget.hidden) {
      if (_restoreAfterFolderSheet) {
        _restoreAfterFolderSheet = false;
        if (_reduceMotion) {
          _reveal.value = 1;
        } else {
          _reveal.forward(from: 0);
        }
      } else {
        _reveal.value = 1;
      }
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: widget.hidden,
    child: AnimatedBuilder(
      animation: _reveal,
      child: widget.child,
      builder: (context, child) {
        final inactive = widget.blocked || _reveal.value < 1;
        return IgnorePointer(
          ignoring: inactive,
          child: ExcludeSemantics(
            excluding: inactive,
            child: ExcludeFocus(
              excluding: inactive,
              child: ClipRect(
                key: const ValueKey('ios-dock-reveal'),
                clipper:
                    _reveal.value >= 1 ? null : _BottomRevealClipper(_reveal),
                child: SlideTransition(position: _slide, child: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _BottomRevealClipper extends CustomClipper<Rect> {
  _BottomRevealClipper(this.progress) : super(reclip: progress);

  final Animation<double> progress;

  @override
  Rect getClip(Size size) {
    final value = progress.value.clamp(0.0, 1.0);
    final height = size.height * value;
    return Rect.fromLTWH(0, size.height - height, size.width, height);
  }

  @override
  bool shouldReclip(_BottomRevealClipper oldClipper) =>
      oldClipper.progress != progress;
}

class _IosOverlayScope extends InheritedWidget {
  const _IosOverlayScope({
    required this.controller,
    required this.revision,
    required super.child,
  });

  final IosDockController controller;
  final int revision;

  @override
  bool updateShouldNotify(_IosOverlayScope oldWidget) =>
      oldWidget.controller != controller || oldWidget.revision != revision;
}

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
