import 'dart:convert';
import 'dart:io';
import 'package:wild/services/epub/epub_parser.dart';

/// Local-only probe; user books are never embedded in source or fixtures.
void main(List<String> args) {
  final out = Directory('build/epub-artwork-probe')
    ..createSync(recursive: true);
  for (var index = 0; index < args.length; index++) {
    final timer = Stopwatch()..start();
    final book = parseEpubBook(File(args[index]).readAsBytesSync());
    final art = <String>[];
    for (var i = 0; i < book.chapters.length; i++) {
      final chapter = book.chapters[i];
      if (chapter.artwork != null) {
        File(
          '${out.path}/book-$index-page-$i.html',
        ).writeAsStringSync(chapter.artwork!.html);
        art.add(chapter.href);
      }
    }
    stdout.writeln(
      jsonEncode({
        'input': index,
        'chapters': book.chapters.length,
        'artwork': art,
        'elapsedMs': timer.elapsedMilliseconds,
        'warnings': book.warnings,
      }),
    );
  }
}
