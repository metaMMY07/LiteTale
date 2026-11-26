import 'dart:async';
import 'dart:collection';
import 'package:wild/services/read_request.dart';

/// Explicit QA opt-in. Contains fixed operation/phase names and durations only;
/// never URLs, query strings, credentials, response text or book identifiers.
class ReadDiagnostics {
  static bool enabled = const bool.fromEnvironment('LITETALE_READ_DIAGNOSTICS');
  static final _events = Queue<ReadTiming>();
  static List<ReadTiming> get events => List.unmodifiable(_events);
  static void clear() => _events.clear();
  static void record(String source, String phase, Duration elapsed) {
    if (!enabled) return;
    _events.add(ReadTiming(source, phase, elapsed.inMicroseconds, 'complete'));
    while (_events.length > 256) {
      _events.removeFirst();
    }
  }

  static Future<T> measure<T>(
    String source,
    String phase,
    Future<T> Function() action,
  ) async {
    if (!enabled) return action();
    final clock = Stopwatch()..start();
    var outcome = 'success';
    try {
      return await action();
    } catch (error) {
      outcome = error is ReadCancelled ? 'cancelled' : 'failed';
      rethrow;
    } finally {
      _events.add(
        ReadTiming(source, phase, clock.elapsedMicroseconds, outcome),
      );
      while (_events.length > 256) {
        _events.removeFirst();
      }
    }
  }

  static T measureSync<T>(String source, String phase, T Function() action) {
    if (!enabled) return action();
    final clock = Stopwatch()..start();
    var outcome = 'success';
    try {
      return action();
    } catch (error) {
      outcome = error is ReadCancelled ? 'cancelled' : 'failed';
      rethrow;
    } finally {
      _events.add(
        ReadTiming(source, phase, clock.elapsedMicroseconds, outcome),
      );
      while (_events.length > 256) {
        _events.removeFirst();
      }
    }
  }
}

class ReadTiming {
  const ReadTiming(this.source, this.phase, this.microseconds, this.outcome);
  final String source, phase, outcome;
  final int microseconds;
}
