import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/read_request.dart';

void main() {
  test(
    'failing cleanup cannot strand the remaining cancellation listeners',
    () async {
      final request = ReadRequest();
      final gate = Completer<int>();
      request.onCancel((_) => throw StateError('socket cleanup failed'));
      final pending = request.wait(gate.future);
      final checked = expectLater(pending, throwsA(isA<ReadCancelled>()));
      request.cancel();
      await checked;
      gate.completeError(StateError('late read failure'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('one subscriber cancels while the shared read still succeeds', () async {
    final pool = SharedReadPool<String, int>();
    final gate = Completer<int>();
    final a = ReadRequest(), b = ReadRequest();
    var loads = 0, physicalCancellations = 0;
    Future<int> load() {
      loads++;
      ReadRequest.current!.onCancel((_) => physicalCancellations++);
      return gate.future;
    }

    final first = ReadRequest.run(a, () => pool.run('same', load));
    final second = ReadRequest.run(b, () => pool.run('same', load));
    final cancelled = expectLater(first, throwsA(isA<ReadCancelled>()));
    await Future<void>.delayed(Duration.zero);
    a.cancel();
    await cancelled;
    expect(physicalCancellations, 0);
    gate.complete(42);
    expect(await second, 42);
    expect(loads, 1);
    expect(pool.length, 0);
  });

  test('last subscriber cancels the physical scope exactly once', () async {
    final pool = SharedReadPool<String, int>();
    final gate = Completer<int>();
    final a = ReadRequest(), b = ReadRequest();
    var cancellations = 0;
    Future<int> load() {
      ReadRequest.current!.onCancel((_) => cancellations++);
      return gate.future;
    }

    final first = ReadRequest.run(a, () => pool.run('key', load));
    final second = ReadRequest.run(b, () => pool.run('key', load));
    final checked = Future.wait([
      expectLater(first, throwsA(isA<ReadCancelled>())),
      expectLater(second, throwsA(isA<ReadCancelled>())),
    ]);
    await Future<void>.delayed(Duration.zero);
    a.cancel();
    b.cancel();
    b.cancel();
    await checked;
    expect(cancellations, 1);
    expect(pool.length, 0);
    gate.completeError(StateError('late error is handled'));
    await Future<void>.delayed(Duration.zero);
  });

  test('old cleanup cannot remove the new same-key read', () async {
    final pool = SharedReadPool<String, int>();
    final oldGate = Completer<int>(), newGate = Completer<int>();
    final a = ReadRequest();
    final first = ReadRequest.run(
      a,
      () => pool.run('key', () => oldGate.future),
    );
    final checked = expectLater(first, throwsA(isA<ReadCancelled>()));
    await Future<void>.delayed(Duration.zero);
    a.cancel();
    final second = pool.run('key', () => newGate.future);
    await checked;
    oldGate.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(pool.length, 1);
    var extraLoads = 0;
    final third = pool.run('key', () async {
      extraLoads++;
      return 9;
    });
    newGate.complete(2);
    expect(await Future.wait([second, third]), [2, 2]);
    expect(extraLoads, 0);
  });

  test('cancelled before dispatch never executes the loader', () async {
    final pool = SharedReadPool<String, int>();
    final request = ReadRequest();
    var loads = 0;
    final result = ReadRequest.run(
      request,
      () => pool.run('key', () async {
        loads++;
        return 1;
      }),
    );
    final checked = expectLater(result, throwsA(isA<ReadCancelled>()));
    request.cancel();
    await checked;
    await Future<void>.delayed(Duration.zero);
    expect(loads, 0);
  });

  test('synchronous loader errors release the key for retry', () async {
    final pool = SharedReadPool<String, int>();
    await expectLater(
      pool.run('key', () => throw StateError('bad')),
      throwsStateError,
    );
    expect(await pool.run('key', () async => 3), 3);
  });
}
