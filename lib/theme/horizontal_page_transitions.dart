import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:wild/theme/ios_page_arrival.dart';

/// Wait until the pushed page's overlay is removed. A normal push Future
/// resolves as soon as pop starts, while the previous page is still being drawn.
Future<T?> pushAndWaitForPageExit<T>(
  BuildContext context,
  PageRoute<T> page,
) async {
  final result = await Navigator.of(context).push(page);
  await page.completed;
  return result;
}

/// Wait for a route to finish covering its predecessor before a window change.
Future<bool> waitForPageArrival(BuildContext context) async {
  final route = ModalRoute.of(context);
  // Hero measurement can temporarily report a completed animation on the
  // hidden destination. Check the real route after that measurement frame.
  if (route?.offstage == true) await WidgetsBinding.instance.endOfFrame;
  final animation = route?.animation;
  if (route != null && animation != null && !animation.isCompleted) {
    final arrived = Completer<bool>();
    void status(AnimationStatus status) {
      if (status == AnimationStatus.completed && !arrived.isCompleted) {
        arrived.complete(true);
      }
    }

    animation.addStatusListener(status);
    try {
      if (!await Future.any([
        arrived.future,
        route.completed.then((_) => false),
      ])) {
        return false;
      }
    } finally {
      animation.removeStatusListener(status);
    }
  }
  await WidgetsBinding.instance.endOfFrame;
  return context.mounted &&
      route?.isCurrent != false &&
      route?.offstage != true &&
      animation?.isCompleted != false;
}

const horizontalPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.iOS: LiteTaleCupertinoTransitionsBuilder(),
    TargetPlatform.fuchsia: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.linux: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.macOS: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.windows: HorizontalCoverPageTransitionsBuilder(),
  },
);

/// Slides over a stationary predecessor on platforms without Cupertino motion.
class HorizontalCoverPageTransitionsBuilder extends PageTransitionsBuilder {
  const HorizontalCoverPageTransitionsBuilder();

  // 300 ms spans about 36 frames on a 120 Hz display. Only a translation is
  // animated, so neither page needs an opacity or size animation each frame.
  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst) return child;
    return _HorizontalCoverTransition(animation: animation, child: child);
  }
}

/// Forces the app's full-screen motion even if a host theme replaces the
/// platform page transition defaults after the route has been created.
class HorizontalCoverPageRoute<T> extends MaterialPageRoute<T> {
  HorizontalCoverPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
    this.animateEntrance = true,
    this.cachePageDuringTransition = false,
    IosPageChromeWarmup? chromeWarmup,
  }) : chromeWarmup = chromeWarmup ?? IosPageChromeWarmup();

  final bool animateEntrance;
  final bool cachePageDuringTransition;

  /// Shared with the destination page so its UIKit glass can attach before
  /// the first visible entrance frame.
  final IosPageChromeWarmup chromeWarmup;

  bool get _usesIosMotion {
    final context = navigator?.context;
    return context != null && Theme.of(context).platform == TargetPlatform.iOS;
  }

  bool get _reduceMotion {
    final context = navigator?.context;
    return context != null &&
        MediaQuery.maybeDisableAnimationsOf(context) == true;
  }

  @override
  Duration get transitionDuration =>
      !animateEntrance || (_usesIosMotion && _reduceMotion)
          ? Duration.zero
          : const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration =>
      _usesIosMotion && _reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 300);

  @override
  Simulation? createSimulation({required bool forward}) {
    if (!_usesIosMotion ||
        _reduceMotion ||
        fullscreenDialog ||
        popGestureInProgress ||
        (forward && (!animateEntrance || isFirst))) {
      return null;
    }
    final start = animation!.value;
    final end = forward ? 1.0 : 0.0;
    // The iOS recording's incoming edge follows a critically damped spring
    // with an immediate start. The recorded return settles more quickly.
    final spring =
        forward
            ? const SpringDescription(mass: 1, stiffness: 441, damping: 42)
            : const SpringDescription(mass: 1, stiffness: 1600, damping: 80);
    final simulation = SpringSimulation(
      spring,
      start,
      end,
      (end - start) * (forward ? 9 : 0),
      tolerance: const Tolerance(distance: .001, velocity: .02),
      snapToEnd: true,
    );
    // A push waits for the destination's native glass so the Flutter
    // attachment placeholder never appears while the page is moving.
    return forward
        ? _ChromeWarmupSimulation(simulation, chromeWarmup)
        : simulation;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => (Theme.of(context).platform == TargetPlatform.iOS
          ? LiteTaleCupertinoTransitionsBuilder(
            useLinearProgress: !fullscreenDialog,
            cachePageDuringTransition: cachePageDuringTransition,
            chromeWarmup: chromeWarmup,
          )
          : const HorizontalCoverPageTransitionsBuilder())
      .buildTransitions(this, context, animation, secondaryAnimation, child);
}

/// Waits until the destination has laid out and attached its UIKit glass.
///
/// Returning zero while waiting keeps the route at its off-screen origin, so
/// the solid placeholder used before the platform view exists is never drawn
/// in the visible part of the slide. A page without glass runs on the original
/// timeline; a stuck callback releases after [IosPageChromeWarmup.maximumHold].
class _ChromeWarmupSimulation extends Simulation {
  _ChromeWarmupSimulation(this._spring, this._warmup);

  final SpringSimulation _spring;
  final IosPageChromeWarmup _warmup;
  double? _origin;

  bool _start(double time) {
    if (_origin != null) return true;
    if (_warmup.empty) {
      // No native glass: preserve the ordinary first-frame timing.
      _origin = 0;
      _warmup.markEntranceStarted();
      return true;
    }
    if (!_warmup.waiting) {
      _origin = time;
      _warmup.markEntranceStarted();
      return true;
    }
    if (time >=
        _warmup.maximumHold.inMicroseconds / Duration.microsecondsPerSecond) {
      _warmup.release();
      _origin = time;
      _warmup.markEntranceStarted();
      return true;
    }
    return false;
  }

  @override
  double x(double time) => _start(time) ? _spring.x(time - _origin!) : 0;

  @override
  double dx(double time) => _start(time) ? _spring.dx(time - _origin!) : 0;

  @override
  bool isDone(double time) => _start(time) && _spring.isDone(time - _origin!);
}

class _HorizontalCoverTransition extends StatefulWidget {
  const _HorizontalCoverTransition({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<_HorizontalCoverTransition> createState() =>
      _HorizontalCoverTransitionState();
}

class _HorizontalCoverTransitionState
    extends State<_HorizontalCoverTransition> {
  late CurvedAnimation _curve;
  late Animation<Offset> _position;

  void _bindAnimation() {
    _curve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutQuad,
      reverseCurve: Curves.easeInQuad,
    );
    _position = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(_curve);
  }

  @override
  void initState() {
    super.initState();
    _bindAnimation();
  }

  @override
  void didUpdateWidget(_HorizontalCoverTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve.dispose();
      _bindAnimation();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _position,
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(child: widget.child),
    );
  }
}
