import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/services/wenku8_host.dart';

void main() {
  test('mirror normalization keeps the shared Wenku8 login domain', () {
    expect(normalizeWenku8Host('  '), '');
    expect(
      normalizeWenku8Host(' https://WWW.WENKU8.NET:443/ '),
      defaultWenku8Host,
    );
    expect(normalizeWenku8Host('https://wenku8.net'), 'https://wenku8.net');
    expect(
      normalizeWenku8Host('https://mirror.wenku8.net/'),
      'https://mirror.wenku8.net',
    );
  });

  test('independent, lookalike and non-root mirror addresses are rejected', () {
    for (final value in [
      'http://www.wenku8.net',
      'https://wenku8.net.attacker.test',
      'https://fakewenku8.net',
      'https://wenku8.cc',
      'https://example.test',
      'https://u:p@www.wenku8.net',
      'https://www.wenku8.net:8443',
      'https://www.wenku8.net/book/1.htm',
      'https://www.wenku8.net/?x=1',
      'https://www.wenku8.net/#x',
      'https://-bad.wenku8.net',
    ]) {
      expect(
        () => normalizeWenku8Host(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test(
    'pending load cannot overwrite a saved host, and reset persists empty',
    () async {
      final load = Completer<String>();
      final written = <String>[];
      final cubit = ApiHostCubit(
        read: () => load.future,
        write: (value) async => written.add(value),
      );
      addTearDown(cubit.close);
      final saving = cubit.updateApiHost('https://mirror.wenku8.net/');
      expect(written, isEmpty);
      load.complete(defaultWenku8Host);
      await saving;
      expect(cubit.state, 'https://mirror.wenku8.net');
      expect(written, ['https://mirror.wenku8.net']);
      await cubit.resetToDefault();
      expect(cubit.state, defaultWenku8Host);
      expect(written.last, '');
    },
  );

  test(
    'invalid save and failed persistence leave the previous host intact',
    () async {
      var writes = 0;
      final cubit = ApiHostCubit(
        read: () async => defaultWenku8Host,
        write: (_) async {
          writes++;
          throw StateError('fixture write failed');
        },
      );
      addTearDown(cubit.close);
      await cubit.initialized;
      await expectLater(
        cubit.updateApiHost('https://example.test'),
        throwsFormatException,
      );
      expect(writes, 0);
      await expectLater(
        cubit.updateApiHost('https://mirror.wenku8.net'),
        throwsStateError,
      );
      expect(writes, 1);
      expect(cubit.state, defaultWenku8Host);
    },
  );
}
