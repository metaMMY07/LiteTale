import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/read_result_cache.dart';

void main() {
  var now = DateTime.utc(2026, 10, 18);

  ReadResultCache<String, String> cache({
    int maxEntries = 3,
    int maxWeight = 100,
    Duration ttl = const Duration(minutes: 5),
    bool Function(String)? cacheable,
  }) => ReadResultCache(
    maxEntries: maxEntries,
    maxWeight: maxWeight,
    ttl: ttl,
    weightOf: (value) => value.length,
    cacheable: cacheable,
    now: () => now,
  );

  setUp(() => now = DateTime.utc(2026, 10, 18));

  test('concurrent callers share one Future and one successful load', () async {
    final reads = cache();
    final loading = Completer<String>();
    var calls = 0;
    Future<String> load() {
      calls++;
      return loading.future;
    }

    final first = reads.getOrLoad('chapter', load);
    final second = reads.getOrLoad('chapter', load);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    loading.complete('content');
    expect(await first, 'content');
    expect(await second, 'content');
    expect(await reads.getOrLoad('chapter', load), 'content');
    expect(calls, 1);
    expect(reads.length, 1);
    expect(reads.retainedWeight, 7);
  });

  test('both asynchronous and synchronous failures can be retried', () async {
    final reads = cache();
    var calls = 0;
    Future<String> load() {
      calls++;
      if (calls == 1) return Future.error(StateError('network'));
      if (calls == 2) throw StateError('synchronous setup');
      return Future.value('recovered');
    }

    await expectLater(reads.getOrLoad('a', load), throwsStateError);
    expect(reads.length, 0);
    await expectLater(reads.getOrLoad('a', load), throwsStateError);
    expect(reads.retainedWeight, 0);
    expect(await reads.getOrLoad('a', load), 'recovered');
    expect(calls, 3);
  });

  test('TTL starts at completion and hits do not extend it', () async {
    final reads = cache(ttl: const Duration(seconds: 5));
    final loading = Completer<String>();
    final pending = reads.getOrLoad('a', () => loading.future);
    now = now.add(const Duration(seconds: 20));
    loading.complete('one');
    await pending;
    now = now.add(const Duration(seconds: 4));
    expect(await reads.getOrLoad('a', () async => 'unexpected'), 'one');
    now = now.add(const Duration(seconds: 1));
    expect(reads.peek('a'), isNull);
    expect(reads.length, 0);
    expect(reads.retainedWeight, 0);
    expect(await reads.getOrLoad('a', () async => 'two'), 'two');
  });

  test('cache hits promote LRU order and peek does not', () async {
    final reads = cache(maxEntries: 2);
    await reads.getOrLoad('a', () async => 'a');
    await reads.getOrLoad('b', () async => 'bb');
    expect(await reads.getOrLoad('a', () async => 'unexpected'), 'a');
    expect(reads.peek('b'), 'bb');
    await reads.getOrLoad('c', () async => 'ccc');
    expect(reads.peek('a'), 'a');
    expect(reads.peek('b'), isNull);
    expect(reads.peek('c'), 'ccc');
    expect(reads.length, 2);
    expect(reads.retainedWeight, 4);
  });

  test('weight limit evicts LRU entries until the total fits', () async {
    final reads = cache(maxEntries: 10, maxWeight: 6);
    await reads.getOrLoad('a', () async => 'aa');
    await reads.getOrLoad('b', () async => 'bb');
    await reads.getOrLoad('c', () async => 'cc');
    await reads.getOrLoad('a', () async => 'unexpected');
    await reads.getOrLoad('d', () async => 'dddd');
    expect(reads.peek('a'), 'aa');
    expect(reads.peek('b'), isNull);
    expect(reads.peek('c'), isNull);
    expect(reads.peek('d'), 'dddd');
    expect(reads.length, 2);
    expect(reads.retainedWeight, 6);
  });

  test('expired entries are removed before evicting a fresh result', () async {
    final reads = cache(maxEntries: 2, maxWeight: 6);
    await reads.getOrLoad('a', () async => 'aaa');
    now = now.add(const Duration(minutes: 4));
    await reads.getOrLoad('b', () async => 'bbb');
    now = now.add(const Duration(minutes: 1));
    await reads.getOrLoad('c', () async => 'ccc');
    expect(reads.peek('a'), isNull);
    expect(reads.peek('b'), 'bbb');
    expect(reads.peek('c'), 'ccc');
    expect(reads.retainedWeight, 6);
    now = now.add(const Duration(minutes: 5));
    expect(reads.length, 0);
    expect(reads.retainedWeight, 0);
  });

  test('clear synchronously drops values and prevents old writeback', () async {
    final reads = cache();
    await reads.getOrLoad('retained', () async => 'content');
    final old = Completer<String>();
    final oldPending = reads.getOrLoad('a', () => old.future);
    reads.clear();
    expect(reads.length, 0);
    expect(reads.retainedWeight, 0);
    expect(await reads.getOrLoad('a', () async => 'new'), 'new');
    old.complete('old');
    expect(await oldPending, 'old');
    expect(reads.peek('a'), 'new');
    expect(reads.length, 1);
    expect(reads.retainedWeight, 3);
  });

  for (final oldFails in [false, true]) {
    test(
      'old ${oldFails ? 'failure' : 'completion'} cannot remove a new load',
      () async {
        final reads = cache();
        final old = Completer<String>();
        final oldPending = reads.getOrLoad('a', () => old.future);
        final oldOutcome = expectLater(
          oldPending,
          oldFails ? throwsStateError : completion('old'),
        );
        reads.clear();
        final fresh = Completer<String>();
        final freshPending = reads.getOrLoad('a', () => fresh.future);
        if (oldFails) {
          old.completeError(StateError('old error'));
        } else {
          old.complete('old');
        }
        await oldOutcome;
        var extraLoads = 0;
        final shared = reads.getOrLoad('a', () async {
          extraLoads++;
          return 'wrong';
        });
        expect(identical(shared, freshPending), isTrue);
        expect(reads.peek('a'), isNull);
        fresh.complete('new');
        expect(await shared, 'new');
        expect(extraLoads, 0);
        expect(reads.peek('a'), 'new');
      },
    );
  }

  test(
    'oversized and invalid results return without displacing cache',
    () async {
      final reads = cache(maxWeight: 5, cacheable: (value) => value != 'bad');
      await reads.getOrLoad('a', () async => 'valid');
      expect(await reads.getOrLoad('big', () async => 'too big'), 'too big');
      expect(await reads.getOrLoad('invalid', () async => 'bad'), 'bad');
      expect(reads.peek('a'), 'valid');
      expect(reads.peek('big'), isNull);
      expect(reads.peek('invalid'), isNull);
      expect(reads.length, 1);
      expect(reads.retainedWeight, 5);
      expect(await reads.getOrLoad('invalid', () async => 'good'), 'good');
      expect(reads.peek('invalid'), 'good');
    },
  );

  test('zero limits disable retention but still merge loads', () async {
    for (final reads in [
      cache(maxEntries: 0),
      cache(maxWeight: 0),
      cache(ttl: Duration.zero),
    ]) {
      final pending = Completer<String>();
      final first = reads.getOrLoad('a', () => pending.future);
      expect(
        identical(reads.getOrLoad('a', () async => 'wrong'), first),
        isTrue,
      );
      pending.complete('result');
      expect(await first, 'result');
      expect(reads.length, 0);
      expect(reads.retainedWeight, 0);
    }
  });

  test('nullable successful values can be retained', () async {
    final reads = ReadResultCache<String, String?>(
      maxEntries: 1,
      maxWeight: 1,
      ttl: const Duration(minutes: 1),
      weightOf: (_) => 1,
    );
    var calls = 0;
    Future<String?> load() async {
      calls++;
      return null;
    }

    expect(await reads.getOrLoad('a', load), isNull);
    expect(await reads.getOrLoad('a', load), isNull);
    expect(calls, 1);
    expect(reads.length, 1);
  });
}
