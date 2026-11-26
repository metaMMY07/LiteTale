import 'dart:convert';
import 'dart:io';
import 'package:wild/services/epub/epub_parser.dart';

/// Private local QA data only. Never upload these resources or chapter text.
void main(List<String> args) {
  final output = Directory('build/research/epub-css-engine-runtime')
    ..createSync(recursive: true);
  final report = [];
  for (var bookIndex = 0; bookIndex < args.length; bookIndex++) {
    final input = File(args[bookIndex]).readAsBytesSync();
    final book = parseEpubBook(input);
    final entries = [];
    for (var i = 0; i < book.chapters.length; i++) {
      final chapter = book.chapters[i];
      final doc = readEpubPublication(
        input,
        chapter.href,
        fixedLayout: chapter.fixedLayout,
        endHref: i + 1 < book.chapters.length ? book.chapters[i + 1].href : '',
      );
      final root = Directory('${output.path}/$bookIndex/$i')
        ..createSync(recursive: true);
      File('${root.path}/chapter.html').writeAsStringSync(doc.html);
      for (final asset in doc.resources.entries) {
        File('${root.path}/${asset.key}').writeAsBytesSync(asset.value);
      }
      entries.add({
        'index': i,
        'path': root.absolute.path,
        'fixed': doc.fixedLayout,
        'href': chapter.href,
        'characters': chapter.content.length,
        'resources': doc.resources.length,
      });
    }
    report.add({'digest': book.digest, 'chapters': entries});
    stdout.writeln(
      jsonEncode({
        'book': bookIndex,
        'chapters': entries.length,
        'fixed': entries.where((c) => c['fixed'] == true).length,
      }),
    );
  }
  File('${output.path}/index.json').writeAsStringSync(jsonEncode(report));
}
