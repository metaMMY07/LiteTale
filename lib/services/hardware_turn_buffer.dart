import 'dart:async';
import '../utils/controller_event.dart';

/// Preserve short hardware bursts while a page is settling, without allowing
/// old keys to escape into another route, lifecycle or chapter long afterwards.
class HardwareTurnBuffer {
  HardwareTurnBuffer({
    required this.active,
    required this.busy,
    required this.dispatch,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final bool Function() active, busy;
  final void Function(ReaderControllerEventArgs) dispatch;
  final _events = <({ReaderControllerEventArgs event, DateTime time})>[];
  Timer? _timer;
  bool _closed = false;
  void add(ReaderControllerEventArgs event) {
    if (_closed || !active()) return;
    if (_events.length == 4) _events.removeAt(0);
    _events.add((event: event, time: _now()));
    _pump();
  }

  void _pump() {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    if (!active()) {
      _events.clear();
      return;
    }
    _events.removeWhere(
      (e) => _now().difference(e.time) > const Duration(milliseconds: 1500),
    );
    if (_events.isEmpty) return;
    if (!busy()) dispatch(_events.removeAt(0).event);
    if (_events.isNotEmpty) {
      _timer = Timer(const Duration(milliseconds: 16), _pump);
    }
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
    _events.clear();
  }
}
