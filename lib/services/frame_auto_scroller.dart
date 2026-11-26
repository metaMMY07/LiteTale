import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Use the display's frame clock, with a time based speed at any refresh rate.
class FrameAutoScroller {
  FrameAutoScroller({
    required TickerProvider vsync,
    required this.controller,
    required this.pixelsPerSecond,
    required this.onEnd,
  }) {
    _ticker = vsync.createTicker(_tick);
  }
  final ScrollController controller;
  final double Function() pixelsPerSecond;
  final VoidCallback onEnd;
  late final Ticker _ticker;
  Duration? _last;
  void start() {
    _last = null;
    if (!_ticker.isActive) _ticker.start();
  }

  void stop() {
    _ticker.stop();
    _last = null;
  }

  void dispose() => _ticker.dispose();
  void _tick(Duration elapsed) {
    final previous = _last;
    _last = elapsed;
    if (previous == null || !controller.hasClients) return;
    final seconds =
        (elapsed - previous).inMicroseconds.clamp(0, 64000) / 1000000;
    final position = controller.position;
    final next = (position.pixels + pixelsPerSecond() * seconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next >= position.maxScrollExtent) {
      stop();
      onEnd();
    }
    if (next != position.pixels) controller.jumpTo(next);
  }
}
