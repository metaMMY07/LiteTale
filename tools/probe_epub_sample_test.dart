// Optional public/local sample probe; never bundled into the application.
// flutter test tools/probe_epub_sample_test.dart --dart-define=EPUB_SAMPLE_PATH=...
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/sources/local_epub_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sample = String.fromEnvironment('EPUB_SAMPLE_PATH');
  test(
    'real EPUB converts and reopens through the private native adapter',
    () async {
      expect(sample, isNotEmpty);
      final input = File(sample);
      final root = await Directory.systemTemp.createTemp('litetale_real_epub_');
      final library = LocalEpubLibrary();
      final restarted = LocalEpubLibrary();
      try {
        final timer = Stopwatch()..start();
        await library.initialize(root.path);
        final result = await library.importFile(XFile(input.path));
        final importedMs = timer.elapsedMilliseconds;
        timer.reset();
        var textCharacters = 0;
        for (var i = 0; i < result.book.chapters.length; i++) {
          final text = await library.chapter(
            result.book.id,
            result.book.chapterId(i),
          );
          expect(text.trim(), isNotEmpty);
          textCharacters += text.length;
        }
        for (final image in result.book.assetNames) {
          expect(
            await library.readAsset('epub-asset:${result.book.digest}/$image'),
            isNotEmpty,
          );
        }
        await restarted.initialize(root.path);
        final detail = await LocalEpubSource(
          library: restarted,
        ).detail(result.book.id);
        expect(
          detail.volumes.single.chapters.length,
          result.book.chapters.length,
        );
        expect(
          (await LocalEpubSource(
            library: restarted,
          ).chapter(result.book.id, result.book.chapterId(0))).content,
          isNotEmpty,
        );
        print(
          jsonEncode({
            'sample': input.uri.pathSegments.last,
            'sha256': sha256.convert(await input.readAsBytes()).toString(),
            'inputBytes': await input.length(),
            'chapters': result.book.chapters.length,
            'images': result.book.assetNames.length,
            'characters': textCharacters,
            'importMs': importedMs,
            'readAllAndRestartMs': timer.elapsedMilliseconds,
            'warnings': result.book.warnings,
          }),
        );
        await restarted.remove(result.book.id);
      } finally {
        library.dispose();
        restarted.dispose();
        final entries =
            await root.list(recursive: true, followLinks: false).toList();
        for (final file in entries.whereType<File>()) {
          await file.delete();
        }
        for (final directory
            in entries.whereType<Directory>().toList()
              ..sort((a, b) => b.path.length.compareTo(a.path.length))) {
          await directory.delete();
        }
        await root.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
