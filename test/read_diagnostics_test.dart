import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/read_diagnostics.dart';
import 'package:wild/services/read_request.dart';

void main() {
  setUp(() {
    ReadDiagnostics.clear();
    ReadDiagnostics.enabled = true;
  });
  tearDown(() {
    ReadDiagnostics.clear();
    ReadDiagnostics.enabled = false;
  });
  test(
    'records bounded phase durations and all outcomes without payloads',
    () async {
      await ReadDiagnostics.measure('bili', 'queue', () async => 1);
      await expectLater(
        ReadDiagnostics.measure<int>(
          'bili',
          'cancel',
          () async => throw const ReadCancelled(),
        ),
        throwsA(isA<ReadCancelled>()),
      );
      expect(ReadDiagnostics.events.last.outcome, 'cancelled');
      expect(
        () => ReadDiagnostics.measureSync<int>(
          'fixture',
          'parse_failure',
          () => throw const FormatException('bad response'),
        ),
        throwsFormatException,
      );
      expect(ReadDiagnostics.events.last.outcome, 'failed');
      expect(
        ReadDiagnostics.events.first.microseconds,
        greaterThanOrEqualTo(0),
      );
      for (var i = 0; i < 300; i++) {
        ReadDiagnostics.measureSync('fixture', 'parse', () => 1);
      }
      expect(ReadDiagnostics.events.length, 256);
      ReadDiagnostics.enabled = false;
      await ReadDiagnostics.measure('bili', 'disabled', () async => 1);
      expect(ReadDiagnostics.events.last.phase, 'parse');
    },
  );
}
