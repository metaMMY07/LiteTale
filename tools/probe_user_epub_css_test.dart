// Read-only inspection of the user-supplied CSS test EPUB. No file is bundled.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/epub_parser.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/services/reader_paginator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('supplied CSS sample retains accents, boxes, columns and dark palette', () async {
    const path = String.fromEnvironment('EPUB_SAMPLE_PATH');
    final book = parseEpubBook(await File(path).readAsBytes());
    expect(book.chapters.length, 4);
    final chapter = book.chapters[1].document!;
    final heading = chapter.blocks.first;
    expect(heading.runs.first.style.color, 0xff245385);
    expect(heading.runs.first.style.darkColor, 0xff98c9ff);
    final note = chapter.blocks.firstWhere((b) => b.text.contains('提示卡片'));
    expect(note.style.box.background, 0xfffff3d8);
    expect(note.style.box.radius.em, greaterThan(0));
    expect(note.style.box.paddingLeft.em, greaterThan(0));
    expect(note.style.box.left.color, 0xffd1b16d);
    final quote = chapter.blocks.firstWhere((b) => b.text.contains('这是引用块'));
    expect(quote.style.marginLeft.fraction, closeTo(.13, .0001));
    expect(quote.style.box.background, 0xfff0f4fa);
    expect(quote.style.box.left.color, 0xff5a83a5);
    expect(chapter.blocks.expand((b) => b.runs).any((r) => r.style.background == 0xfffff0a8), isTrue);
    final initial = chapter.blocks.firstWhere((b) => b.text.startsWith('春天')).runs.first;
    expect(initial.text, '春');
    expect(initial.style.scale, 2);
    final lists = book.chapters[2].document!;
    expect(lists.blocks.any((b) => b.text.startsWith('1. ')), isTrue);
    expect(lists.blocks.any((b) => b.text.startsWith('3. ')), isTrue);
    final rows = lists.blocks.where((b) => b.cells.isNotEmpty).toList();
    expect(rows.length, 5);
    expect(rows.every((b) => b.cells.length == 2), isTrue);
    expect(rows.first.cells.first.runs.first.style.bold, isTrue);
    expect(rows[2].style.box.background, 0xfff1f6fa);
    for (final document in book.chapters.map((c) => c.document!)) {
      expect(ReaderDocument.fromJson(document.toJson()).content, document.content);
      for (final (width, height) in [(300.0, 450.0), (450.0, 650.0)]) {
        final pages = paginateReaderContent(content: document.content, document: document,
          canvasWidth: width, canvasHeight: height, fontSize: 18, lineHeight: 1.3, paragraphSpacing: 24);
        expect(pages.expand((p) => p.fragments!).map((f) => f.text).join(), document.blocks.map((b) => b.text).join());
      }
    }
    final out = Directory('build/epub-css-fix')..createSync(recursive: true);
    File('${out.path}/user-document.json').writeAsStringSync(jsonEncode({
      'title':book.title, 'warnings':book.warnings,
      'chapters':[for (final c in book.chapters) {'title':c.title,'document':c.document!.toJson()}],
    }));
    print(jsonEncode({'chapters':book.chapters.length, 'rows':rows.length, 'warnings':book.warnings}));
  });
}
