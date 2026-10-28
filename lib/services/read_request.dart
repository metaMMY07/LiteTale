import 'dart:async';

/// Internal lifecycle outcome, never a website or authentication error.
class ReadCancelled implements Exception {
  const ReadCancelled();
  @override
  String toString() => '请求已取消';
}

/// Cancellation belongs to a caller, not to a shared Future. The zone lets
/// existing source interfaces carry it through nested asynchronous reads.
class ReadRequest {
  static final _zoneKey = Object();
  static ReadRequest? get current => Zone.current[_zoneKey] as ReadRequest?;
  static T run<T>(ReadRequest request, T Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: request});

  final _listeners = <void Function(Object)>{};
  Object? _reason;
  bool get isCancelled => _reason != null;
  Object get reason => _reason ?? const ReadCancelled();

  void check() {
    if (_reason case final error?) throw error;
  }

  void cancel([Object error = const ReadCancelled()]) {
    if (isCancelled) return;
    _reason = error;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener(error);
      } catch (_) {
        // A transport cleanup failure must not prevent other subscribers from
        // receiving cancellation or leave their futures unresolved.
      }
    }
  }

  void Function() onCancel(void Function(Object) listener) {
    if (isCancelled) {
      listener(reason);
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Completes promptly on cancellation, while still handling late errors.
  /// Physical transport cleanup must also subscribe to [onCancel].
  Future<T> wait<T>(Future<T> future) {
    final result = Completer<T>();
    final remove = onCancel((error) {
      if (!result.isCompleted) result.completeError(error);
    });
    future.then(
      (value) {
        remove();
        if (!result.isCompleted) {
          if (isCancelled) {
            result.completeError(reason);
          } else {
            result.complete(value);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        remove();
        if (!result.isCompleted) {
          result.completeError(isCancelled ? reason : error, stack);
        }
      },
    );
    return result.future;
  }
}

/// Coalesces loads without letting one departing consumer cancel another.
/// Each physical load has its own cancellation scope; no values are retained.
class SharedReadPool<K, V> {
  final _pending = <K, _SharedRead<V>>{};
  int get length => _pending.length;
  bool contains(K key) => _pending[key]?.request.isCancelled == false;

  Future<V> run(K key, Future<V> Function() load) {
    final caller = ReadRequest.current;
    if (caller?.isCancelled == true) return Future.error(caller!.reason);
    var job = _pending[key];
    if (job == null || job.request.isCancelled) {
      job = _SharedRead<V>();
      _pending[key] = job;
      final created = job;
      scheduleMicrotask(() async {
        try {
          created.request.check();
          final value = await ReadRequest.run(
            created.request,
            () => created.request.wait(Future<V>.sync(load)),
          );
          created.request.check();
          for (final subscriber in created.subscribers.toList()) {
            subscriber.remove();
            if (!subscriber.result.isCompleted) {
              subscriber.result.complete(value);
            }
          }
        } catch (error, stack) {
          for (final subscriber in created.subscribers.toList()) {
            subscriber.remove();
            if (!subscriber.result.isCompleted) {
              subscriber.result.completeError(error, stack);
            }
          }
        } finally {
          created.subscribers.clear();
          if (identical(_pending[key], created)) {
            _pending.remove(key);
          }
        }
      });
    }
    final shared = job;
    final subscriber = _ReadSubscriber<V>();
    shared.subscribers.add(subscriber);
    subscriber.remove =
        caller?.onCancel((error) {
          shared.subscribers.remove(subscriber);
          if (!subscriber.result.isCompleted) {
            subscriber.result.completeError(error);
          }
          if (shared.subscribers.isEmpty) {
            shared.request.cancel(error);
            if (identical(_pending[key], shared)) {
              _pending.remove(key);
            }
          }
        }) ??
        () {};
    return subscriber.result.future;
  }

  void clear() {
    final jobs = _pending.values.toList();
    _pending.clear();
    for (final job in jobs) {
      job.request.cancel();
    }
  }
}

class _SharedRead<V> {
  final request = ReadRequest();
  final subscribers = <_ReadSubscriber<V>>{};
}

class _ReadSubscriber<V> {
  final result = Completer<V>();
  void Function() remove = () {};
}
