import 'dart:async';

import 'package:flutter/material.dart';

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
    _IosPageArrival(route: route, animation: animation, child: child),
  );
}

class IosPageArrival extends InheritedWidget {
  const IosPageArrival._({required this.pending, required super.child});

  final Future<bool>? pending;

  /// Null once the page is visible at rest, or outside a Cupertino route.
  /// A pending arrival resolves false if the route is removed first.
  static Future<bool>? pendingOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<IosPageArrival>()?.pending;

  static bool hasArrivedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IosPageArrival>()?.pending ==
      null;

  @override
  bool updateShouldNotify(IosPageArrival oldWidget) =>
      oldWidget.pending != pending;
}

class _IosPageArrival extends StatefulWidget {
  const _IosPageArrival({
    required this.route,
    required this.animation,
    required this.child,
  });

  final ModalRoute<Object?> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_IosPageArrival> createState() => _IosPageArrivalState();
}

class _IosPageArrivalState extends State<_IosPageArrival> {
  Completer<bool>? _pending;
  bool _settleQueued = false;

  // The Navigator may briefly report a completed animation while measuring
  // a hidden destination for Hero layout. That is not an on-screen arrival.
  bool get _settled => !widget.route.offstage && widget.animation.isCompleted;

  @override
  void initState() {
    super.initState();
    if (!_settled) {
      _pending = Completer<bool>();
      widget.animation.addStatusListener(_onStatus);
    }
  }

  @override
  void didUpdateWidget(covariant _IosPageArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pending == null) return;
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
    _onStatus(widget.animation.status);
  }

  void _onStatus(AnimationStatus status) {
    if (!_settled || _settleQueued) return;
    _settleQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleQueued = false;
      if (!mounted || !_settled) return;
      final pending = _pending;
      if (pending == null) return;
      widget.animation.removeStatusListener(_onStatus);
      setState(() => _pending = null);
      pending.complete(true);
    });
  }

  @override
  void dispose() {
    if (_pending case final pending?) {
      widget.animation.removeStatusListener(_onStatus);
      pending.complete(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      IosPageArrival._(pending: _pending?.future, child: widget.child);
}
