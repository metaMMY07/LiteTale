/// A bounded cache for successful read results, with one load per key in flight.
///
/// TTL starts when a load succeeds. Cache hits update LRU order; [peek] does not.
/// A zero entry limit, weight limit, or TTL disables retention while still
/// coalescing concurrent loads. Values should not change weight after insertion.
class ReadResultCache<K, V> {
  ReadResultCache({
    required this.maxEntries,
    required this.maxWeight,
    required this.ttl,
    required int Function(V value) weightOf,
    bool Function(V value)? cacheable,
    DateTime Function()? now,
  }) : _weightOf = weightOf,
       _cacheable = cacheable,
       _now = now ?? DateTime.now {
    if (maxEntries < 0) {
      throw ArgumentError.value(
        maxEntries,
        'maxEntries',
        'Must be nonnegative',
      );
    }
    if (maxWeight < 0) {
      throw ArgumentError.value(maxWeight, 'maxWeight', 'Must be nonnegative');
    }
    if (ttl.isNegative) {
      throw ArgumentError.value(ttl, 'ttl', 'Must be nonnegative');
    }
  }

  final int maxEntries;
  final int maxWeight;
  final Duration ttl;
  final int Function(V value) _weightOf;
  final bool Function(V value)? _cacheable;
  final DateTime Function() _now;

  final _entries = <K, _ReadResultEntry<V>>{};
  final _inFlight = <K, Future<V>>{};
  var _retainedWeight = 0;
  var _generation = 0;

  int get length {
    _removeExpired(_now());
    return _entries.length;
  }

  int get retainedWeight {
    _removeExpired(_now());
    return _retainedWeight;
  }

  /// Returns an unexpired result without starting a load or changing LRU order.
  V? peek(K key) => _find(key)?.value;

  Future<V> getOrLoad(K key, Future<V> Function() load) {
    final entry = _find(key);
    if (entry != null) {
      _entries.remove(key);
      _entries[key] = entry;
      return Future<V>.value(entry.value);
    }

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final generation = _generation;
    late final Future<V> pending;
    // Register before invoking user code, including a synchronously throwing
    // loader or one that clears the cache and immediately starts another load.
    pending = Future<V>.microtask(load)
        .then((value) {
          if (generation == _generation) _retain(key, value, generation);
          return value;
        })
        .whenComplete(() {
          // An older generation must not remove the replacement request.
          if (identical(_inFlight[key], pending)) _inFlight.remove(key);
        });
    _inFlight[key] = pending;
    return pending;
  }

  /// Drops retained results and detaches all previous in-flight loads.
  ///
  /// Existing callers still receive those loads' results or errors, but neither
  /// completion nor failure can change this generation's entries or requests.
  void clear() {
    _generation++;
    _entries.clear();
    _inFlight.clear();
    _retainedWeight = 0;
  }

  _ReadResultEntry<V>? _find(K key) {
    final entry = _entries[key];
    if (entry != null && !entry.expiresAt.isAfter(_now())) {
      _entries.remove(key);
      _retainedWeight -= entry.weight;
      return null;
    }
    return entry;
  }

  void _retain(K key, V value, int generation) {
    if (maxEntries == 0 || maxWeight == 0 || ttl == Duration.zero) return;
    if (_cacheable != null && !_cacheable(value)) return;
    final weight = _weightOf(value);
    if (weight < 0) {
      throw ArgumentError.value(
        weight,
        'weightOf(value)',
        'Must be nonnegative',
      );
    }
    if (weight > maxWeight || generation != _generation) return;

    final now = _now();
    _removeExpired(now);
    final previous = _entries.remove(key);
    if (previous != null) _retainedWeight -= previous.weight;
    _entries[key] = _ReadResultEntry(
      value: value,
      weight: weight,
      expiresAt: now.add(ttl),
    );
    _retainedWeight += weight;

    while (_entries.length > maxEntries || _retainedWeight > maxWeight) {
      final oldest = _entries.remove(_entries.keys.first)!;
      _retainedWeight -= oldest.weight;
    }
  }

  void _removeExpired(DateTime now) {
    _entries.removeWhere((key, entry) {
      if (entry.expiresAt.isAfter(now)) return false;
      _retainedWeight -= entry.weight;
      return true;
    });
  }
}

class _ReadResultEntry<V> {
  const _ReadResultEntry({
    required this.value,
    required this.weight,
    required this.expiresAt,
  });

  final V value;
  final int weight;
  final DateTime expiresAt;
}
