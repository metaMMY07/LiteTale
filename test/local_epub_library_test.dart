import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:wild/services/epub/apple_books_opener.dart';
import 'package:wild/models/reader_document.dart';
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

  LocalEpubLibrary library({
    Future<Uint8List> Function(File)? readFileBytes,
    EpubBookParser? parser,
    Future<void> Function(Directory from, String to)? renameDirectory,
    DateTime Function()? now,
  }) => LocalEpubLibrary(
    parser: parser ?? parse,
    useIsolates: false,
    readFileBytes: readFileBytes,
    renameDirectory: renameDirectory,
    now: now ?? () => DateTime.utc(2026, 10, 18),
  );

  XFile input([List<int> bytes = const [1, 2, 3], String name = '小说.epub']) =>
      XFile.fromData(Uint8List.fromList(bytes), path: name);

  File stored(LocalEpubBook book, String name) => File(
    '${root.path}${Platform.pathSeparator}local_epub'
    '${Platform.pathSeparator}${book.digest}${Platform.pathSeparator}$name',
  );

  Future<void> downgradeToLegacy(LocalEpubBook book) async {
    final file = stored(book, 'book.json');
    final manifest = jsonDecode(await file.readAsString()) as Map;
    manifest['schema'] = 1;
    final chapters = manifest['chapters'] as List;
    for (var i = 0; i < chapters.length; i++) {
      final entry = chapters[i] as Map;
      final jsonFile = stored(book, entry['file'] as String);
      final payload = jsonDecode(await jsonFile.readAsString()) as Map;
      final plain = Uint8List.fromList(
        utf8.encode(payload['content'] as String),
      );
      await stored(book, 'chapter_$i.txt').writeAsBytes(plain);
      entry['file'] = 'chapter_$i.txt';
      entry['length'] = plain.length;
      entry['sha256'] = sha256.convert(plain).toString();
      entry.remove('stableIndex');
      await jsonFile.delete();
    }
    await file.writeAsString(jsonEncode(manifest));
  }

  EpubChapterData styledChapter(String title, String href, String text) {
    final document = ReaderDocument([
      ReaderBlock(
        runs: [ReaderRun(text, style: const ReaderInlineStyle(bold: true))],
        style: const ReaderBlockStyle(align: 'center'),
      ),
    ]);
    return EpubChapterData(
      title: title,
      href: href,
      content: document.content,
      document: document,
    );
  }

  ParsedEpubBook withChapters(
    Uint8List bytes,
    List<EpubChapterData> chapters,
  ) => ParsedEpubBook(
    digest: sha256.convert(bytes).toString(),
    title: '结构化小说',
    author: '作者',
    description: '正文含段落样式',
    language: 'zh',
    subjects: const ['轻小说'],
    chapters: chapters,
    assets: const {},
  );

  Future<LocalEpubBook> legacyBook() async {
    final original = library();
    await original.initialize(root.path);
    final book = (await original.importFile(input())).book;
    await downgradeToLegacy(book);
    return book;
  }

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
    'Books handoff uses the exact original and cancellation preserves the library',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final lib = library();
      await lib.initialize(root.path);
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final imported = await lib.importFile(
        XFile.fromData(bytes, name: 'test.epub'),
      );
      const channel = MethodChannel('litetale/apple_books');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      String? path;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        path = (call.arguments as Map)['path'] as String;
        expect(call.method, 'open');
        expect(await File(path!).readAsBytes(), bytes);
        return {'completed': false, 'activity': ''};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final opener = AppleBooksOpener(channel: channel, isIOS: true);
      expect(await opener.open(lib, imported.book.id), isFalse);
      expect(lib.contains(imported.book.id), isTrue);
      expect(calls, 1);
      expect(
        await opener.open(lib, imported.book.id, isActive: () => false),
        isFalse,
      );
      expect(calls, 1);
      await File(path!).writeAsBytes([5, 4, 3, 2, 1]);
      await expectLater(
        opener.open(lib, imported.book.id),
        throwsA(isA<EpubImportException>()),
      );
      expect(calls, 1);
      lib.dispose();
    },
  );

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
          if (file.path.endsWith('chapter_0.json')) chapterReads++;
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
      await stored(book, 'chapter_1.json').writeAsString('坏');
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
        epubChapterId(book.digest, 2),
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
          if (file.path.endsWith('chapter_0.json') && delayFirst) {
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
    'structured chapter data and plain compatibility survive restart',
    () async {
      final store = library(
        parser:
            (bytes, {fallbackTitle = ''}) => withChapters(bytes, [
              styledChapter('居中标题', '正文/a.xhtml', '居中加粗正文'),
            ]),
      );
      await store.initialize(root.path);
      final imported = await store.importFile(input());
      final book = imported.book;
      expect(book.formatVersion, 3);
      expect(imported.upgraded, isFalse);
      final data = await store.chapterData(book.id, book.chapterId(0));
      expect(data.content, '居中加粗正文');
      expect(data.document!.blocks.single.style.align, 'center');
      expect(data.document!.blocks.single.runs.single.style.bold, isTrue);
      expect(await store.chapter(book.id, book.chapterId(0)), data.content);
      expect(
        identical(await store.chapterData(book.id, book.chapterId(0)), data),
        isTrue,
      );
      final restarted = library();
      await restarted.initialize(root.path);
      final restored = await restarted.chapterData(book.id, book.chapterId(0));
      expect(restored.document!.cacheIdentity, data.document!.cacheIdentity);
      expect(restored.content, data.content);
    },
  );

  test(
    'old rich style revision upgrades with the same book and chapter IDs',
    () async {
      final store = library();
      await store.initialize(root.path);
      final original = (await store.importFile(input())).book;
      final manifestFile = stored(original, 'book.json');
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
      manifest.remove(
        'styleRevision',
      ); // 1.0.0 rich schema2, before the new boxes.
      await manifestFile.writeAsString(jsonEncode(manifest));
      final reopened = library();
      await reopened.initialize(root.path);
      expect(reopened.books.single.formatVersion, 3);
      expect(reopened.books.single.needsStyleUpgrade, isTrue);
      final result = await reopened.importFile(input());
      expect(result.upgraded, isTrue);
      expect(result.book.id, original.id);
      expect(result.book.chapterId(0), original.chapterId(0));
      expect(result.book.importedAtMs, original.importedAtMs);
      expect(result.book.needsStyleUpgrade, isFalse);
      expect(result.book.styleRevision, currentEpubStyleRevision);
    },
  );

  test(
    'schema1 books remain readable without importing the original again',
    () async {
      final original = await legacyBook();
      final store = library();
      await store.initialize(root.path);
      final book = store.books.single;
      expect(book.id, original.id);
      expect(book.formatVersion, 1);
      final chapter = await store.chapterData(book.id, book.chapterId(0));
      expect(chapter.document, isNull);
      expect(chapter.content, '第一章\n中文与 Emoji 🌱');
      expect(chapter.title, '第一章');
    },
  );

  test(
    'legacy upgrade preserves IDs and date across reordered and added chapters',
    () async {
      final original = await legacyBook();
      var conversions = 0;
      final store = library(
        now: () => DateTime.utc(2026, 10, 21),
        parser: (bytes, {fallbackTitle = ''}) {
          conversions++;
          return withChapters(bytes, [
            styledChapter('新增序章', '正文/序章.xhtml', '新序章'),
            styledChapter('第二章', '正文/第二章.xhtml', '新版第二章'),
            styledChapter('第一章', '正文/第一章.xhtml', '新版第一章'),
          ]);
        },
      );
      await store.initialize(root.path);
      final previousRevision = store.revisionFor(original.id);
      final result = await store.importFile(input());
      final book = result.book;
      expect(result.upgraded, isTrue);
      expect(result.alreadyImported, isFalse);
      expect(book.id, original.id);
      expect(book.importedAtMs, original.importedAtMs);
      expect(book.formatVersion, 3);
      expect(book.chapterId(0), epubChapterId(book.digest, 2));
      expect(book.chapterId(1), epubChapterId(book.digest, 1));
      expect(book.chapterId(2), epubChapterId(book.digest, 0));
      expect(
        await store.chapter(book.id, epubChapterId(book.digest, 0)),
        '新版第一章',
      );
      expect(
        await store.chapter(book.id, epubChapterId(book.digest, 1)),
        '新版第二章',
      );
      expect(store.revisionFor(book.id), greaterThan(previousRevision));
      final base = Directory('${root.path}${Platform.pathSeparator}local_epub');
      final backup = base.listSync().whereType<Directory>().singleWhere(
        (directory) => directory.path.contains('.orphan_'),
      );
      expect(
        await File(
          '${backup.path}${Platform.pathSeparator}chapter_0.txt',
        ).readAsString(),
        '第一章\n中文与 Emoji 🌱',
      );
      final duplicate = await store.importFile(input());
      expect(duplicate.alreadyImported, isTrue);
      expect(duplicate.upgraded, isFalse);
      expect(conversions, 1);
      final restarted = library();
      await restarted.initialize(root.path);
      expect(
        restarted.books.single.chapterId(2),
        epubChapterId(book.digest, 0),
      );
      expect(
        (await restarted.chapterData(
          book.id,
          epubChapterId(book.digest, 0),
        )).document,
        isNotNull,
      );
    },
  );

  test(
    'missing legacy href cancels upgrade without replacing any old chapter',
    () async {
      final original = await legacyBook();
      final store = library(
        parser:
            (bytes, {fallbackTitle = ''}) => withChapters(bytes, [
              styledChapter('第一章', '正文/第一章.xhtml', '新正文'),
            ]),
      );
      await store.initialize(root.path);
      final revision = store.revisionFor(original.id);
      await expectLater(
        store.importFile(input()),
        throwsA(
          isA<EpubImportException>().having(
            (error) => error.message,
            'message',
            contains('原书'),
          ),
        ),
      );
      expect(store.book(original.id)!.formatVersion, 1);
      expect(store.revisionFor(original.id), revision);
      expect(
        await store.chapter(original.id, epubChapterId(original.digest, 1)),
        '第二章\n下一页',
      );
      final base = Directory('${root.path}${Platform.pathSeparator}local_epub');
      expect(base.listSync(), hasLength(1));
    },
  );

  test('ambiguous legacy href mapping refuses upgrade', () async {
    final original = await legacyBook();
    final store = library(
      parser:
          (bytes, {fallbackTitle = ''}) => withChapters(bytes, [
            styledChapter('重复第一章', '正文/第一章.xhtml', '新正文一'),
            styledChapter('重复第一章', '正文/第一章.xhtml', '新正文二'),
            styledChapter('第二章', '正文/第二章.xhtml', '新正文三'),
          ]),
    );
    await store.initialize(root.path);
    await expectLater(store.importFile(input()), isImportError);
    expect(store.book(original.id)!.formatVersion, 1);
    expect(
      await store.chapter(original.id, epubChapterId(original.digest, 0)),
      '第一章\n中文与 Emoji 🌱',
    );
  });

  test(
    'publication failure restores the exact old readable directory',
    () async {
      final original = await legacyBook();
      final store = library(
        renameDirectory: (from, to) async {
          if (from.path.contains('.import_')) {
            throw FileSystemException('simulated publish failure');
          }
          await from.rename(to);
        },
      );
      await store.initialize(root.path);
      final revision = store.revisionFor(original.id);
      await expectLater(
        store.importFile(input()),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.book(original.id)!.formatVersion, 1);
      expect(store.revisionFor(original.id), revision);
      expect(
        await store.chapter(original.id, epubChapterId(original.digest, 0)),
        '第一章\n中文与 Emoji 🌱',
      );
      expect(await stored(original, 'chapter_0.txt').exists(), isTrue);
      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books.single.formatVersion, 1);
      expect(restarted.loadWarnings, isEmpty);
    },
  );

  test(
    'interrupted rollback uses retained old copy and recovers at startup',
    () async {
      final original = await legacyBook();
      final store = library(
        renameDirectory: (from, to) async {
          if (from.path.contains('.import_') ||
              from.path.contains('.orphan_')) {
            throw FileSystemException(
              'simulated publication and restore failure',
            );
          }
          await from.rename(to);
        },
      );
      await store.initialize(root.path);
      await expectLater(
        store.importFile(input()),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await store.chapter(original.id, epubChapterId(original.digest, 1)),
        '第二章\n下一页',
      );
      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books.single.formatVersion, 1);
      expect(restarted.loadWarnings, isEmpty);
      expect(await stored(original, 'chapter_0.txt').exists(), isTrue);
      expect(
        await restarted.chapter(original.id, epubChapterId(original.digest, 0)),
        '第一章\n中文与 Emoji 🌱',
      );
    },
  );

  test(
    'old in-flight read cannot populate cache after a successful upgrade',
    () async {
      final original = await legacyBook();
      final pending = Completer<Uint8List>();
      final started = Completer<void>();
      final store = library(
        readFileBytes: (file) async {
          if (file.path.endsWith('chapter_0.txt')) {
            started.complete();
            return pending.future;
          }
          return file.readAsBytes();
        },
      );
      await store.initialize(root.path);
      final old = store.chapter(original.id, epubChapterId(original.digest, 0));
      final checkOld = expectLater(old, isImportError);
      await started.future;
      final result = await store.importFile(input());
      expect(result.upgraded, isTrue);
      pending.complete(Uint8List.fromList(utf8.encode('第一章\n中文与 Emoji 🌱')));
      await checkOld;
      final fresh = await store.chapterData(
        original.id,
        epubChapterId(original.digest, 0),
      );
      expect(fresh.content, '第一章\n中文与 Emoji 🌱');
      expect(result.book.formatVersion, 3);
    },
  );

  test(
    'invalid structured data cannot be read even with a matching file hash',
    () async {
      final store = library(
        parser:
            (bytes, {fallbackTitle = ''}) =>
                withChapters(bytes, [styledChapter('第一章', 'one.xhtml', '正文')]),
      );
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      final file = stored(book, 'chapter_0.json');
      final payload = jsonDecode(await file.readAsString()) as Map;
      payload['content'] = '与结构化文本不同';
      final badBytes = utf8.encode(jsonEncode(payload));
      await file.writeAsBytes(badBytes);
      final manifest =
          jsonDecode(await stored(book, 'book.json').readAsString()) as Map;
      manifest['chapters'][0]['length'] = badBytes.length;
      manifest['chapters'][0]['sha256'] = sha256.convert(badBytes).toString();
      await stored(book, 'book.json').writeAsString(jsonEncode(manifest));
      final restarted = library();
      await restarted.initialize(root.path);
      await expectLater(
        restarted.chapterData(book.id, book.chapterId(0)),
        isImportError,
      );
    },
  );

  test(
    'foreign structured image references cannot publish an imported book',
    () async {
      final document = ReaderDocument([
        ReaderBlock(imageUrl: 'epub-asset:${'f' * 64}/${'a' * 64}.png'),
      ]);
      final store = library(
        parser:
            (bytes, {fallbackTitle = ''}) => withChapters(bytes, [
              EpubChapterData(
                title: '插图',
                href: 'one.xhtml',
                content: document.content,
                document: document,
              ),
            ]),
      );
      await store.initialize(root.path);
      await expectLater(store.importFile(input()), isImportError);
      expect(store.books, isEmpty);
    },
  );

  test(
    'invalid structured style bounds are rejected despite valid file hash',
    () async {
      final store = library(
        parser:
            (bytes, {fallbackTitle = ''}) =>
                withChapters(bytes, [styledChapter('第一章', 'one.xhtml', '正文')]),
      );
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      final file = stored(book, 'chapter_0.json');
      final payload = jsonDecode(await file.readAsString()) as Map;
      payload['document']['blocks'][0]['runs'][0]['style']['scale'] = 100000;
      final badBytes = utf8.encode(jsonEncode(payload));
      await file.writeAsBytes(badBytes);
      final manifest =
          jsonDecode(await stored(book, 'book.json').readAsString()) as Map;
      manifest['chapters'][0]['length'] = badBytes.length;
      manifest['chapters'][0]['sha256'] = sha256.convert(badBytes).toString();
      await stored(book, 'book.json').writeAsString(jsonEncode(manifest));
      final restarted = library();
      await restarted.initialize(root.path);
      await expectLater(
        restarted.chapterData(book.id, book.chapterId(0)),
        isImportError,
      );
    },
  );

  test(
    'duplicated persisted stable IDs cannot redirect chapter history',
    () async {
      final store = library();
      await store.initialize(root.path);
      final book = (await store.importFile(input())).book;
      final file = stored(book, 'book.json');
      final metadata = jsonDecode(await file.readAsString()) as Map;
      metadata['chapters'][1]['stableIndex'] =
          metadata['chapters'][0]['stableIndex'];
      await file.writeAsString(jsonEncode(metadata));
      final restarted = library();
      await restarted.initialize(root.path);
      expect(restarted.books, isEmpty);
      expect(restarted.loadWarnings, isNotEmpty);
    },
  );

  test(
    'real isolate upgrade preserves original chapter IDs after restart',
    () async {
      final bytes = buildEpubFixture();
      final store = LocalEpubLibrary();
      await store.initialize(root.path);
      final original =
          (await store.importFile(XFile.fromData(bytes, path: '原书.epub'))).book;
      await downgradeToLegacy(original);
      await store.initialize(root.path);
      expect(store.books.single.formatVersion, 1);
      final upgraded = await store.importFile(
        XFile.fromData(bytes, path: '重新选原书.epub'),
      );
      expect(upgraded.upgraded, isTrue);
      expect(upgraded.book.importedAtMs, original.importedAtMs);
      expect(upgraded.book.chapterId(0), original.chapterId(0));
      final reopened = LocalEpubLibrary();
      await reopened.initialize(root.path);
      expect(reopened.books.single.formatVersion, 3);
      expect(
        await reopened.chapter(original.id, original.chapterId(0)),
        contains('这是自行编写的测试正文。'),
      );
    },
  );

  test(
    'styled documents cross background isolates during import and upgrade',
    () async {
      final store = LocalEpubLibrary(parser: _parseStyledIsolateFixture);
      await store.initialize(root.path);
      final original = (await store.importFile(input())).book;
      final first = await store.chapterData(original.id, original.chapterId(0));
      expect(first.document!.blocks.single.runs.single.style.italic, isTrue);
      await downgradeToLegacy(original);
      await store.initialize(root.path);
      final upgraded = await store.importFile(input());
      expect(upgraded.upgraded, isTrue);
      final restarted = LocalEpubLibrary(parser: _parseStyledIsolateFixture);
      await restarted.initialize(root.path);
      final chapter = await restarted.chapterData(
        original.id,
        original.chapterId(0),
      );
      expect(chapter.document!.blocks.single.style.align, 'right');
      expect(chapter.document!.blocks.single.runs.single.style.italic, isTrue);
      expect(
        await restarted.chapter(original.id, original.chapterId(0)),
        '后台结构化正文',
      );
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

ParsedEpubBook _parseStyledIsolateFixture(
  Uint8List bytes, {
  String fallbackTitle = '',
}) {
  final document = ReaderDocument([
    ReaderBlock(
      runs: const [
        ReaderRun('后台结构化正文', style: ReaderInlineStyle(italic: true)),
      ],
      style: const ReaderBlockStyle(align: 'right'),
    ),
  ]);
  return ParsedEpubBook(
    digest: sha256.convert(bytes).toString(),
    title: '后台测试',
    author: '测试作者',
    description: '',
    language: 'zh',
    subjects: const [],
    chapters: [
      EpubChapterData(
        title: '测试章',
        href: 'one.xhtml',
        content: document.content,
        document: document,
      ),
    ],
    assets: const {},
  );
}

class _DeferredXFile extends XFile {
  _DeferredXFile(this.bytes) : super.fromData(Uint8List(3), path: '稍后导入.epub');
  final Future<Uint8List> bytes;
  @override
  Future<Uint8List> readAsBytes() => bytes;
}
