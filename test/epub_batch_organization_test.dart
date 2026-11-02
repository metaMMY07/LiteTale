import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/epub_import_queue.dart';
import 'package:wild/services/epub/epub_library_query.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/services/epub/local_epub_organization.dart';

import 'support/epub_fixture.dart';

String bookId(int n) => 'epub:${n.toRadixString(16).padLeft(64, '0')}';
LocalEpubBook fakeBook(int n, {String? title}) => LocalEpubBook(
  digest: bookId(n).substring(5),
  title: title ?? '第 $n 卷',
  author: '作者',
  description: '',
  language: 'zh',
  subjects: const [],
  fileName: '01.epub',
  importedAtMs: n,
  chapters: const [],
  assetNames: const [],
);

void main() {
  late Directory root;
  late LocalEpubOrganizationStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('litetale_epub_batch_');
    store = LocalEpubOrganizationStore();
    await store.initialize(root.path);
  });
  tearDown(() async {
    store.dispose();
    // Only this test's owned temporary tree; individual files, no recursive delete.
    final entries =
        await root.list(recursive: true, followLinks: false).toList();
    for (final file in entries.where((e) => e is File || e is Link)) {
      await file.delete();
    }
    for (final directory
        in entries.whereType<Directory>().toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length))) {
      await directory.delete();
    }
    await root.delete();
  });

  File slot(int n) =>
      File('${root.path}/local_epub_organization/organization-$n.json');

  test(
    'snapshot sequence is covered by checksum; book removal only clears its membership',
    () async {
      final c = await store.createCollection('原名称');
      await store.renameCollection(c.id, '新名称');
      final envelope = jsonDecode(await slot(1).readAsString()) as Map;
      envelope['generation'] = 1000;
      await slot(1).writeAsString(jsonEncode(envelope));
      await store.initialize(root.path);
      expect(store.collections.single.name, '原名称');
      expect(store.warning, isNotNull);
      final library = LocalEpubLibrary(useIsolates: false);
      addTearDown(library.dispose);
      await library.initialize(root.path);
      final book =
          (await library.importFile(
            XFile.fromData(buildEpubFixture(), name: '保留原文件.epub'),
          )).book;
      await library.organization.addBooks(c.id, [book.id]);
      await library.organization.recordOpened(book.id);
      await library.remove(book.id);
      expect(library.organization.isUnfiled(book.id), isTrue);
      expect(library.organization.lastOpened(book.id), 0);
      expect(library.organization.collections.single.id, c.id);
    },
  );

  test(
    'classification persists independently of the EPUB and supports multiple collections',
    () async {
      final a = await store.createCollection('待看');
      final b = await store.createCollection('校园');
      await store.addBooks(a.id, [bookId(1), bookId(2), bookId(1)]);
      await store.addBooks(b.id, [bookId(1)]);
      await store.recordOpened(bookId(1));
      await store.renameCollection(a.id, '明天阅读');
      await store.selectCollection(a.id);
      await store.setSort(EpubLibrarySort.title);
      await store.moveCollection(b.id, -1);
      final restarted = LocalEpubOrganizationStore();
      addTearDown(restarted.dispose);
      await restarted.initialize(root.path);
      expect(restarted.collections.map((c) => c.name), ['校园', '明天阅读']);
      expect(restarted.selectedCollection, a.id);
      expect(restarted.sort, EpubLibrarySort.title);
      expect(restarted.lastOpened(bookId(1)), greaterThan(0));
      expect(restarted.contains(a.id, bookId(1)), isTrue);
      expect(restarted.contains(b.id, bookId(1)), isTrue);
      await restarted.removeCollection(a.id);
      expect(restarted.selectedCollection, allEpubs);
      expect(restarted.contains(b.id, bookId(1)), isTrue);
      expect(restarted.isUnfiled(bookId(2)), isTrue);
      expect(() => restarted.collections.clear(), throwsUnsupportedError);
    },
  );

  test(
    'concurrent batch additions serialize without losing members; errors do not poison writes',
    () async {
      final c = await store.createCollection('收藏');
      await expectLater(
        store.createCollection(' 收藏 '),
        throwsA(isA<EpubOrganizationException>()),
      );
      await expectLater(
        store.createCollection('全部'),
        throwsA(isA<EpubOrganizationException>()),
      );
      await Future.wait(
        List.generate(100, (i) => store.addBooks(c.id, [bookId(i + 1)])),
      );
      expect(
        List.generate(
          100,
          (i) => store.contains(c.id, bookId(i + 1)),
        ).every((v) => v),
        isTrue,
      );
      expect(
        () => store.addBooks(c.id, ['lns:1']),
        throwsA(isA<EpubOrganizationException>()),
      );
      await store.removeBooks(c.id, [bookId(1), bookId(2)]);
      expect(store.isUnfiled(bookId(1)), isTrue);
      expect(store.contains(c.id, bookId(3)), isTrue);
    },
  );

  test(
    'failed atomic write preserves previous state and can be retried',
    () async {
      var fail = false;
      final fragile = LocalEpubOrganizationStore(
        writeFile: (file, contents) async {
          if (fail) {
            await file.writeAsString('partial');
            throw const FileSystemException('full');
          }
          await file.writeAsString(contents, flush: true);
        },
      );
      addTearDown(fragile.dispose);
      await fragile.initialize(root.path);
      final c = await fragile.createCollection('待看');
      fail = true;
      await expectLater(
        fragile.addBooks(c.id, [bookId(1)]),
        throwsA(isA<EpubOrganizationException>()),
      );
      expect(fragile.isUnfiled(bookId(1)), isTrue);
      final restarted = LocalEpubOrganizationStore();
      addTearDown(restarted.dispose);
      await restarted.initialize(root.path);
      expect(restarted.collections.single.name, '待看');
      expect(restarted.isUnfiled(bookId(1)), isTrue);
      fail = false;
      await fragile.addBooks(c.id, [bookId(1)]);
      expect(fragile.contains(c.id, bookId(1)), isTrue);
    },
  );

  test(
    'damaged latest snapshot recovers previous valid snapshot, not a temporary write',
    () async {
      final c = await store.createCollection('旧名称'); // slot 0
      await store.addBooks(c.id, [bookId(1)]); // slot 1
      await store.renameCollection(c.id, '新名称'); // slot 0
      await slot(0).writeAsString('{broken');
      final restarted = LocalEpubOrganizationStore();
      addTearDown(restarted.dispose);
      await restarted.initialize(root.path);
      expect(restarted.isReady, isTrue);
      expect(restarted.warning, isNotNull);
      expect(restarted.collections.single.name, '旧名称');
      expect(restarted.contains(c.id, bookId(1)), isTrue);
      await restarted.renameCollection(c.id, '恢复后名称');
      expect(restarted.warning, isNull);
    },
  );

  test(
    'two invalid snapshots and unknown schema are read-only and are not overwritten',
    () async {
      await store.createCollection('待看');
      await slot(0).writeAsString('broken');
      await slot(1).writeAsString('also broken');
      await store.initialize(root.path);
      expect(store.isReady, isFalse);
      await expectLater(
        store.createCollection('不应写入'),
        throwsA(isA<EpubOrganizationException>()),
      );
      expect(await slot(0).readAsString(), 'broken');
      await slot(1).writeAsString(jsonEncode({'schema': 2, 'generation': 5}));
      await store.retryInitialization();
      expect(store.loadError, contains('较新版本'));
      expect(await slot(0).readAsString(), 'broken');
    },
  );

  test(
    'classification does not parse books; natural sorting and filtered selection use stable IDs',
    () async {
      final c = await store.createCollection('系列');
      final books = [fakeBook(10), fakeBook(2), fakeBook(1)];
      await store.addBooks(c.id, [bookId(1), bookId(10)]);
      await store.setSort(EpubLibrarySort.title);
      expect(queryLocalEpubs(books, store).map((b) => b.id), [
        bookId(1),
        bookId(2),
        bookId(10),
      ]);
      expect(
        queryLocalEpubs(books, store, collectionId: c.id).map((b) => b.id),
        [bookId(1), bookId(10)],
      );
      expect(
        queryLocalEpubs(books, store, collectionId: unfiledEpubs).single.id,
        bookId(2),
      );
      await store.recordOpened(bookId(10));
      await store.setSort(EpubLibrarySort.recent);
      expect(queryLocalEpubs(books, store).first.id, bookId(10));
      expect(
        compareEpubTitles(
          '卷 999999999999999999999',
          '卷 1000000000000000000000',
        ),
        lessThan(0),
      );
    },
  );

  test(
    'stopping keeps active atomic import, cancels pending items, then resumes only pending',
    () async {
      final gate = Completer<EpubImportResult>();
      var calls = 0;
      final queue = EpubImportQueue(
        organization: store,
        importFile: (_) async {
          calls++;
          if (calls == 1) return gate.future;
          return EpubImportResult(fakeBook(calls), alreadyImported: false);
        },
      );
      addTearDown(queue.dispose);
      final batch = queue.start(
        List.generate(20, (i) => XFile('book-$i.epub')),
      );
      expect(queue.isRunning, isTrue);
      expect(() => queue.start([XFile('other.epub')]), throwsStateError);
      queue.stop();
      expect(queue.count(EpubImportStatus.cancelled), 19);
      gate.complete(EpubImportResult(fakeBook(1), alreadyImported: false));
      await batch;
      expect(calls, 1);
      expect(queue.count(EpubImportStatus.imported), 1);
      await queue.resumeCancelled();
      expect(calls, 20);
      expect(queue.count(EpubImportStatus.imported), 20);
      expect(queue.completed, 20);
    },
  );

  test(
    'one bad file does not stop the batch; retry does not reimport successful or duplicate items',
    () async {
      var allow = false;
      final calls = <String>[];
      final queue = EpubImportQueue(
        organization: store,
        importFile: (file) async {
          calls.add(file.name);
          if (file.name == 'bad.epub' && !allow) {
            throw const EpubImportException('损坏的 EPUB');
          }
          return EpubImportResult(
            fakeBook(1),
            alreadyImported: file.name == 'duplicate.epub',
          );
        },
      );
      addTearDown(queue.dispose);
      await queue.start([
        XFile('first.epub'),
        XFile('bad.epub'),
        XFile('duplicate.epub'),
        XFile('last.epub'),
      ]);
      expect(queue.count(EpubImportStatus.imported), 2);
      expect(queue.count(EpubImportStatus.duplicate), 1);
      expect(queue.items[1].error, '损坏的 EPUB');
      allow = true;
      await queue.retryFailed();
      expect(calls, [
        'first.epub',
        'bad.epub',
        'duplicate.epub',
        'last.epub',
        'bad.epub',
      ]);
      expect(queue.completed, 4);
      expect(queue.count(EpubImportStatus.failed), 0);
    },
  );

  test(
    'classification failure keeps committed book; retry classification never rereads the file',
    () async {
      var fail = false;
      final fragile = LocalEpubOrganizationStore(
        writeFile: (file, text) async {
          if (fail) throw const FileSystemException('full');
          await file.writeAsString(text, flush: true);
        },
      );
      addTearDown(fragile.dispose);
      await fragile.initialize(root.path);
      final c = await fragile.createCollection('目标');
      fail = true;
      var calls = 0;
      final queue = EpubImportQueue(
        organization: fragile,
        importFile: (_) async {
          calls++;
          return EpubImportResult(fakeBook(1), alreadyImported: false);
        },
      );
      addTearDown(queue.dispose);
      await queue.start(
        [XFile('first.epub')],
        collectionId: c.id,
        afterImport: (_) => throw StateError('presentation failure'),
      );
      expect(queue.count(EpubImportStatus.imported), 1);
      expect(queue.items.single.result!.book.id, bookId(1));
      expect(queue.classificationFailures, 1);
      expect(queue.items.single.warning, isNotNull);
      fail = false;
      await queue.retryClassification();
      expect(calls, 1);
      expect(queue.classificationFailures, 0);
      expect(fragile.contains(c.id, bookId(1)), isTrue);
    },
  );

  test(
    '100 real EPUBs use one parser at a time, exact duplicate identity, restart and original bytes',
    () async {
      final library = LocalEpubLibrary(useIsolates: false);
      addTearDown(library.dispose);
      await library.initialize(root.path);
      final first = buildEpubFixture(title: '系列 第1卷');
      final bytes = List.generate(
        100,
        (i) => i == 0 ? first : buildEpubFixture(title: '系列 第${i + 1}卷'),
      );
      // Same filenames deliberately exercise content-based identity.
      final files =
          bytes.map((b) => XFile.fromData(b, name: '01.epub')).toList();
      final c = await library.organization.createCollection('导入测试');
      final batch = [
        ...files,
        XFile.fromData(first, name: '同内容新名字.epub'),
        XFile.fromData(utf8.encode('bad zip'), name: '损坏.epub'),
      ];
      await library.imports.start(batch, collectionId: c.id);
      expect(library.imports.count(EpubImportStatus.imported), 100);
      expect(library.imports.count(EpubImportStatus.duplicate), 1);
      expect(library.imports.count(EpubImportStatus.failed), 1);
      expect(library.books, hasLength(100));
      final id = library.imports.items.first.result!.book.id;
      expect(
        await (await library.originalFileForOpening(id)).readAsBytes(),
        first,
      );
      await library.organization.renameCollection(c.id, '重新分类');
      final restarted = LocalEpubLibrary(useIsolates: false);
      addTearDown(restarted.dispose);
      await restarted.initialize(root.path);
      expect(restarted.books, hasLength(100));
      expect(
        restarted.books.every(
          (b) => restarted.organization.contains(c.id, b.id),
        ),
        isTrue,
      );
      expect(restarted.book(id), isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
