import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/settings/reading_statistics.dart';

/// Tracks reading only while the reader is visible, foregrounded and active.
/// Place it inside the reader route around the content that is actually shown.
class ReadingSessionScope extends StatefulWidget {
  const ReadingSessionScope({
    super.key,
    required this.bookId,
    required this.title,
    required this.child,
    this.isReading = true,
    this.active = true,
    this.flushInterval = const Duration(seconds: 30),
    this.routeCheckInterval = const Duration(milliseconds: 500),
    this.idleTimeout = const Duration(minutes: 5),
    this.clock,
  });

  final String bookId;
  final String title;
  final Widget child;

  /// Set false while chapter content is still loading or otherwise not readable.
  final bool isReading;

  /// A host can use this to suspend timing during reader-owned overlays.
  final bool active;
  final Duration flushInterval;
  final Duration routeCheckInterval;
  final Duration idleTimeout;
  final DateTime Function()? clock;

  /// Call from reader controls for keyboard, volume-key or accessibility input.
  static void recordActivity(BuildContext context) {
    context
        .findAncestorStateOfType<ReadingSessionScopeState>()
        ?.recordActivity();
  }

  @override
  ReadingSessionScopeState createState() => ReadingSessionScopeState();
}

class ReadingSessionScopeState extends State<ReadingSessionScope>
    with WidgetsBindingObserver {
  ReadingStatisticsCubit? _statistics;
  ModalRoute<dynamic>? _route;
  Timer? _routeCheckTimer;
  Timer? _flushTimer;
  String? _sessionId;
  DateTime? _lastActivity;
  DateTime? _lastPointerActivity;
  bool _starting = false;
  int _revision = 0;

  DateTime get _now =>
      widget.clock?.call() ?? _statistics?.currentTime ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastActivity = _now;
    _routeCheckTimer = Timer.periodic(
      widget.routeCheckInterval,
      (_) => _sync(),
    );
    _flushTimer = Timer.periodic(widget.flushInterval, (_) => _flush());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _statistics = context.read<ReadingStatisticsCubit>();
    } catch (_) {
      _statistics = null;
    }
    _route = ModalRoute.of(context);
    _sync();
  }

  @override
  void didUpdateWidget(covariant ReadingSessionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flushInterval != widget.flushInterval) {
      _flushTimer?.cancel();
      _flushTimer = Timer.periodic(widget.flushInterval, (_) => _flush());
    }
    if (oldWidget.routeCheckInterval != widget.routeCheckInterval) {
      _routeCheckTimer?.cancel();
      _routeCheckTimer = Timer.periodic(
        widget.routeCheckInterval,
        (_) => _sync(),
      );
    }
    if (oldWidget.bookId != widget.bookId || oldWidget.title != widget.title) {
      _stopSession();
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  void recordActivity() {
    _lastActivity = _now;
    _sync();
  }

  bool get _canCount {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final route = _route;
    final lastActivity = _lastActivity;
    return widget.isReading &&
        widget.active &&
        lifecycle == AppLifecycleState.resumed &&
        (route == null || route.isCurrent) &&
        (lastActivity == null ||
            _now.difference(lastActivity) <= widget.idleTimeout);
  }

  void _sync() {
    if (!mounted || _statistics == null) return;
    if (!_canCount) {
      if (_starting) _revision++;
      _stopSession();
      return;
    }
    if (_sessionId != null || _starting) return;
    _starting = true;
    final revision = ++_revision;
    unawaited(_startSession(revision));
  }

  Future<void> _startSession(int revision) async {
    final cubit = _statistics;
    if (cubit == null) {
      _starting = false;
      return;
    }
    try {
      final sessionId = await cubit.startSession(
        widget.bookId,
        widget.title,
        at: _now,
      );
      if (!mounted || revision != _revision || !_canCount) {
        await cubit.endSession(sessionId, at: _now);
      } else {
        _sessionId = sessionId;
      }
    } catch (_) {
      // A failed local read must not crash the reader. The next lifecycle or
      // activity update can try again after the storage layer recovers.
    } finally {
      _starting = false;
      // Retry on the next visibility tick; never spin on a storage failure.
    }
  }

  void _flush() {
    final sessionId = _sessionId;
    final cubit = _statistics;
    if (sessionId == null || cubit == null) return;
    if (!_canCount) {
      _sync();
      return;
    }
    cubit.recordElapsed(sessionId, _now);
  }

  void _stopSession() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    _sessionId = null;
    _revision++;
    final cubit = _statistics;
    if (cubit != null) unawaited(cubit.endSession(sessionId, at: _now));
  }

  void _onPointerActivity(PointerEvent event) {
    final now = _now;
    final last = _lastPointerActivity;
    if (event is PointerDownEvent ||
        event is PointerSignalEvent ||
        last == null ||
        now.difference(last) >= const Duration(seconds: 1)) {
      _lastPointerActivity = now;
      recordActivity();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointerActivity,
    onPointerMove: _onPointerActivity,
    onPointerSignal: _onPointerActivity,
    child: widget.child,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _routeCheckTimer?.cancel();
    _flushTimer?.cancel();
    _stopSession();
    super.dispose();
  }
}
