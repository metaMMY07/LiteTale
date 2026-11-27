import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/ios_dock_insets.dart';

/// Counts the UIKit glass views a destination page is still waiting for.
///
/// A pushed page keeps its entrance at the off-screen origin until these
/// views exist, so the solid attachment placeholder never becomes visible and
/// the native glass does not swap in mid-slide. Pages without glass resolve
/// once their first layout completes and keep the normal first frame.
class IosPageChromeWarmup {
  IosPageChromeWarmup({this.maximumHold = const Duration(milliseconds: 100)});

  /// Upper bound for a missed or stuck platform-view callback.
  final Duration maximumHold;

  int _pending = 0;
  bool _sawChrome = false;
  bool _pageBuilt = false;
  bool _released = false;
  bool _entranceStarted = false;

  /// True until layout has run and every glass view in the page has attached.
  bool get waiting => !_released && (!_pageBuilt || _pending > 0);

  /// True once the entrance slide has started (after warmup or [maximumHold]).
  bool get entranceStarted => _entranceStarted;

  /// True when this page has no UIKit glass at all, so its entrance may reuse
  /// the elapsed animation time instead of starting a delayed spring. A page
  /// whose glass has already attached is not empty and starts its slide at
  /// the current frame.
  bool get empty => !_released && _pageBuilt && _pending == 0 && !_sawChrome;

  void register() {
    if (_released) return;
    _sawChrome = true;
    _pending++;
  }

  void attached() {
    if (_pending > 0) _pending--;
  }

  void abandon() => attached();

  void pageLaidOut() => _pageBuilt = true;

  void markEntranceStarted() => _entranceStarted = true;

  void release() {
    _released = true;
    _pending = 0;
  }

  @visibleForTesting
  int get pending => _pending;

  @visibleForTesting
  bool get sawChrome => _sawChrome;

  @visibleForTesting
  bool get pageBuilt => _pageBuilt;
}

// Only round the leading edge sliding over the previous page; rounding the
// trailing edge exposes the window background at the top-right corner while
// the predecessor parallax-slides to the left.
BorderRadius iosSlidingPageRadius(
  Size viewport, {
  TextDirection textDirection = TextDirection.ltr,
}) => BorderRadiusDirectional.horizontal(
  start: Radius.circular(viewport.shortestSide >= 600 ? 32 : 64),
).resolve(textDirection);

/// Preserves the Cupertino slide and edge swipe while exposing the first
/// settled frame to work that should not compete with the entrance.
class LiteTaleCupertinoTransitionsBuilder
    extends CupertinoPageTransitionsBuilder {
  const LiteTaleCupertinoTransitionsBuilder({
    this.useLinearProgress = false,
    this.cachePageDuringTransition = false,
    this.chromeWarmup,
  });

  final bool useLinearProgress;
  final bool cachePageDuringTransition;
  final IosPageChromeWarmup? chromeWarmup;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) == true;
    // Delegated transitions can pass an idle animation while the page above
    // is moving. Observe the actual route to track visibility.
    final secondary = route.secondaryAnimation ?? secondaryAnimation;
    final content = _IosPageArrival(
      route: route,
      animation: animation,
      secondary: secondary,
      chromeWarmup: chromeWarmup,
      roundWhileSliding:
          !route.fullscreenDialog && !route.isFirst && !reduceMotion,
      child: IosDockInsets.applyToPage(
        context,
        route,
        cachePageDuringTransition && route.allowSnapshotting && !reduceMotion
            ? _IosPageSnapshot(
              primary: animation,
              secondary: secondary,
              child: child,
            )
            : child,
      ),
    );
    if (reduceMotion && !useLinearProgress) return content;

    final transition = super.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      content,
    );
    if (!useLinearProgress || transition is! CupertinoPageTransition) {
      return transition;
    }
    // Reuse Flutter's edge recognizer and hand the two pages the same progress
    // from the route spring, including while a back swipe is tracking a finger.
    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: true,
      child: transition.child,
    );
  }
}

/// Cache the departing Flutter page. Incoming content and native controls
/// continue to draw live, so the transition cannot show stale glass or forms.
class _IosPageSnapshot extends StatefulWidget {
  const _IosPageSnapshot({
    required this.primary,
    required this.secondary,
    required this.child,
  });

  final Animation<double> primary, secondary;
  final Widget child;

  @override
  State<_IosPageSnapshot> createState() => _IosPageSnapshotState();
}

class _IosPageSnapshotState extends State<_IosPageSnapshot> {
  final _snapshot = SnapshotController();

  void _update(AnimationStatus _) {
    _snapshot.allowSnapshotting =
        widget.primary.status == AnimationStatus.reverse ||
        (widget.primary.isCompleted &&
            widget.secondary.status == AnimationStatus.forward);
  }

  @override
  void initState() {
    super.initState();
    widget.primary.addStatusListener(_update);
    widget.secondary.addStatusListener(_update);
    _update(widget.primary.status);
  }

  @override
  void didUpdateWidget(covariant _IosPageSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.primary != widget.primary) {
      oldWidget.primary.removeStatusListener(_update);
      widget.primary.addStatusListener(_update);
    }
    if (oldWidget.secondary != widget.secondary) {
      oldWidget.secondary.removeStatusListener(_update);
      widget.secondary.addStatusListener(_update);
    }
    _update(widget.primary.status);
  }

  @override
  void dispose() {
    widget.primary.removeStatusListener(_update);
    widget.secondary.removeStatusListener(_update);
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _snapshot,
    mode: SnapshotMode.permissive,
    autoresize: true,
    child: widget.child,
  );
}

class IosPageArrival extends InheritedWidget {
  const IosPageArrival._({
    required this.pending,
    required this.chromeAtRest,
    required this.onstage,
    required this.chromeWarmup,
    required super.child,
  });

  final Future<bool>? pending;
  final bool chromeAtRest;

  /// The Navigator hides a freshly pushed route for one frame while it
  /// measures Hero destinations. Dependents must rebuild when it is shown.
  final bool onstage;
  final IosPageChromeWarmup? chromeWarmup;

  /// Null once the page is visible at rest, or outside a Cupertino route.
  /// A pending arrival resolves false if the route is removed first.
  static Future<bool>? pendingOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<IosPageArrival>()?.pending;

  /// The UIKit glass this route has to attach before its entrance is shown.
  static IosPageChromeWarmup? chromeWarmupOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<IosPageArrival>()?.chromeWarmup;

  /// Observe the boundaries of a slide in either direction, including the
  /// page underneath it. This does not rebuild listeners for each tick.
  static bool chromeAtRestOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<IosPageArrival>()
          ?.chromeAtRest ??
      true;

  @override
  bool updateShouldNotify(IosPageArrival oldWidget) =>
      oldWidget.pending != pending ||
      oldWidget.chromeAtRest != chromeAtRest ||
      oldWidget.onstage != onstage;
}

class _IosPageArrival extends StatefulWidget {
  const _IosPageArrival({
    required this.route,
    required this.animation,
    required this.secondary,
    required this.roundWhileSliding,
    required this.child,
    this.chromeWarmup,
  });

  final ModalRoute<Object?> route;
  final Animation<double> animation;
  final Animation<double> secondary;
  final bool roundWhileSliding;
  final Widget child;
  final IosPageChromeWarmup? chromeWarmup;

  @override
  State<_IosPageArrival> createState() => _IosPageArrivalState();
}

class _IosPageArrivalState extends State<_IosPageArrival> {
  Completer<bool>? _pending;
  bool _settleQueued = false;
  late bool _chromeAtRest;

  // The Navigator may briefly report a completed animation while measuring
  // a hidden destination for Hero layout. That is not an on-screen arrival.
  bool get _settled => !widget.route.offstage && widget.animation.isCompleted;
  bool get _atRest => _settled && widget.secondary.isDismissed;

  @override
  void initState() {
    super.initState();
    if (!_settled) _pending = Completer<bool>();
    _chromeAtRest = _atRest;
    widget.animation.addStatusListener(_onStatus);
    widget.secondary.addStatusListener(_onStatus);
    // Registration happens while the page builds during this frame. Mark the
    // page as laid out afterwards even when the Navigator keeps this first
    // frame offstage for Hero measurement, so an empty page keeps its normal
    // entrance timing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.chromeWarmup?.pageLaidOut();
    });
  }

  @override
  void didUpdateWidget(covariant _IosPageArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
    if (oldWidget.secondary != widget.secondary) {
      oldWidget.secondary.removeStatusListener(_onStatus);
      widget.secondary.addStatusListener(_onStatus);
    }
    _chromeAtRest = _atRest;
    _queueArrival();
  }

  void _onStatus(AnimationStatus _) {
    final atRest = _atRest;
    if (_chromeAtRest != atRest) setState(() => _chromeAtRest = atRest);
    _queueArrival();
  }

  void _queueArrival() {
    if (_pending == null || !_settled || _settleQueued) return;
    _settleQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleQueued = false;
      if (!mounted || !_settled) return;
      final pending = _pending;
      if (pending == null) return;
      setState(() => _pending = null);
      pending.complete(true);
    });
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    widget.secondary.removeStatusListener(_onStatus);
    widget.chromeWarmup?.release();
    _pending?.complete(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A newly pushed route can be offstage for its first frame while Hero
    // destinations are measured. Dependents still need to know when it is
    // shown so their native views start accepting input.
    final onstage = !widget.route.offstage;
    return IosPageArrival._(
      pending: _pending?.future,
      chromeAtRest: _chromeAtRest && _pending == null,
      onstage: onstage,
      chromeWarmup: widget.chromeWarmup,
      child:
          widget.roundWhileSliding
              ? ClipRRect(
                borderRadius: iosSlidingPageRadius(
                  MediaQuery.sizeOf(context),
                  textDirection: Directionality.of(context),
                ),
                clipBehavior:
                    widget.animation.isCompleted ? Clip.none : Clip.antiAlias,
                child: widget.child,
              )
              : widget.child,
    );
  }
}
