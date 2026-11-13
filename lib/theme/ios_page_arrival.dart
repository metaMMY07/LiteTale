import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wild/theme/ios_dock_insets.dart';

/// Preserves the Cupertino slide and edge swipe while exposing the first
/// settled frame to work that should not compete with the entrance.
class LiteTaleCupertinoTransitionsBuilder
    extends CupertinoPageTransitionsBuilder {
  const LiteTaleCupertinoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => super.buildTransitions(
    route,
    context,
    animation,
    secondaryAnimation,
    _IosPageArrival(
      route: route,
      animation: animation,
      // A delegated Cupertino transition may supply an idle animation to
      // buildTransitions even while the page above is moving.
      secondary: route.secondaryAnimation ?? secondaryAnimation,
      child: IosDockInsets.applyToPage(context, route, child),
    ),
  );
}

class IosPageArrival extends InheritedWidget {
  const IosPageArrival._({
    required this.pending,
    required this.chromeAtRest,
    required super.child,
  });

  final Future<bool>? pending;
  final bool chromeAtRest;

  /// Null once the page is visible at rest, or outside a Cupertino route.
  /// A pending arrival resolves false if the route is removed first.
  static Future<bool>? pendingOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<IosPageArrival>()?.pending;

  /// Observe the boundaries of a slide in either direction, including the
  /// page underneath it. This does not rebuild listeners for each tick.
  static bool chromeAtRestOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<IosPageArrival>()
          ?.chromeAtRest ??
      true;

  @override
  bool updateShouldNotify(IosPageArrival oldWidget) =>
      oldWidget.pending != pending || oldWidget.chromeAtRest != chromeAtRest;
}

class _IosPageArrival extends StatefulWidget {
  const _IosPageArrival({
    required this.route,
    required this.animation,
    required this.secondary,
    required this.child,
  });

  final ModalRoute<Object?> route;
  final Animation<double> animation;
  final Animation<double> secondary;
  final Widget child;

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
    _pending?.complete(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IosPageArrival._(
    pending: _pending?.future,
    chromeAtRest: _chromeAtRest && _pending == null,
    child: widget.child,
  );
}
