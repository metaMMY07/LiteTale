import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:wild/theme/ios_page_arrival.dart';

/// Wait until the pushed page's overlay is removed. A normal push Future
/// resolves as soon as pop starts, while the previous page is still being drawn.
Future<void> pushAndWaitForPageExit(
  BuildContext context,
  PageRoute<void> page,
) async {
  await Navigator.of(context).push(page);
  await page.completed;
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
  });

  final bool animateEntrance;
  final bool cachePageDuringTransition;

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
    return SpringSimulation(
      spring,
      start,
      end,
      (end - start) * (forward ? 9 : 0),
      tolerance: const Tolerance(distance: .001, velocity: .02),
      snapToEnd: true,
    );
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
          )
          : const HorizontalCoverPageTransitionsBuilder())
      .buildTransitions(this, context, animation, secondaryAnimation, child);
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
