import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (
      String name,
      List<int> image, [
      Map<String, Object?>? args,
    ]) async {
      final file = File(
        '${Platform.environment['NOVELS_TEST_SCREENSHOTS'] ?? 'build/integration-screens'}/$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(image);
      return true;
    },
  );
}
