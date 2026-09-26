import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/sources/book_source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'public Wenku8 covers download, cache, decode and render',
    (tester) async {
      await app.main();
      // RustLib.init only loads the bridge; /init initializes the database and
      // cache directories asynchronously before showing the home navigation.
      final startup = Stopwatch()..start();
      while (find.byType(NavigationBar).evaluate().isEmpty &&
          startup.elapsed.inSeconds < 35) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(NavigationBar), findsOneWidget);
      // Use an isolated loopback URL: never damage a user's saved cover file.
      final sample = await rootBundle.load('lib/assets/startup.png');
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(sample.buffer.asUint8List());
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final fixtureUrl = 'http://127.0.0.1:${server.port}/cache-recovery.png';
      final fixturePath = await api.downloadImage(url: fixtureUrl);
      final original = await File(fixturePath).readAsBytes();
      // An interrupted cache write must trigger a fresh request, not permanent
      // decode errors. Restore only this fixture if an assertion fails.
      try {
        await File(fixturePath).writeAsBytes([0, 1, 2]);
        final recoveredPath = await api.downloadImage(url: fixtureUrl);
        expect(await File(recoveredPath).readAsBytes(), original);
        expect(requests, 2);
        final moved = await File(
          fixturePath,
        ).rename('$fixturePath.test-backup');
        try {
          final restoredPath = await api.downloadImage(url: fixtureUrl);
          expect(await File(restoredPath).readAsBytes(), original);
          expect(requests, 3);
        } finally {
          // Keep the single backup file for diagnostics; no bulk cache cleanup.
          if (!await File(fixturePath).exists()) await moved.copy(fixturePath);
        }
        debugPrint('WENKU_CACHE_RECOVERY_OK corrupt and missing files');
      } finally {
        await File(fixturePath).writeAsBytes(original);
      }
      final failures = <String>[];
      for (final url in [
        'http://img.wenku8.com/image/3/3492/3492s.jpg',
        'http://img.wenku8.com/image/3/3744/3744s.jpg',
        'https://img.wenku8.com/image/3/3425/3425s.jpg',
      ]) {
        try {
          final path = await api
              .downloadImage(url: url)
              .timeout(const Duration(seconds: 35));
          final bytes = await File(path).readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, greaterThan(0));
          frame.image.dispose();
          codec.dispose();
          expect(await api.downloadImage(url: url), path);
          debugPrint('WENKU_IMAGE_OK $url ${bytes.length} bytes');
        } catch (error) {
          failures.add('$url: $error');
          debugPrint('WENKU_IMAGE_FAILURE $url: $error');
        }
      }
      expect(failures, isEmpty);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 180,
              child: CachedImage(
                source: SourceId.wenku8,
                url: 'http://img.wenku8.com/image/3/3492/3492s.jpg',
              ),
            ),
          ),
        ),
      );
      final watch = Stopwatch()..start();
      while (watch.elapsed.inSeconds < 20 &&
          !tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue,
      );
      expect(find.byIcon(Icons.broken_image), findsNothing);
      // Cover reveal timing is covered separately; this verifies image recovery.
      debugPrint('WENKU_VICTORIA_RENDER_OK book 3492 CachedImage');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
