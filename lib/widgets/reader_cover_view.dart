import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/widgets/reader_paper_turn.dart';
import 'package:wild/widgets/reader_raster_readiness.dart';

/// Retains adjacent pages for taps, drags, and hardware page turns.
/// A completed turn commits progress, and dragging can take over a settle.
class ReaderCoverController {
  ReaderCoverViewState? _view;
  bool get isTurning => _view?._busy ?? false;
  Future<void> turn(int direction, {double? startY}) async =>
      _view?.turn(direction, startY: startY);
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
    this.waitForPageContent = false,
    this.preloadAdjacentPages = true,
    this.effect = ReaderPageEffect.slide,
    this.paperColor,
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
  final bool waitForPageContent;
  final bool preloadAdjacentPages;
  final ReaderPageEffect effect;
  final Color? paperColor;
  @override
  State<ReaderCoverView> createState() => ReaderCoverViewState();
}

class ReaderCoverViewState extends State<ReaderCoverView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _progress = AnimationController(vsync: this);
  final _papers = <int, ({Widget layer, ReaderRasterReadiness readiness})>{};
  int _index = 0, _direction = 0, _generation = 0;
  ({int direction, double? startY})? _queued;
  final _reportedIndices = <int>{};
  double _width = 1, _drag = 0;
  double _height = 1, _touchY = .5;
  bool _settling = false, _dragging = false;
  bool _readinessFrameScheduled = false;
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
        widget.effect != oldWidget.effect ||
        (widget.index != oldWidget.index &&
            widget.index != _index &&
            !_reportedIndices.remove(widget.index)) ||
        !widget.active) {
      _cancel();
      _index = widget.index;
      _reportedIndices.clear();
      if (widget.revision != oldWidget.revision) _papers.clear();
    }
    if (widget.index == _index) _reportedIndices.clear();
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

  Future<void> turn(int direction, {double? startY}) async {
    if (!_active || direction.abs() != 1) return;
    if (_busy) {
      _queued = (direction: direction, startY: startY);
      return;
    }
    final target = _index + direction;
    if (target < 0 || target >= widget.pageCount) {
      widget.onBoundaryTurn?.call(direction);
      return;
    }
    if (!_isPageReady(target)) {
      setState(() => _queued = (direction: direction, startY: startY));
      return;
    }
    setState(() {
      _touchY = startY == null ? .5 : (startY / _height).clamp(0.0, 1.0);
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
    final milliseconds = widget.effect.milliseconds;
    if (!reduce && milliseconds > 0) {
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
                  milliseconds: (milliseconds * distance).round().clamp(
                    90,
                    milliseconds,
                  ),
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
    if (commit) _reportPage(_index);
    if (queued != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(turn(queued.direction, startY: queued.startY));
        }
      });
    }
  }

  void _reportPage(int index) {
    // Parent rebuilds may echo an earlier fully crossed page while a second
    // gesture is already moving. Such an echo is not an external seek.
    _reportedIndices.add(index);
    _reportedIndices.removeWhere((i) => (i - _index).abs() > 3);
    widget.onPageChanged(index);
  }

  void _updateDrag(double delta) {
    _drag += delta;
    final crossed = <int>[];
    // Carry unused distance through a page edge. The next paper can enter in
    // this same gesture, including when it grabbed an unfinished release.
    while (_drag.abs() >= _width) {
      final direction = _drag < 0 ? 1 : -1;
      final target = _index + direction;
      if (target < 0 || target >= widget.pageCount || !_isPageReady(target)) {
        break;
      }
      _index = target;
      _drag += direction * _width;
      crossed.add(_index);
    }
    final direction = _drag == 0 ? 0 : (_drag < 0 ? 1 : -1);
    final target = _index + direction;
    setState(() {
      _direction =
          target < 0 || target >= widget.pageCount || !_isPageReady(target)
              ? 0
              : direction;
      _progress.value =
          _direction == 0 ? 0 : (_drag.abs() / _width).clamp(0, 1);
    });
    for (final index in crossed) {
      _reportPage(index);
    }
  }

  void _cancelDrag() {
    if (!_dragging) return;
    _dragging = false;
    if (!_settling) unawaited(_settle(false, velocity: 0));
  }

  bool _isPageReady(int index) =>
      !widget.waitForPageContent || _papers[index]?.readiness.isReady == true;

  bool get _canPreload =>
      widget.preloadAdjacentPages && _active && !_busy && _queued == null;

  void _pageContentChanged() {
    if (!mounted ||
        !widget.waitForPageContent ||
        (!_dragging && _queued == null && !widget.preloadAdjacentPages) ||
        _readinessFrameScheduled) {
      return;
    }
    _readinessFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readinessFrameScheduled = false;
      if (!mounted || !_active) return;
      if (_dragging && !_settling) {
        _updateDrag(0);
      } else if (_queued case final pending?) {
        if (_busy || !_isPageReady(_index + pending.direction)) return;
        _queued = null;
        unawaited(turn(pending.direction, startY: pending.startY));
      } else if (_canPreload) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _paper(int index) =>
      _papers.putIfAbsent(index, () {
        final readiness = ReaderRasterReadiness(onChanged: _pageContentChanged);
        return (
          readiness: readiness,
          layer: RepaintBoundary(
            child: ReaderRasterScope(
              readiness: readiness,
              child: DecoratedBox(
                decoration: widget.paperDecoration,
                child: widget.pageBuilder(context, index),
              ),
            ),
          ),
        );
      }).layer;

  List<int> _mountedPageIndices() {
    final nearby = [
      if (_index > 0) _index - 1,
      _index,
      if (_index + 1 < widget.pageCount) _index + 1,
    ];
    if (!widget.waitForPageContent) return nearby;

    final demandedDirection =
        _queued?.direction ??
        (_dragging && _drag != 0 ? (_drag < 0 ? 1 : -1) : _direction);
    final demanded = _index + demandedDirection;
    final mounted = {
      ...nearby.where(_papers.containsKey),
      _index,
      if (nearby.contains(demanded)) demanded,
    };
    // Only start one offstage spread at a time. A gesture can demand the
    // opposite spread immediately without also starting another warmup.
    if (_canPreload && mounted.where(_papers.containsKey).every(_isPageReady)) {
      for (final index in [_index + 1, _index - 1]) {
        if (nearby.contains(index) && mounted.add(index)) break;
      }
    }
    return nearby.where(mounted.contains).toList();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      _height = constraints.maxHeight;
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      final effect =
          MediaQuery.disableAnimationsOf(context)
              ? ReaderPageEffect.none
              : widget.effect;
      _papers.removeWhere(
        (index, _) => (index - _index).abs() > 1 || index >= widget.pageCount,
      );
      final indices = _mountedPageIndices();
      final children = {for (final i in indices) i: _paper(i)};
      return Listener(
        // Flutter can report an already accepted drag's pointer cancellation
        // through onDragEnd. Cancel before that callback can commit a page.
        onPointerCancel: (_) => _cancelDrag(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart:
              !_active
                  ? null
                  : (details) {
                    if (!_active) return;
                    if (_settling) {
                      _generation++;
                      _progress.stop();
                      _settling = false;
                      _queued = null;
                    }
                    _dragging = true;
                    _touchY = (details.localPosition.dy / _height).clamp(
                      0.0,
                      1.0,
                    );
                    _drag = -_direction * _progress.value * _width;
                  },
          onHorizontalDragUpdate:
              !_active
                  ? null
                  : (details) {
                    if (!_active || _settling || !_dragging) return;
                    _touchY = (details.localPosition.dy / _height).clamp(
                      0.0,
                      1.0,
                    );
                    _updateDrag(details.delta.dx);
                  },
          onHorizontalDragCancel: _cancelDrag,
          onHorizontalDragEnd:
              !_active
                  ? null
                  : (details) {
                    if (!_active || _settling || !_dragging) return;
                    _dragging = false;
                    if (_direction == 0) {
                      if (_drag.abs() > 36) {
                        if (widget.waitForPageContent) {
                          unawaited(turn(_drag < 0 ? 1 : -1));
                        } else {
                          widget.onBoundaryTurn?.call(_drag < 0 ? 1 : -1);
                        }
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
                final turning = _direction != 0;
                final progress = _progress.value;
                // Both sheets share the same physical-pixel displacement. A
                // fractional raster edge can otherwise expose a hairline even
                // without a painted divider or the old cover shadow.
                final distance =
                    (progress * _width * pixelRatio).round() / pixelRatio;
                final offset = -_direction * distance;
                final front = math.max(_index, target);
                final paperTurn =
                    turning && effect == ReaderPageEffect.paper
                        ? ReaderPaperTurnFrame(
                          size: Size(_width, _height),
                          progress: progress,
                          touchY: _touchY,
                          forward: _direction > 0,
                          spread: widget.isSpread,
                          paper:
                              widget.paperColor ??
                              Theme.of(context).canvasColor,
                        )
                        : null;
                final layers =
                    paperTurn == null
                        ? indices
                        : [...indices.where((i) => i != _index), _index];
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final i in layers)
                      Positioned.fill(
                        key: ValueKey('cover-sheet-$i'),
                        child: Offstage(
                          offstage:
                              !turning || effect == ReaderPageEffect.none
                                  ? i != _index
                                  : i != _index && i != target,
                          child: IgnorePointer(
                            ignoring: _busy || i != _index,
                            child:
                                effect == ReaderPageEffect.paper
                                    ? ReaderPaperTurn(
                                      frame:
                                          i == _index || i == target
                                              ? paperTurn
                                              : null,
                                      outgoing: i == _index,
                                      child: children[i]!,
                                    )
                                    : _sheet(
                                      page: children[i]!,
                                      index: i,
                                      effect: effect,
                                      turning: turning,
                                      progress: progress,
                                      front: front,
                                      offset: offset,
                                    ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  );

  Widget _sheet({
    required Widget page,
    required int index,
    required ReaderPageEffect effect,
    required bool turning,
    required double progress,
    required int front,
    required double offset,
  }) {
    final topSheet = turning && index == front;
    final dx =
        !turning
            ? 0.0
            : switch (effect) {
              ReaderPageEffect.cover =>
                topSheet
                    ? index == _index
                        ? offset
                        : offset + _width
                    : 0.0,
              ReaderPageEffect.fade || ReaderPageEffect.none => 0.0,
              _ => index == _index ? offset : offset + _direction * _width,
            };
    if (effect == ReaderPageEffect.fade) {
      page = Opacity(
        opacity:
            !topSheet
                ? 1
                : index == _index
                ? 1 - progress
                : progress,
        child: page,
      );
    } else if (effect == ReaderPageEffect.cover) {
      final shadow = topSheet ? math.sin(math.pi * progress) : 0.0;
      page = DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: [
            if (shadow > 0)
              BoxShadow(
                color: Colors.black.withValues(alpha: .16 * shadow),
                offset: const Offset(-4, 0),
                blurRadius: 12 * shadow,
              ),
          ],
        ),
        child: page,
      );
    }
    return Transform.translate(
      key: ValueKey('cover-position-$index'),
      offset: Offset(dx, 0),
      child: page,
    );
  }
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
