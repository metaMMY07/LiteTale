import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../../models/reader_document.dart';
import '../read_result_cache.dart';
import 'epub_models.dart';
import 'epub_parser.dart';
import 'epub_artwork_renderer.dart';
import 'epub_publication_document.dart';

typedef EpubBookParser =
    ParsedEpubBook Function(Uint8List bytes, {String fallbackTitle});

const _manifestName = 'book.json';
const _removedName = 'removed';
const _maxManifestBytes = 8 * 1024 * 1024;
const _maxChapterBytes = 8 * 1024 * 1024;
const _maxChapterJsonBytes = 32 * 1024 * 1024;
const _maxTextBytes = 128 * 1024 * 1024;
const _maxChapterStorageBytes = 256 * 1024 * 1024;
const _maxAssetBytes = 20 * 1024 * 1024;
const _maxTotalAssetBytes = 128 * 1024 * 1024;
final _assetNamePattern = RegExp(
  r'^[a-f0-9]{64}\.(?:png|jpg|gif|webp|bmp|avif)$',
);

/// Private, normalized EPUB files plus an owned original for CSS pagination.
/// Startup reads manifests only; chapter rendering never depends on the
/// document provider's URI remaining available.
class LocalEpubLibrary extends ChangeNotifier {
  LocalEpubLibrary({
    EpubBookParser? parser,
    bool useIsolates = true,
    Future<Uint8List> Function(File file)? readFileBytes,
    Future<void> Function(Directory from, String to)? renameDirectory,
    DateTime Function()? now,
    EpubArtworkRasterizer? rasterizeArtwork,
  }) : _parser = parser ?? parseEpubBook,
       _useIsolates = useIsolates,
       _readFileBytes = readFileBytes ?? _readBytes,
       _renameDirectory = renameDirectory ?? _rename,
       _now = now ?? DateTime.now,
       _renderLegacyArtwork = rasterizeArtwork != null || !Platform.isAndroid,
       _rasterizeArtwork = rasterizeArtwork ?? rasterizeEpubArtwork;

  static final instance = LocalEpubLibrary();

  final EpubBookParser _parser;
  final bool _useIsolates;
  final Future<Uint8List> Function(File file) _readFileBytes;
  final Future<void> Function(Directory from, String to) _renameDirectory;
  final DateTime Function() _now;
  final EpubArtworkRasterizer _rasterizeArtwork;
  final bool _renderLegacyArtwork;
  final _records = <String, _StoredBook>{};
  final _revisions = <String, int>{};
  final _chapterCache = ReadResultCache<String, _LoadedChapter>(
    maxEntries: 12,
    maxWeight: 4 * 1024 * 1024,
    ttl: const Duration(minutes: 30),
    weightOf:
        (value) => value.encodedLength * 4 + value.data.content.length * 2,
  );
  final _assetCache = ReadResultCache<String, Uint8List>(
    maxEntries: 6,
    maxWeight: 8 * 1024 * 1024,
    ttl: const Duration(minutes: 10),
    weightOf: (value) => value.length,
  );
  final _publicationCache = ReadResultCache<String, Uint8List>(
    maxEntries: 1,
    maxWeight: maxEpubInputBytes,
    ttl: const Duration(minutes: 10),
    weightOf: (value) => value.length,
  );
  final _documentCache = ReadResultCache<String, EpubPublicationDocument>(
    maxEntries: 6,
    maxWeight: 24 * 1024 * 1024,
    ttl: const Duration(minutes: 10),
    weightOf:
        (doc) =>
            doc.html.length * 2 +
            doc.resources.values.fold<int>(0, (n, bytes) => n + bytes.length),
  );
  Future<void> _mutationTail = Future<void>.value();
  Completer<void>? _publication;
  String? _base;
  String? _lastRoot;
  String? _initializationError;
  List<String> _loadWarnings = const [];
  var _unique = 0;

  String? get initializationError => _initializationError;
  List<String> get loadWarnings => List.unmodifiable(_loadWarnings);

  List<LocalEpubBook> get books {
    final result = _records.values.map((record) => record.book).toList();
    result.sort((a, b) {
      final date = b.importedAtMs.compareTo(a.importedAtMs);
      return date == 0 ? a.digest.compareTo(b.digest) : date;
    });
    return List.unmodifiable(result);
  }

  LocalEpubBook? book(String id) => _records[id]?.book;
  bool contains(String id) => _records.containsKey(id);
  int revisionFor(String id) => _revisions[id] ?? 0;

  Future<void> initialize(String root) => _mutate(() async {
    _lastRoot = root;
    try {
      final directory = Directory(root).absolute;
      await directory.create(recursive: true);
      final privateRoot = await directory.resolveSymbolicLinks();
      final base = _join(privateRoot, 'local_epub');
      final type = await FileSystemEntity.type(base, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const EpubImportException('本地书库目录不可用，请检查存储空间');
      }
      await Directory(base).create();
      if (await Directory(base).resolveSymbolicLinks() != base) {
        throw const EpubImportException('本地书库目录不可用，请检查存储空间');
      }
      final snapshot = await _background(_loadSnapshot, base);
      for (final id in {..._records.keys, ...snapshot.records.keys}) {
        _revisions[id] = revisionFor(id) + 1;
      }
      _base = base;
      _records
        ..clear()
        ..addAll(snapshot.records);
      _chapterCache.clear();
      _assetCache.clear();
      _publicationCache.clear();
      _documentCache.clear();
      _loadWarnings = snapshot.warnings;
      _initializationError = null;
      notifyListeners();
    } catch (_) {
      _initializationError = '本地书库初始化失败，请检查存储空间后重试';
      notifyListeners();
      rethrow;
    }
  });

  Future<void> retryInitialization() {
    final root = _lastRoot;
    if (root == null) {
      return Future<void>.error(const EpubImportException('本地书库尚未初始化，请重新启动应用'));
    }
    return initialize(root);
  }

  Future<EpubImportResult> importFile(XFile input) => _mutate(() async {
    final base = _requireBase();
    final length = await input.length();
    if (length <= 0 || length > maxEpubInputBytes) {
      throw const EpubImportException('请选择有效的 EPUB 文件（最大 128 MB）');
    }
    final bytes = await input.readAsBytes();
    if (bytes.isEmpty || bytes.length > maxEpubInputBytes) {
      throw const EpubImportException('请选择有效的 EPUB 文件（最大 128 MB）');
    }
    final digest = await _background(_hashInput, bytes);
    final existing = _records['epub:$digest'];
    if (existing != null && !existing.book.needsStyleUpgrade) {
      return EpubImportResult(existing.book, alreadyImported: true);
    }

    final fileName = existing?.book.fileName ?? _displayFileName(input.name);
    final importedAtMs =
        existing?.book.importedAtMs ?? _now().millisecondsSinceEpoch;
    final stage = _join(base, '.import_${digest}_${_nextUnique()}');
    final parser = _parser;
    final parsed = await _background(_parseBookJob, (bytes, fileName, parser));
    if (parsed.digest != digest) {
      throw const EpubImportException('EPUB 文件校验失败');
    }
    final rendered =
        _renderLegacyArtwork
            ? await renderEpubArtwork(parsed, _rasterizeArtwork)
            : parsed;
    final prepared = await _background(_prepareBookJob, (
      base,
      stage,
      rendered,
      digest,
      fileName,
      importedAtMs,
      existing?.book,
      bytes,
    ));
    final target = _join(base, digest);
    String? backup;
    File? journal;
    final publication = Completer<void>();
    _publication = publication;
    try {
      _checkOwnedDirectory(base, stage);
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        // A tombstoned or corrupt former import must never be overwritten. Move
        // it aside intact, allowing this identical book to be imported again.
        _checkOwnedDirectory(base, target);
        backup = _join(base, '.orphan_${digest}_${_nextUnique()}');
        if (existing != null) {
          journal = await _writeUpgradeJournal(base, digest, backup, stage);
        }
        await _renameDirectory(Directory(target), backup);
        existing?.directoryOverride = backup;
      } else if (type != FileSystemEntityType.notFound) {
        throw const EpubImportException('同名本地书籍目录不可用，未覆盖现有文件');
      }
      await _renameDirectory(Directory(stage), target);
      _records[prepared.book.id] = prepared;
      _revisions[prepared.book.id] = revisionFor(prepared.book.id) + 1;
      _chapterCache.clear();
      _assetCache.clear();
      _publicationCache.clear();
      _documentCache.clear();
      _deleteJournal(journal);
      notifyListeners();
      return EpubImportResult(
        prepared.book,
        alreadyImported: false,
        upgraded: existing != null,
      );
    } catch (_) {
      if (existing != null && backup != null) {
        try {
          if (await FileSystemEntity.type(target, followLinks: false) ==
                  FileSystemEntityType.notFound &&
              await FileSystemEntity.type(backup, followLinks: false) ==
                  FileSystemEntityType.directory) {
            _checkOwnedDirectory(base, backup);
            await _renameDirectory(Directory(backup), target);
            existing.directoryOverride = null;
          }
          if (existing.directoryOverride == null) _deleteJournal(journal);
        } catch (_) {
          // Keep the valid old copy and journal for startup recovery. Reads in
          // this process use its retained backing path if restore failed.
        }
      }
      await _background(_removeKnownFilesJob, (base, stage, prepared));
      rethrow;
    } finally {
      if (identical(_publication, publication)) _publication = null;
      publication.complete();
    }
  });

  Future<String> chapter(String bookId, String chapterId) async =>
      (await chapterData(bookId, chapterId)).content;

  Future<EpubPublicationDocument> publication(
    String bookId,
    String chapterId,
  ) async {
    final record = _record(bookId), revision = revisionFor(bookId);
    final index = record.book.chapters.indexWhere(
      (c) =>
          epubChapterId(
            record.book.digest,
            c.stableIndex ?? record.book.chapters.indexOf(c),
          ) ==
          chapterId,
    );
    if (index < 0 || record.publication == null) {
      throw const EpubImportException('请重新导入原 EPUB 以启用完整 CSS');
    }
    final result = await _documentCache.getOrLoad(
      '$bookId:$revision:$chapterId',
      () async {
        final entry = record.publication!;
        final bytes = await _publicationCache.getOrLoad(
          '$bookId:$revision',
          () async {
            final bytes = await _readOwned(record, entry.file, entry.length);
            await _background(_verifyAssetJob, (
              bytes,
              entry.length,
              entry.digest,
            ));
            _assertCurrent(record, revision);
            return bytes;
          },
        );
        final chapter = record.book.chapters[index];
        final document = await _background(_publicationJob, (
          bytes,
          chapter.href,
          chapter.fixedLayout,
          index + 1 < record.book.chapters.length
              ? record.book.chapters[index + 1].href
              : '',
        ));
        _assertCurrent(record, revision);
        return document;
      },
    );
    _assertCurrent(record, revision);
    return result;
  }

  Future<EpubChapterData> chapterData(String bookId, String chapterId) async {
    final record = _record(bookId);
    final prefix = 'epub:${record.book.digest}:c';
    if (!chapterId.startsWith(prefix)) {
      throw const EpubImportException('本地章节编号无效');
    }
    final suffix = chapterId.substring(prefix.length);
    if (!RegExp(r'^(?:0|[1-9][0-9]{0,5})$').hasMatch(suffix)) {
      throw const EpubImportException('本地章节编号无效');
    }
    final stableIndex = int.parse(suffix);
    final index = record.positionFor(stableIndex);
    if (index == null) {
      throw const EpubImportException('本地章节不存在');
    }
    final revision = revisionFor(bookId);
    final result = await _chapterCache.getOrLoad(
      '$bookId:$revision:$stableIndex',
      () async {
        final entry = record.chapters[index];
        final bytes = await _readOwned(record, entry.file, entry.length);
        final content = await _background(_decodeChapterJob, (
          bytes,
          entry.length,
          entry.digest,
          record.book.formatVersion,
          record.book.chapters[index].title,
          record.book.chapters[index].href,
          record.book.digest,
          record.book.assetNames,
        ));
        _assertCurrent(record, revision);
        return content;
      },
    );
    _assertCurrent(record, revision);
    return result.data;
  }

  Future<Uint8List> readAsset(String url) async {
    final match = RegExp(
      r'^epub-asset:([a-f0-9]{64})/([a-f0-9]{64}\.(?:png|jpg|gif|webp|bmp|avif))$',
    ).firstMatch(url);
    if (match == null) throw const EpubImportException('本地图片地址无效');
    final record = _record('epub:${match[1]}');
    final entry = record.assets[match[2]];
    if (entry == null) throw const EpubImportException('本地图片不存在');
    final revision = revisionFor(record.book.id);
    final result = await _assetCache.getOrLoad('$url:$revision', () async {
      final bytes = await _readOwned(record, entry.file, entry.length);
      await _background(_verifyAssetJob, (bytes, entry.length, entry.digest));
      _assertCurrent(record, revision);
      return bytes.asUnmodifiableView();
    });
    _assertCurrent(record, revision);
    return result;
  }

  Future<void> remove(String bookId) => _mutate(() async {
    final record = _records[bookId];
    if (record == null) return;
    final base = _requireBase();
    var directory = record.directoryOverride ?? _join(base, record.book.digest);
    final type = await FileSystemEntity.type(directory, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      _checkOwnedDirectory(base, directory);
      final tombstone = File(_join(directory, _removedName));
      final markerType = await FileSystemEntity.type(
        tombstone.path,
        followLinks: false,
      );
      if (markerType == FileSystemEntityType.notFound ||
          markerType == FileSystemEntityType.file) {
        await tombstone.writeAsString('removed', flush: true);
      }
    }

    // Invalidate before file I/O completes; old readers may not publish their
    // result into a newly imported book with the same digest.
    _records.remove(bookId);
    _revisions[bookId] = revisionFor(bookId) + 1;
    _chapterCache.clear();
    _assetCache.clear();
    _publicationCache.clear();
    _documentCache.clear();
    notifyListeners();
    if (type != FileSystemEntityType.directory) return;

    try {
      final retired = _join(
        base,
        '.removed_${record.book.digest}_${_nextUnique()}',
      );
      await Directory(directory).rename(retired);
      directory = retired;
    } on FileSystemException {
      // The durable tombstone already prevents resurrection after restart.
    }
    final cleaned = await _background(_removeKnownFilesJob, (
      base,
      directory,
      record,
    ));
    if (!cleaned) {
      _loadWarnings = [..._loadWarnings, '书籍已移除，部分剩余文件未清理'];
    }
  });

  Future<Uint8List> _readOwned(
    _StoredBook record,
    String name,
    int expectedLength,
  ) async {
    final base = _requireBase();
    await _awaitPublication(record);
    final directory =
        record.directoryOverride ?? _join(base, record.book.digest);
    try {
      _checkOwnedDirectory(base, directory);
      final file = _checkedFile(directory, name);
      if (await file.length() != expectedLength) {
        throw const EpubImportException('本地书籍文件损坏，请移除后重新导入');
      }
      await _awaitPublication(record);
      final bytes = await _readFileBytes(file);
      await _awaitPublication(record);
      if (bytes.length != expectedLength) {
        throw const EpubImportException('本地书籍文件损坏，请移除后重新导入');
      }
      return bytes;
    } on FileSystemException {
      throw const EpubImportException('本地书籍文件缺失，请移除后重新导入');
    }
  }

  Future<void> _awaitPublication(_StoredBook record) async {
    final publication = _publication;
    if (publication != null) await publication.future;
    if (!identical(_records[record.book.id], record)) {
      throw const EpubImportException('这本本地书籍已更新，请重新打开');
    }
  }

  _StoredBook _record(String id) {
    epubDigestFromId(id);
    final record = _records[id];
    if (record == null) throw const EpubImportException('这本本地书籍已被移除');
    return record;
  }

  void _assertCurrent(_StoredBook record, int revision) {
    if (!identical(_records[record.book.id], record) ||
        revisionFor(record.book.id) != revision) {
      throw const EpubImportException('这本本地书籍已被移除或重新导入');
    }
  }

  String _requireBase() {
    if (_base == null || _initializationError != null) {
      throw const EpubImportException('本地书库尚未准备好，请重试');
    }
    return _base!;
  }

  String _nextUnique() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_unique++}';

  Future<R> _background<R, M>(R Function(M) callback, M message) =>
      _useIsolates
          ? compute(callback, message)
          : Future<R>.sync(() => callback(message));

  Future<T> _mutate<T>(Future<T> Function() operation) {
    final completion = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completion.complete(await operation());
      } catch (error, stack) {
        completion.completeError(error, stack);
      }
    });
    return completion.future;
  }
}

Future<Uint8List> _readBytes(File file) => file.readAsBytes();
Future<void> _rename(Directory from, String to) async {
  await from.rename(to);
}

String _hashInput(Uint8List bytes) => sha256.convert(bytes).toString();

// Only top-level callbacks and explicit data cross isolate boundaries. A closure
// created in an async library method can implicitly capture this and its queue.
_LoadedChapter _decodeChapterJob(
  (Uint8List, int, String, int, String, String, String, List<String>) data,
) {
  _verifyBytes(data.$1, data.$2, data.$3);
  try {
    final text = utf8.decode(data.$1);
    if (data.$4 == 1) {
      return _LoadedChapter(
        EpubChapterData(title: data.$5, href: data.$6, content: text),
        data.$1.length,
      );
    }
    final payload = jsonDecode(text);
    if (payload is! Map ||
        payload['schema'] != 1 ||
        payload['content'] is! String) {
      throw const FormatException('invalid chapter payload');
    }
    final content = payload['content'] as String;
    if (utf8.encode(content).length > _maxChapterBytes) {
      throw const FormatException('oversized plain chapter');
    }
    final document =
        payload['document'] == null
            ? null
            : ReaderDocument.fromJson(payload['document']);
    if (document != null) {
      if (document.content != content) {
        throw const FormatException('plain and styled text differ');
      }
      var runs = 0;
      final ownedAssets = data.$8.toSet();
      for (final block in document.blocks) {
        runs += block.runs.length;
        if (runs > 200000) throw const FormatException('too many reader runs');
        for (final image in [block.imageUrl, block.artworkUrl]) {
          if (image != null) {
            final prefix = 'epub-asset:${data.$7}/';
            if (!image.startsWith(prefix) ||
                !ownedAssets.contains(image.substring(prefix.length))) {
              throw const FormatException('nonowned reader image');
            }
          }
        }
      }
    }
    return _LoadedChapter(
      EpubChapterData(
        title: data.$5,
        href: data.$6,
        content: content,
        document: document,
      ),
      data.$1.length,
    );
  } on EpubImportException {
    rethrow;
  } catch (_) {
    throw const EpubImportException('本地章节排版数据损坏，请移除后重新导入');
  }
}

class _LoadedChapter {
  const _LoadedChapter(this.data, this.encodedLength);
  final EpubChapterData data;
  final int encodedLength;
}

bool _verifyAssetJob((Uint8List, int, String) data) {
  _verifyBytes(data.$1, data.$2, data.$3);
  return true;
}

_StoredBook _prepareBookJob(
  (
    String,
    String,
    ParsedEpubBook,
    String,
    String,
    int,
    LocalEpubBook?,
    Uint8List,
  )
  data,
) => _prepareBook(
  data.$1,
  data.$2,
  data.$3,
  data.$4,
  data.$5,
  data.$6,
  data.$7,
  data.$8,
);

EpubPublicationDocument _publicationJob(
  (Uint8List, String, bool, String) data,
) => readEpubPublication(
  data.$1,
  data.$2,
  fixedLayout: data.$3,
  endHref: data.$4,
);

ParsedEpubBook _parseBookJob((Uint8List, String, EpubBookParser) data) =>
    data.$3(data.$1, fallbackTitle: data.$2);

bool _removeKnownFilesJob((String, String, _StoredBook) data) =>
    _removeKnownFiles(data.$1, data.$2, data.$3);

String _join(String base, String name) => '$base${Platform.pathSeparator}$name';
String _chapterFile(int index, [int formatVersion = 2]) =>
    'chapter_$index.${formatVersion == 1 ? 'txt' : 'json'}';

String _displayFileName(String value) {
  final name = value.replaceAll('\\', '/').split('/').last;
  final display = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (display.isEmpty) return '本地书籍.epub';
  return display.length > 255 ? display.substring(0, 255) : display;
}

void _checkOwnedDirectory(String base, String directory) {
  if (Directory(directory).parent.path != base ||
      FileSystemEntity.typeSync(directory, followLinks: false) !=
          FileSystemEntityType.directory ||
      Directory(directory).resolveSymbolicLinksSync() != directory ||
      Directory(base).resolveSymbolicLinksSync() != base) {
    throw const EpubImportException('本地书籍目录不可用，请移除后重新导入');
  }
}

File _checkedFile(String directory, String name) {
  if (name.contains('/') ||
      name.contains('\\') ||
      name == '.' ||
      name == '..') {
    throw const EpubImportException('本地书籍文件名无效');
  }
  final file = File(_join(directory, name));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      file.resolveSymbolicLinksSync() != file.path) {
    throw const EpubImportException('本地书籍文件缺失，请移除后重新导入');
  }
  return file;
}

void _verifyBytes(Uint8List bytes, int length, String digest) {
  if (bytes.length != length || sha256.convert(bytes).toString() != digest) {
    throw const EpubImportException('本地书籍文件损坏，请移除后重新导入');
  }
}

class _OwnedEntry {
  const _OwnedEntry(this.file, this.length, this.digest);
  final String file, digest;
  final int length;
  Map<String, Object> toJson() => {
    'file': file,
    'length': length,
    'sha256': digest,
  };
}

class _StoredBook {
  _StoredBook(this.book, this.chapters, this.assets, [this.publication]);
  final LocalEpubBook book;
  final List<_OwnedEntry> chapters;
  final Map<String, _OwnedEntry> assets;
  final _OwnedEntry? publication;
  String? directoryOverride;
  late final Map<int, int> _positions = {
    for (var i = 0; i < book.chapters.length; i++)
      book.chapters[i].stableIndex ?? i: i,
  };
  int? positionFor(int stableIndex) => _positions[stableIndex];
  Map<String, Object?> toJson() => {
    'schema': book.formatVersion,
    'styleRevision': book.styleRevision,
    'digest': book.digest,
    'title': book.title,
    'author': book.author,
    'description': book.description,
    'language': book.language,
    'subjects': book.subjects,
    'fileName': book.fileName,
    'importedAtMs': book.importedAtMs,
    'coverAssetName': book.coverAssetName,
    'warnings': book.warnings,
    if (publication != null) 'publication': publication!.toJson(),
    'chapters': [
      for (var i = 0; i < chapters.length; i++)
        {
          ...chapters[i].toJson(),
          'title': book.chapters[i].title,
          'href': book.chapters[i].href,
          if (book.formatVersion >= 3)
            'fixedLayout': book.chapters[i].fixedLayout,
          if (book.formatVersion >= 2)
            'stableIndex': book.chapters[i].stableIndex ?? i,
        },
    ],
    'assets': [for (final entry in assets.values) entry.toJson()],
  };
}

class _LibrarySnapshot {
  const _LibrarySnapshot(this.records, this.warnings);
  final Map<String, _StoredBook> records;
  final List<String> warnings;
}

Future<File> _writeUpgradeJournal(
  String base,
  String digest,
  String backup,
  String stage,
) async {
  final file = File(_join(base, '.upgrade_$digest.json'));
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (Directory(base).resolveSymbolicLinksSync() != base ||
      (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file)) {
    throw const EpubImportException('本地书籍升级记录不可用，原书已保留');
  }
  await file.writeAsString(
    jsonEncode({
      'schema': 1,
      'digest': digest,
      'backup':
          Directory(
            backup,
          ).uri.pathSegments.where((part) => part.isNotEmpty).last,
      'stage':
          Directory(
            stage,
          ).uri.pathSegments.where((part) => part.isNotEmpty).last,
    }),
    flush: true,
  );
  return file;
}

void _deleteJournal(File? file) {
  if (file == null) return;
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file &&
        file.resolveSymbolicLinksSync() == file.path) {
      file.deleteSync();
    }
  } on FileSystemException {
    // A leftover journal is harmless: startup validates the active manifest.
  }
}

List<String> _recoverUpgrades(String base) {
  final warnings = <String>[];
  for (final child in Directory(base).listSync(followLinks: false)) {
    final name = child.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final match = RegExp(r'^\.upgrade_([a-f0-9]{64})\.json$').firstMatch(name);
    if (match == null || child is! File) continue;
    try {
      final file = _checkedFile(base, name);
      if (file.lengthSync() > 2048) {
        throw const FormatException('large upgrade journal');
      }
      final value = jsonDecode(file.readAsStringSync());
      final digest = match[1]!;
      if (value is! Map || value['schema'] != 1 || value['digest'] != digest) {
        throw const FormatException('invalid upgrade journal');
      }
      final backupName = value['backup'];
      final stageName = value['stage'];
      if (backupName is! String ||
          stageName is! String ||
          !RegExp(
            '^\\.orphan_${digest}_[0-9]+_[0-9]+\$',
          ).hasMatch(backupName) ||
          !RegExp('^\\.import_${digest}_[0-9]+_[0-9]+\$').hasMatch(stageName)) {
        throw const FormatException('invalid recovery paths');
      }
      final target = _join(base, digest);
      final targetType = FileSystemEntity.typeSync(target, followLinks: false);
      if (targetType == FileSystemEntityType.notFound) {
        final backup = _join(base, backupName);
        _readValidatedBookDirectory(base, backup, digest);
        Directory(backup).renameSync(target);
      }
      _readValidatedBookDirectory(base, target, digest);
      _deleteJournal(file);
    } catch (_) {
      warnings.add('一本本地书籍的升级未完成，原文件已保留，请重试导入');
    }
  }
  return warnings;
}

_StoredBook _readValidatedBookDirectory(
  String base,
  String directory,
  String digest,
) {
  _checkOwnedDirectory(base, directory);
  if (FileSystemEntity.typeSync(
        _join(directory, _removedName),
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('book removed');
  }
  final manifest = _checkedFile(directory, _manifestName);
  if (manifest.lengthSync() > _maxManifestBytes) {
    throw const FormatException('manifest too large');
  }
  return _readManifest(jsonDecode(manifest.readAsStringSync()), digest);
}

_LibrarySnapshot _loadSnapshot(String base) {
  final books = <String, _StoredBook>{};
  final warnings = _recoverUpgrades(base);
  for (final child in Directory(base).listSync(followLinks: false)) {
    final digest = child.uri.pathSegments.where((part) => part.isNotEmpty).last;
    if (child is! Directory || !isEpubDigest(digest)) continue;
    try {
      _checkOwnedDirectory(base, child.path);
      if (FileSystemEntity.typeSync(
            _join(child.path, _removedName),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      final file = _checkedFile(child.path, _manifestName);
      if (file.lengthSync() > _maxManifestBytes) {
        throw const FormatException('manifest too large');
      }
      final record = _readManifest(jsonDecode(file.readAsStringSync()), digest);
      books[record.book.id] = record;
    } catch (_) {
      warnings.add('一本本地书籍的信息损坏，已跳过；可重新导入原文件');
    }
  }
  return _LibrarySnapshot(books, warnings);
}

_StoredBook _readManifest(Object? value, String expectedDigest) {
  if (value is! Map<String, dynamic> ||
      !const [1, 2, 3].contains(value['schema']) ||
      value['digest'] != expectedDigest) {
    throw const FormatException('invalid manifest');
  }
  final formatVersion = value['schema'] as int;
  String text(String key, {int max = 4096}) {
    final item = value[key];
    if (item is! String || item.length > max) {
      throw const FormatException('invalid text');
    }
    return item;
  }

  List<String> strings(String key, {int max = 1024}) {
    final items = value[key];
    if (items is! List || items.length > max) {
      throw const FormatException('invalid list');
    }
    return List.unmodifiable([
      for (final item in items)
        if (item is String && item.length <= 4096)
          item
        else
          throw const FormatException('invalid list item'),
    ]);
  }

  final at = value['importedAtMs'];
  final chapterList = value['chapters'];
  final assetList = value['assets'];
  final cover = value['coverAssetName'];
  if (at is! int ||
      at < 0 ||
      chapterList is! List ||
      chapterList.isEmpty ||
      chapterList.length > 10000 ||
      assetList is! List ||
      assetList.length > 10000 ||
      (cover != null && cover is! String)) {
    throw const FormatException('invalid manifest entries');
  }
  final chapterEntries = <_OwnedEntry>[];
  final chapters = <LocalEpubChapter>[];
  final stableIndices = <int>{};
  var totalText = 0;
  for (var i = 0; i < chapterList.length; i++) {
    final item = chapterList[i];
    final entry = _readEntry(
      item,
      formatVersion == 1 ? _maxChapterBytes : _maxChapterJsonBytes,
    );
    if (entry.file != _chapterFile(i, formatVersion) ||
        item is! Map ||
        item['title'] is! String ||
        (item['title'] as String).length > 4096 ||
        item['href'] is! String ||
        (item['href'] as String).length > 4096) {
      throw const FormatException('invalid chapter');
    }
    final stableIndex = formatVersion == 1 ? i : item['stableIndex'];
    if (stableIndex is! int ||
        stableIndex < 0 ||
        stableIndex > 999999 ||
        !stableIndices.add(stableIndex)) {
      throw const FormatException('invalid stable chapter id');
    }
    if (formatVersion >= 3 && item['fixedLayout'] is! bool) {
      throw const FormatException('invalid chapter layout');
    }
    totalText += entry.length;
    chapterEntries.add(entry);
    chapters.add(
      LocalEpubChapter(
        title: item['title'],
        href: item['href'],
        stableIndex: stableIndex,
        fixedLayout: formatVersion >= 3 && item['fixedLayout'] == true,
      ),
    );
  }
  final assets = <String, _OwnedEntry>{};
  var totalAssets = 0;
  for (final item in assetList) {
    final entry = _readEntry(item, _maxAssetBytes);
    if (!_assetNamePattern.hasMatch(entry.file) ||
        entry.digest != entry.file.substring(0, 64) ||
        assets.containsKey(entry.file)) {
      throw const FormatException('invalid asset');
    }
    totalAssets += entry.length;
    assets[entry.file] = entry;
  }
  if (totalText >
          (formatVersion == 1 ? _maxTextBytes : _maxChapterStorageBytes) ||
      totalAssets > _maxTotalAssetBytes ||
      (cover != null && !assets.containsKey(cover))) {
    throw const FormatException('invalid manifest totals or cover');
  }
  final styleRevision = value['styleRevision'] ?? 1;
  if (styleRevision is! int || styleRevision < 1 || styleRevision > 100000) {
    throw const FormatException('invalid style revision');
  }
  final book = LocalEpubBook(
    digest: expectedDigest,
    title: text('title'),
    author: text('author'),
    description: text('description', max: 1024 * 1024),
    language: text('language'),
    subjects: strings('subjects'),
    fileName: text('fileName', max: 255),
    importedAtMs: at,
    chapters: List.unmodifiable(chapters),
    assetNames: List.unmodifiable(assets.keys),
    coverAssetName: cover as String?,
    warnings: strings('warnings'),
    formatVersion: formatVersion,
    styleRevision: styleRevision,
  );
  final publication =
      formatVersion < 3
          ? null
          : _readEntry(value['publication'], maxEpubInputBytes);
  if (publication != null &&
      (publication.file != 'publication.epub' ||
          publication.digest != expectedDigest)) {
    throw const FormatException('invalid publication');
  }
  return _StoredBook(
    book,
    List.unmodifiable(chapterEntries),
    assets,
    publication,
  );
}

_OwnedEntry _readEntry(Object? value, int maxBytes) {
  if (value is! Map ||
      value['file'] is! String ||
      value['length'] is! int ||
      value['length'] < 0 ||
      value['length'] > maxBytes ||
      value['sha256'] is! String ||
      !isEpubDigest(value['sha256'])) {
    throw const FormatException('invalid stored file');
  }
  return _OwnedEntry(value['file'], value['length'], value['sha256']);
}

_StoredBook _prepareBook(
  String base,
  String stage,
  ParsedEpubBook parsed,
  String digest,
  String fileName,
  int importedAtMs,
  LocalEpubBook? previous,
  Uint8List publication,
) {
  if (parsed.digest != digest) {
    throw const EpubImportException('EPUB 文件校验失败');
  }
  final chapterEntries = <_OwnedEntry>[];
  final assets = <String, _OwnedEntry>{};
  final chapterBytes = <Uint8List>[];
  final stableIndices = _stableChapterIndices(parsed.chapters, previous);
  var totalPlainBytes = 0;
  for (var i = 0; i < parsed.chapters.length; i++) {
    final chapter = parsed.chapters[i];
    final plainLength = utf8.encode(chapter.content).length;
    totalPlainBytes += plainLength;
    if (plainLength > _maxChapterBytes || totalPlainBytes > _maxTextBytes) {
      throw const EpubImportException('EPUB 正文过大，暂不支持导入');
    }
    final data = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'content': chapter.content,
          'document': chapter.document?.toJson(),
        }),
      ),
    );
    if (data.length > _maxChapterJsonBytes) {
      throw const EpubImportException('EPUB 章节排版数据过大，暂不支持导入');
    }
    final checksum = sha256.convert(data).toString();
    _decodeChapterJob((
      data,
      data.length,
      checksum,
      2,
      chapter.title,
      chapter.href,
      digest,
      parsed.assets.keys.toList(),
    ));
    chapterBytes.add(data);
    chapterEntries.add(_OwnedEntry(_chapterFile(i), data.length, checksum));
  }
  for (final asset in parsed.assets.entries) {
    if (!_assetNamePattern.hasMatch(asset.key) ||
        sha256.convert(asset.value).toString() != asset.key.substring(0, 64)) {
      throw const EpubImportException('EPUB 图片校验失败');
    }
    assets[asset.key] = _OwnedEntry(
      asset.key,
      asset.value.length,
      asset.key.substring(0, 64),
    );
  }
  final proposed = _StoredBook(
    LocalEpubBook(
      digest: digest,
      title: parsed.title,
      author: parsed.author,
      description: parsed.description,
      language: parsed.language,
      subjects: parsed.subjects,
      fileName: fileName,
      importedAtMs: importedAtMs,
      chapters: [
        for (var i = 0; i < parsed.chapters.length; i++)
          LocalEpubChapter(
            title: parsed.chapters[i].title,
            href: parsed.chapters[i].href,
            stableIndex: stableIndices[i],
            fixedLayout: parsed.chapters[i].fixedLayout,
          ),
      ],
      assetNames: assets.keys.toList(),
      coverAssetName: parsed.coverAssetName,
      warnings: parsed.warnings,
      formatVersion: 3,
      styleRevision:
          parsed.artworkNeedsRetry
              ? currentEpubStyleRevision - 1
              : currentEpubStyleRevision,
    ),
    chapterEntries,
    assets,
    _OwnedEntry('publication.epub', publication.length, digest),
  );
  // The same strict schema is used for imports and persisted metadata.
  final record = _readManifest(proposed.toJson(), digest);
  final metadata = utf8.encode(jsonEncode(record.toJson()));
  if (metadata.length > _maxManifestBytes) {
    throw const EpubImportException('EPUB 目录过大，暂不支持导入');
  }
  if (Directory(stage).parent.path != base ||
      Directory(base).resolveSymbolicLinksSync() != base ||
      FileSystemEntity.typeSync(stage, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw const EpubImportException('本地书籍目录不可用');
  }
  Directory(stage).createSync();
  try {
    File(
      _join(stage, 'publication.epub'),
    ).writeAsBytesSync(publication, flush: true);
    for (var i = 0; i < chapterBytes.length; i++) {
      File(_join(stage, _chapterFile(i))).writeAsBytesSync(chapterBytes[i]);
    }
    for (final asset in parsed.assets.entries) {
      File(_join(stage, asset.key)).writeAsBytesSync(asset.value);
    }
    File(_join(stage, _manifestName)).writeAsBytesSync(metadata, flush: true);
    return record;
  } catch (_) {
    _removeKnownFiles(base, stage, record);
    rethrow;
  }
}

List<int> _stableChapterIndices(
  List<EpubChapterData> chapters,
  LocalEpubBook? previous,
) {
  if (previous == null) return List.generate(chapters.length, (index) => index);
  final oldIds = <String, int>{};
  for (var i = 0; i < previous.chapters.length; i++) {
    final chapter = previous.chapters[i];
    if (chapter.href.isEmpty || oldIds.containsKey(chapter.href)) {
      throw const EpubImportException('原书章节地址存在歧义，无法安全升级；原书与阅读记录已保留');
    }
    oldIds[chapter.href] = chapter.stableIndex ?? i;
  }
  final newCounts = <String, int>{};
  for (final chapter in chapters) {
    newCounts.update(chapter.href, (count) => count + 1, ifAbsent: () => 1);
  }
  if (oldIds.keys.any((href) => newCounts[href] != 1)) {
    throw const EpubImportException('新版解析的章节结构有变化，无法保留原阅读位置；升级已取消，原书与阅读记录已保留');
  }
  var next =
      oldIds.values.fold(-1, (maximum, id) => id > maximum ? id : maximum) + 1;
  final indices = <int>[];
  for (final chapter in chapters) {
    final index = oldIds[chapter.href] ?? next++;
    if (index > 999999) throw const EpubImportException('章节数量过多，无法安全升级；原书已保留');
    indices.add(index);
  }
  return indices;
}

/// Deliberately nonrecursive: unknown files and links are retained. A removed
/// digest directory keeps its tombstone until an empty directory can be deleted.
bool _removeKnownFiles(String base, String directory, _StoredBook record) {
  try {
    _checkOwnedDirectory(base, directory);
    for (final name in [
      ...record.chapters.map((entry) => entry.file),
      ...record.assets.keys,
      if (record.publication != null) record.publication!.file,
      _manifestName,
    ]) {
      final path = _join(directory, name);
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.file) {
        File(path).deleteSync();
      }
    }
    final marker = _join(directory, _removedName);
    final remaining = Directory(directory).listSync(followLinks: false);
    if (remaining.every((entry) => entry.path == marker)) {
      if (FileSystemEntity.typeSync(marker, followLinks: false) ==
          FileSystemEntityType.file) {
        File(marker).deleteSync();
      }
      Directory(directory).deleteSync();
      return true;
    }
  } catch (_) {
    // Logical removal is durable; storage failures cannot restore the book.
  }
  return false;
}
