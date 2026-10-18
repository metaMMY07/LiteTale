import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';

import 'support/epub_fixture.dart';

void main() {
  late Directory root;
  final image = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  final imageName = '${sha256.convert(image)}.png';
  var parses = 0;

  ParsedEpubBook parse(Uint8List bytes, {String fallbackTitle = ''}) {
    parses++;
    if (bytes.first == 0) throw const EpubImportException('bad epub');
    return ParsedEpubBook(
      digest: sha256.convert(bytes).toString(),
      title: '一册本地轻小说',
      author: '作者',
      description: '内容简介',
      language: 'zh',
      subjects: const ['轻小说'],
      chapters: [
        const EpubChapterData(
          title: '第一章',
          href: '正文/第一章.xhtml',
          content: '第一章\n中文与 Emoji 🌱',
        ),
        const EpubChapterData(
          title: '第二章',
          href: '正文/第二章.xhtml',
          content: '第二章\n下一页',
        ),
      ],
      assets: {imageName: image},
      coverAssetName: imageName,
      warnings: const ['测试提示'],
    );
  }

  LocalEpubLibrary library({Future<Uint8List> Function(File)? readFileBytes}) =>
      LocalEpubLibrary(
        parser: parse,
        useIsolates: false,
        readFileBytes: readFileBytes,
        now: () => DateTime.utc(2026, 10, 18),
      );

  XFile input([List<int> bytes = const [1, 2, 3], String name = '小说.epub']) =>
      XFile.fromData(Uint8List.fromList(bytes), path: name);

  File stored(LocalEpubBook book, String name) => File(
    '${root.path}${Platform.pathSeparator}local_epub'
    '${Platform.pathSeparator}${book.digest}${Platform.pathSeparator}$name',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('litetale_epub_store_');
    parses = 0;
  });

  tearDown(() async {
    // These test-owned files are enumerated and deleted individually. Never
    // invoke recursive deletion against an interpolated directory.
    final entries =
        await root.list(recursive: true, followLinks: false).toList();
    for (final file in entries.whereType<File>()) {
      await file.delete();
    }
    for (final link in entries.whereType<Link>()) {
      await link.delete();
    }
    final directories =
        entries.whereType<Directory>().toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      await directory.delete();
    }
    await root.delete();
  });

  test(
    'real parser and default background isolates import and reopen EPUB',
    () async {
      final bytes = buildEpubFixture(
        title: '后台导入测试',
        resources: {'Images/cover.png': epubFixturePng()},
        coverPath: 'Images/cover.png',
      );
      final store = LocalEpubLibrary();
      await store.initialize(root.path);
      final result = await store.importFile(
        XFile.fromData(bytes, path: '中文文件名.epub'),
      );
      expect(result.book.title, '后台导入测试');
      expect(
        await store.chapter(result.book.id, result.book.chapterId(0)),
        contains('这是自行编写的测试正文。'),
      );
      expect(await store.readAsset(result.book.coverUrl), epubFixturePng());
      final restarted = LocalEpubLibrary();
      await restarted.initialize(root.path);
      expect(restarted.books.single.id, result.book.id);
      expect(
        await restarted.chapter(result.book.id, result.book.chapterId(0)),
        contains('这是自行编写的测试正文。'),
      );
      await restarted.remove(result.book.id);
      expect(restarted.books, isEmpty);
    },
  );

  test('import survives original file removal and process restart', () async {
    final original = File('${root.path}${Platform.pathSeparator}原书.epub');
    await original.writeAsBytes([1, 2, 3]);
    final first = library();
    await first.initialize(root.path);
    final result = await first.importFile(XFile(original.path));
    expect(result.alreadyImported, isFalse);
    expect(result.book.fileName, '原书.epub');
    expect(first.books.single.title, '一册本地轻小说');
    expect(
      await first.chapter(result.book.id, result.book.chapterId(0)),
      '第一章\n中文与 Emoji 🌱',
    );
    await original.delete();

    final restarted = library();
    await restarted.initialize(root.path);
    final book = restarted.books.single;
    expect(
      parses,
      1,
      reason: 'startup must not parse/decompress the EPUB again',
    );
    expect(book.id, result.book.id);
    expect(book.chapters[1].title, '第二章');
    expect(await restarted.chapter(book.id, book.chapterId(1)), '第二章\n下一页');
    expect(await restarted.readAsset(book.coverUrl), image);
    expect(restarted.initializationError, isNull);
  });

  test(
    'identical bytes renamed or imported concurrently are not reparsed',
    () async {
      final store = library();
      await store.initialize(root.path);
      final results = await Future.wait([
        store.importFile(input()),
        store.importFile(input(const [1, 2, 3], '另一个名字.epub')),
      ]);
      expect(results.first.alreadyImported, isFalse);
      expect(results.last.alreadyImported, isTrue);
      expect(results.first.book.id, results.last.book.id);
      expect(parses, 1);
      expect(store.books.length, 1);
    },
  );

  test(
    'failed import publishes no book and does not poison later imports',
    () async {
      final store = library();
      await store.initialize(root.path);
      await expectLater(store.importFile(input(const [0])), isImportError);
      expect(store.books, isEmpty);
      expect(
        Directory('${root.path}${Platform.pathSeparator}local_epub').listSync(),
        isEmpty,
      );
      await store.importFile(input());
      expect(store.books, hasLength(1));
    },
  );

  test('empty and oversized inputs fail before parsing', () async {
    final store = library();
    await store.initialize(root.path);
    await expectLater(store.importFile(input(const [])), isImportError);
    final tooLarge = XFile.fromData(
      Uint8List.fromList([1]),
      length: maxEpubInputBytes + 1,
    );
    await expectLater(store.importFile(tooLarge), isImportError);
    expect(parses, 0);
  });

  test(
    'one corrupt manifest and abandoned staging do not hide valid books',
    () async {
      final store = library();
      await store.initialize(root.path);
      final valid = (await store.importFile(input())).book;
      final corrupt = (await store.importFile(input(const [4, 5]))).book;
      await stored(corrupt, 'book.json').writeAsString('{invalid');
      final staging = Directory(
        '${root.path}${Platform.pathSeparator}local_epub'
        '${Platform.pathSeparator}.import_crashed',
      );
      await staging.create();
      await File(
        '${staging.path}${Platform.pathSeparator}book.json',
      ).writeAsString('{}');

      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books.map((book) => book.id), [valid.id]);
      expect(restarted.loadWarnings, hasLength(1));
      expect(restarted.initializationError, isNull);
      final restored = await restarted.importFile(input(const [4, 5]));
      expect(restored.alreadyImported, isFalse);
      expect(restarted.books, hasLength(2));
    },
  );

  test('manifest filenames and digests are validated before use', () async {
    final store = library();
    await store.initialize(root.path);
    final book = (await store.importFile(input())).book;
    final manifestFile = stored(book, 'book.json');
    final metadata = jsonDecode(await manifestFile.readAsString()) as Map;
    metadata['chapters'][0]['file'] = '../outside.txt';
    await manifestFile.writeAsString(jsonEncode(metadata));
    final restarted = library();
    await restarted.initialize(root.path);
    expect(restarted.books, isEmpty);
    expect(restarted.loadWarnings, isNotEmpty);
  });

  test(
    'chapter reads deduplicate in flight and retain only validated text',
    () async {
      var chapterReads = 0;
      final store = library(
        readFileBytes: (file) async {
          if (file.path.endsWith('chapter_0.txt')) chapterReads++;
          return file.readAsBytes();
        },
      );
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      final read = await Future.wait([
        store.chapter(book.id, book.chapterId(0)),
        store.chapter(book.id, book.chapterId(0)),
      ]);
      expect(read.first, read.last);
      expect(chapterReads, 1);
      await store.chapter(book.id, book.chapterId(0));
      expect(chapterReads, 1);
      await stored(book, 'chapter_1.txt').writeAsString('坏');
      await expectLater(
        store.chapter(book.id, book.chapterId(1)),
        isImportError,
      );
    },
  );

  test(
    'an import awaiting file bytes does not block existing chapter reads',
    () async {
      final store = library();
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      final pending = Completer<Uint8List>();
      final import = store.importFile(_DeferredXFile(pending.future));
      await Future<void>.delayed(Duration.zero);
      expect(
        await store
            .chapter(book.id, book.chapterId(0))
            .timeout(const Duration(seconds: 1)),
        contains('中文与 Emoji'),
      );
      pending.complete(Uint8List.fromList([5, 6, 7]));
      await import;
      expect(store.books, hasLength(2));
    },
  );

  test(
    'reject invalid chapter IDs and nondeclared/arbitrary asset URIs',
    () async {
      final store = library();
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      for (final chapter in [
        'file:///private/chapter.txt',
        'epub:${book.digest}:c-1',
        'epub:${book.digest}:c01',
        book.chapterId(2),
        'epub:${'f' * 64}:c0',
      ]) {
        await expectLater(store.chapter(book.id, chapter), isImportError);
      }
      for (final asset in [
        'file:///private/image.png',
        'https://example.com/image.png',
        'epub-asset:${book.digest}/../book.json',
        'epub-asset:${book.digest}/%2e%2e/book.json',
        'epub-asset:${book.digest}/${'f' * 64}.png',
        '${book.coverUrl}?outside=true',
      ]) {
        await expectLater(store.readAsset(asset), isImportError);
      }
    },
  );

  test(
    'missing or same-length tampered images return recoverable errors',
    () async {
      final store = library();
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      await stored(book, imageName).writeAsBytes(List.filled(image.length, 1));
      await expectLater(store.readAsset(book.coverUrl), isImportError);
      await stored(book, imageName).delete();
      await expectLater(store.readAsset(book.coverUrl), isImportError);
    },
  );

  test(
    'removal invalidates pending reads before identical content reimport',
    () async {
      final pending = Completer<Uint8List>();
      final started = Completer<void>();
      var delayFirst = true;
      final store = library(
        readFileBytes: (file) async {
          if (file.path.endsWith('chapter_0.txt') && delayFirst) {
            delayFirst = false;
            started.complete();
            return pending.future;
          }
          return file.readAsBytes();
        },
      );
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      final firstRevision = store.revisionFor(book.id);
      final oldRead = store.chapter(book.id, book.chapterId(0));
      final oldReadCheck = expectLater(oldRead, isImportError);
      await started.future;
      await store.remove(book.id);
      expect(store.contains(book.id), isFalse);
      expect(store.revisionFor(book.id), greaterThan(firstRevision));
      final reimported = (await store.importFile(input())).book;
      pending.complete(Uint8List.fromList(utf8.encode('第一章\n中文与 Emoji 🌱')));
      await oldReadCheck;
      expect(
        await store.chapter(reimported.id, reimported.chapterId(0)),
        '第一章\n中文与 Emoji 🌱',
      );
      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books, hasLength(1));
    },
  );

  test(
    'removal retains unknown files and cannot resurrect on restart',
    () async {
      final store = library();
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      await stored(book, 'unexpected.txt').writeAsString('do not delete');
      await store.remove(book.id);
      final base = Directory('${root.path}${Platform.pathSeparator}local_epub');
      final remaining = await base.list().toList();
      expect(remaining, hasLength(1));
      final retained = remaining.single as Directory;
      expect(
        await File(
          '${retained.path}${Platform.pathSeparator}unexpected.txt',
        ).readAsString(),
        'do not delete',
      );
      expect(
        await File('${retained.path}${Platform.pathSeparator}removed').exists(),
        isTrue,
      );
      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books, isEmpty);
      await restarted.importFile(input());
      expect(restarted.books, hasLength(1));
    },
  );

  test(
    'existing tombstone is ignored and reimport quarantines it safely',
    () async {
      final store = library();
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      await stored(book, 'removed').writeAsString('removed');
      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books, isEmpty);
      await restarted.importFile(input());
      expect(restarted.books, hasLength(1));
    },
  );

  test(
    'initialization error is exposed and a later retry can recover',
    () async {
      final collision = File('${root.path}${Platform.pathSeparator}local_epub');
      await collision.writeAsString('not a directory');
      final store = library();
      await expectLater(store.initialize(root.path), isImportError);
      expect(store.initializationError, isNotNull);
      await collision.delete();
      await store.retryInitialization();
      expect(store.initializationError, isNull);
      await store.importFile(input());
      expect(store.books, hasLength(1));
    },
  );
}

final isImportError = throwsA(isA<EpubImportException>());

class _DeferredXFile extends XFile {
  _DeferredXFile(this.bytes) : super.fromData(Uint8List(3), path: '稍后导入.epub');
  final Future<Uint8List> bytes;
  @override
  Future<Uint8List> readAsBytes() => bytes;
}
