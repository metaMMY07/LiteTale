import 'dart:async';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:wild/widgets/reader_raster_readiness.dart';

/// Two opaque sheets travel together, matching the supplied reading video.
/// The historical cover-view API stays compatible with tap/volume controls.
/// A completed turn alone commits progress; dragging can take over a settle.
class ReaderCoverController {
  ReaderCoverViewState? _view;
  bool get isTurning => _view?._busy ?? false;
  Future<void> turn(int direction) async => _view?.turn(direction);
  void dispose() {
    _view = null;
  }
}

class ReaderCoverView extends StatefulWidget {
  const ReaderCoverView({
    super.key,
    required this.controller,
    required this.index,
    required this.pageCount,
    required this.pageBuilder,
    required this.onPageChanged,
    required this.paperDecoration,
    this.onBoundaryTurn,
    this.revision,
    this.active = true,
    this.leafCount,
    this.isSpread = false,
  });
  final ReaderCoverController controller;
  final int index, pageCount;
  final IndexedWidgetBuilder pageBuilder;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int>? onBoundaryTurn;
  final Decoration paperDecoration;
  final Object? revision;
  final bool active;
  final int? leafCount;
  final bool isSpread;
  @override
  State<ReaderCoverView> createState() => ReaderCoverViewState();
}

class ReaderCoverViewState extends State<ReaderCoverView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _turnDuration = Duration(milliseconds: 360);
  late final _progress = AnimationController(vsync: this);
  final _papers = <int, Widget>{};
  int _index = 0, _direction = 0, _generation = 0;
  int? _queued;
  double _width = 1, _drag = 0;
  bool _settling = false, _dragging = false;
  bool get _busy => _settling || _dragging || _direction != 0;
  bool get _active =>
      widget.active &&
      ModalRoute.of(context)?.isCurrent != false &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    widget.controller._view = this;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(ReaderCoverView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._view = null;
      widget.controller._view = this;
    }
    if (widget.revision != oldWidget.revision ||
        widget.index != _index ||
        !widget.active) {
      _cancel();
      _index = widget.index;
      if (widget.revision != oldWidget.revision) _papers.clear();
    }
    if (widget.isSpread &&
        oldWidget.leafCount?.isOdd == true &&
        (widget.leafCount ?? 0) > oldWidget.leafCount!) {
      _papers.remove(oldWidget.leafCount! ~/ 2);
    }
  }

  void _cancel() {
    _generation++;
    _progress.stop();
    _direction = 0;
    _drag = 0;
    _dragging = false;
    _settling = false;
    _queued = null;
    _progress.value = 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    // The inactive build removes recognizers. Resume must rebuild too; waiting
    // for a tap used to leave the first resumed swipe without any listener.
    setState(() {
      if (state != AppLifecycleState.resumed) _cancel();
    });
  }

  @override
  void dispose() {
    _cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller._view == this) widget.controller._view = null;
    _progress.dispose();
    super.dispose();
  }

  Future<void> turn(int direction) async {
    if (!_active || direction.abs() != 1) return;
    if (_busy) {
      _queued = direction;
      return;
    }
    final target = _index + direction;
    if (target < 0 || target >= widget.pageCount) {
      widget.onBoundaryTurn?.call(direction);
      return;
    }
    setState(() {
      _direction = direction;
      _progress.value = 0;
    });
    await _settle(true);
  }

  Future<void> _settle(bool commit, {double? velocity}) async {
    if (_direction == 0) return;
    _settling = true;
    final generation = ++_generation;
    final direction = _direction;
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (!reduce) {
      try {
        if (velocity != null) {
          // The same spring/tolerance as Flutter's page scrolling, with the
          // release speed in viewport units. Never restart the tap ease-in
          // while the page is already moving with a finger.
          final pixels = _width * MediaQuery.devicePixelRatioOf(context);
          await _progress
              .animateWith(
                _DragPageSimulation(
                  ScrollSpringSimulation(
                    const PageScrollPhysics().spring,
                    _progress.value,
                    commit ? 1 : 0,
                    velocity,
                    tolerance: Tolerance(
                      distance: 1 / pixels,
                      velocity: 20 / pixels,
                    ),
                  ),
                  commit ? 1 : 0,
                ),
              )
              .orCancel;
        } else {
          // Preserve the accepted click/volume-key timing exactly.
          final distance = ((commit ? 1.0 : 0.0) - _progress.value).abs();
          await _progress
              .animateTo(
                commit ? 1 : 0,
                duration: Duration(
                  milliseconds: (_turnDuration.inMilliseconds * distance)
                      .round()
                      .clamp(90, _turnDuration.inMilliseconds),
                ),
                curve: Curves.easeInOutCubic,
              )
              .orCancel;
        }
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || generation != _generation) return;
    if (!_active) {
      setState(_cancel);
      return;
    }
    final queued = _queued;
    _queued = null;
    setState(() {
      if (commit) _index += direction;
      _direction = 0;
      _settling = false;
      _progress.value = 0;
    });
    if (commit) widget.onPageChanged(_index);
    if (queued != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(turn(queued));
      });
    }
  }

  Widget _paper(int index) => _papers.putIfAbsent(
    index,
    () => RepaintBoundary(
      child: ReaderRasterScope(
        readiness: ReaderRasterReadiness(onChanged: () {}),
        child: DecoratedBox(
          decoration: widget.paperDecoration,
          child: widget.pageBuilder(context, index),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      _papers.removeWhere(
        (index, _) => (index - _index).abs() > 1 || index >= widget.pageCount,
      );
      final indices = [
        if (_index > 0) _index - 1,
        _index,
        if (_index + 1 < widget.pageCount) _index + 1,
      ];
      final children = {for (final i in indices) i: _paper(i)};
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart:
            !_active
                ? null
                : (_) {
                  if (!_active) return;
                  if (_settling) {
                    _generation++;
                    _progress.stop();
                    _settling = false;
                    _queued = null;
                  }
                  _dragging = true;
                  _drag = -_direction * _progress.value * _width;
                },
        onHorizontalDragUpdate:
            !_active
                ? null
                : (details) {
                  if (!_active || _settling || !_dragging) return;
                  _drag += details.delta.dx;
                  final direction = _drag < 0 ? 1 : -1;
                  final target = _index + direction;
                  if (target < 0 || target >= widget.pageCount) {
                    if (_direction != 0) {
                      setState(() {
                        _direction = 0;
                        _progress.value = 0;
                      });
                    }
                    return;
                  }
                  if (_direction != direction) {
                    setState(() => _direction = direction);
                  }
                  _progress.value = (_drag.abs() / _width).clamp(0, 1);
                },
        onHorizontalDragCancel: () {
          if (!_dragging) return;
          _dragging = false;
          if (!_settling) unawaited(_settle(false, velocity: 0));
        },
        onHorizontalDragEnd:
            !_active
                ? null
                : (details) {
                  if (!_active || _settling || !_dragging) return;
                  _dragging = false;
                  if (_direction == 0) {
                    if (_drag.abs() > 36) {
                      widget.onBoundaryTurn?.call(_drag < 0 ? 1 : -1);
                    }
                    return;
                  }
                  final velocity = details.primaryVelocity ?? 0;
                  final forward = velocity * -_direction;
                  unawaited(
                    _settle(
                      forward > 350 ||
                          (forward >= -350 && _progress.value > .22),
                      velocity: forward / _width,
                    ),
                  );
                },
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _progress,
            builder: (context, _) {
              final target = _index + _direction;
              // Both sheets share the same physical-pixel displacement. A
              // fractional raster edge can otherwise expose a hairline even
              // without a painted divider or the old cover shadow.
              final distance =
                  (_progress.value * _width * pixelRatio).round() / pixelRatio;
              final offset = -_direction * distance;
              return Stack(
                fit: StackFit.expand,
                children: [
                  for (final i in indices)
                    Positioned.fill(
                      key: ValueKey('cover-sheet-$i'),
                      child: Offstage(
                        offstage:
                            _direction == 0
                                ? i != _index
                                : i != _index && i != target,
                        child: IgnorePointer(
                          ignoring: _busy || i != _index,
                          child: Transform.translate(
                            key: ValueKey('cover-position-$i'),
                            offset: Offset(
                              _direction == 0
                                  ? 0
                                  : i == _index
                                  ? offset
                                  : offset + _direction * _width,
                              0,
                            ),
                            child: children[i] ?? const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

/// End a fast release as soon as its target edge is visually reached, rather
/// than holding input while an off-screen spring overshoot settles invisibly.
class _DragPageSimulation extends Simulation {
  _DragPageSimulation(this.spring, this.target);
  final ScrollSpringSimulation spring;
  final double target;

  @override
  bool isDone(double time) =>
      spring.isDone(time) ||
      (target == 1 ? spring.x(time) >= 1 : spring.x(time) <= 0);

  @override
  double x(double time) => isDone(time) ? target : spring.x(time).clamp(0, 1);

  @override
  double dx(double time) => isDone(time) ? 0 : spring.dx(time);
}
