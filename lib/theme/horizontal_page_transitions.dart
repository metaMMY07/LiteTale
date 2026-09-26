import 'package:flutter/material.dart';

/// A page covers its predecessor from the right and uncovers it to the right.
/// The page underneath stays still. No opacity, scale, or shared-element work is
/// performed during the transition.
const horizontalPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.iOS: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.fuchsia: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.linux: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.macOS: HorizontalCoverPageTransitionsBuilder(),
    TargetPlatform.windows: HorizontalCoverPageTransitionsBuilder(),
  },
);

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
  });

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => const HorizontalCoverPageTransitionsBuilder().buildTransitions(
    this,
    context,
    animation,
    secondaryAnimation,
    child,
  );
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
