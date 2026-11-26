import 'dart:convert';
import 'dart:io';
import 'package:wild/services/epub/epub_parser.dart';

/// Read-only native-conversion probe. No novel text is included in the report.
void main(List<String> args) {
  final report = <Map<String, Object?>>[];
  for (final path in args) {
    final timer = Stopwatch()..start();
    try {
      final book = parseEpubBook(File(path).readAsBytesSync());
      final entry = <String, Object?>{
        'file': path.split(RegExp(r'[/\\]')).last,
        'sha256': book.digest,
        'chapterCount': book.chapters.length,
        'elapsedMs': timer.elapsedMilliseconds,
        'warnings': book.warnings,
        'scope':
            'Actual native parser only; no browser rendering or APK UI test',
        'chapters': [
          for (final chapter in book.chapters)
            {
              'href': chapter.href,
              'textCharacters': chapter.content.length,
              'nativeBlocks': chapter.document?.blocks.length ?? 0,
              'hasArtworkCandidate': chapter.artwork != null,
              'artworkHtmlBytes':
                  chapter.artwork == null
                      ? 0
                      : utf8.encode(chapter.artwork!.html).length,
            },
        ],
      };
      report.add(entry);
      stdout.writeln(
        jsonEncode({
          'file': entry['file'],
          'chapters': entry['chapterCount'],
          'elapsedMs': entry['elapsedMs'],
          'warnings': entry['warnings'],
          'artworkCandidates':
              book.chapters.where((chapter) => chapter.artwork != null).length,
        }),
      );
    } on Object catch (error) {
      final result = <String, Object?>{
        'file': path.split(RegExp(r'[/\\]')).last,
        'scope':
            'Actual native parser only; no browser rendering or APK UI test',
        'elapsedMs': timer.elapsedMilliseconds,
        'error': '$error',
      };
      report.add(result);
      stdout.writeln(jsonEncode(result));
    }
  }
  final output = File(
    'build/research/epub-css-engines-2026-10/native-parser-audit.json',
  );
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
}
