// Local data only. Uses the production reader, pagination, and Android curl.
// Build with --target tools/tablet_reader_demo.dart for live gesture QA.
import 'package:flutter/material.dart';
import '../integration_test/fixtures/tablet_reader_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await createTabletReaderFixture());
}
