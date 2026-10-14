import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/shelf_api_error.dart';
import 'package:wild/services/shelf_device_id.dart';

const knownId = '01234567-89ab-4cde-8fab-0123456789ab';
final uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  test(
    'concurrent first use waits for one saved ID, reused after restart',
    () async {
      String? saved;
      var reads = 0, writes = 0, returned = 0;
      final saving = Completer<void>();
      Future<String?> read() async {
        reads++;
        return saved;
      }

      Future<void> write(String id) async {
        writes++;
        await saving.future;
        saved = id;
      }

      final identity = ShelfDeviceId(readValue: read, writeValue: write);
      final requests = List.generate(
        20,
        (_) => identity.value().then((id) {
          returned++;
          return id;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, 1);
      expect(writes, 1);
      expect(returned, 0);
      saving.complete();
      final ids = await Future.wait(requests);
      expect(ids.toSet(), {saved});
      expect(uuid.hasMatch(saved!), isTrue);
      expect(await identity.value(), saved);
      final restarted = ShelfDeviceId(readValue: read, writeValue: write);
      expect(await restarted.value(), saved);
      expect(reads, 2);
      expect(writes, 1);
    },
  );

  test('independent installations generate independent random IDs', () async {
    Future<String> fresh() =>
        ShelfDeviceId(
          readValue: () async => null,
          writeValue: (_) async {},
        ).value();
    final first = await fresh(), second = await fresh();
    expect(uuid.hasMatch(first), isTrue);
    expect(uuid.hasMatch(second), isTrue);
    expect(first, isNot(second));
  });

  test('an existing ID is returned unchanged without a write', () async {
    var writes = 0;
    final identity = ShelfDeviceId(
      readValue: () async => knownId,
      writeValue: (_) async {
        writes++;
      },
    );
    expect(await identity.value(), knownId);
    expect(await identity.value(), knownId);
    expect(writes, 0);
  });

  test('read failure preserves storage and a later read can recover', () async {
    var reads = 0, writes = 0;
    final identity = ShelfDeviceId(
      readValue: () async {
        if (++reads == 1) throw StateError('private platform details');
        return knownId;
      },
      writeValue: (_) async {
        writes++;
      },
    );
    await expectLater(
      identity.value(),
      throwsA(
        isA<ShelfApiException>().having(
          (e) => e.toString(),
          'safe error',
          isNot(contains('private platform details')),
        ),
      ),
    );
    expect(await identity.value(), knownId);
    expect(writes, 0);
  });

  test('failed persistence does not return an unsaved identifier', () async {
    var writes = 0;
    String? saved;
    final identity = ShelfDeviceId(
      readValue: () async => saved,
      writeValue: (id) async {
        if (++writes == 1) throw StateError('unavailable');
        saved = id;
      },
    );
    await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
    expect(saved, isNull);
    expect(await identity.value(), saved);
    expect(writes, 2);
  });

  test(
    'ambiguous write failure rereads the ID already saved by the platform',
    () async {
      String? saved;
      var writes = 0;
      final identity = ShelfDeviceId(
        readValue: () async => saved,
        writeValue: (id) async {
          saved = id;
          writes++;
          throw StateError('completion failed after commit');
        },
      );
      await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
      expect(saved, isNotNull);
      expect(await identity.value(), saved);
      expect(writes, 1);
    },
  );

  test(
    'invalid stored IDs fail safely without replacing the existing value',
    () async {
      for (final stored in [
        'invalid',
        '$knownId\n',
        '$knownId\r\nx-test: injected',
      ]) {
        var writes = 0;
        final identity = ShelfDeviceId(
          readValue: () async => stored,
          writeValue: (_) async {
            writes++;
          },
        );
        await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
        expect(writes, 0);
      }
    },
  );

  test(
    'a timed-out read is shared until the actual platform call finishes',
    () async {
      final reading = Completer<String?>();
      var reads = 0, writes = 0;
      final identity = ShelfDeviceId(
        readValue: () {
          reads++;
          return reading.future;
        },
        writeValue: (_) async {
          writes++;
        },
        storageTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
      await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
      expect(reads, 1);
      expect(writes, 0);
      reading.complete(knownId);
      expect(await identity.value(), knownId);
    },
  );

  test(
    'a late write cannot race a second generated ID after timeout',
    () async {
      final saving = Completer<void>();
      var reads = 0, writes = 0;
      String? candidate, saved;
      final identity = ShelfDeviceId(
        readValue: () async {
          reads++;
          return saved;
        },
        writeValue: (id) async {
          candidate = id;
          writes++;
          await saving.future;
          saved = id;
        },
        storageTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
      await expectLater(identity.value(), throwsA(isA<ShelfApiException>()));
      expect(reads, 1);
      expect(writes, 1);
      saving.complete();
      expect(await identity.value(), candidate);
      expect(saved, candidate);
    },
  );
}
