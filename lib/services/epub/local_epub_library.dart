import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../read_result_cache.dart';
import 'epub_models.dart';
import 'epub_parser.dart';

typedef EpubBookParser =
    ParsedEpubBook Function(Uint8List bytes, {String fallbackTitle});

const _manifestName = 'book.json';
const _removedName = 'removed';
const _maxManifestBytes = 8 * 1024 * 1024;
const _maxChapterBytes = 8 * 1024 * 1024;
const _maxTextBytes = 128 * 1024 * 1024;
const _maxAssetBytes = 20 * 1024 * 1024;
const _maxTotalAssetBytes = 128 * 1024 * 1024;
final _assetNamePattern = RegExp(
  r'^[a-f0-9]{64}\.(?:png|jpg|gif|webp|bmp|avif)$',
);

/// Private, normalized EPUB files. Startup reads manifests only; import converts
/// once in an isolate, so reading never decompresses a ZIP or depends on the
/// original document provider's URI remaining available.
class LocalEpubLibrary extends ChangeNotifier {
  LocalEpubLibrary({
    EpubBookParser? parser,
    bool useIsolates = true,
    Future<Uint8List> Function(File file)? readFileBytes,
    DateTime Function()? now,
  }) : _parser = parser ?? parseEpubBook,
       _useIsolates = useIsolates,
       _readFileBytes = readFileBytes ?? _readBytes,
       _now = now ?? DateTime.now;

  static final instance = LocalEpubLibrary();

  final EpubBookParser _parser;
  final bool _useIsolates;
  final Future<Uint8List> Function(File file) _readFileBytes;
  final DateTime Function() _now;
  final _records = <String, _StoredBook>{};
  final _revisions = <String, int>{};
  final _chapterCache = ReadResultCache<String, String>(
    maxEntries: 12,
    maxWeight: 4 * 1024 * 1024,
    ttl: const Duration(minutes: 30),
    weightOf: (value) => value.length * 2,
  );
  final _assetCache = ReadResultCache<String, Uint8List>(
    maxEntries: 6,
    maxWeight: 8 * 1024 * 1024,
    ttl: const Duration(minutes: 10),
    weightOf: (value) => value.length,
  );
  Future<void> _mutationTail = Future<void>.value();
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
    if (existing != null) {
      return EpubImportResult(existing.book, alreadyImported: true);
    }

    final fileName = _displayFileName(input.name);
    final importedAtMs = _now().millisecondsSinceEpoch;
    final stage = _join(base, '.import_${digest}_${_nextUnique()}');
    final parser = _parser;
    final prepared = await _background(_prepareBookJob, (
      base,
      stage,
      bytes,
      digest,
      fileName,
      importedAtMs,
      parser,
    ));
    try {
      _checkOwnedDirectory(base, stage);
      final target = _join(base, digest);
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        // A tombstoned or corrupt former import must never be overwritten. Move
        // it aside intact, allowing this identical book to be imported again.
        _checkOwnedDirectory(base, target);
        await Directory(
          target,
        ).rename(_join(base, '.orphan_${digest}_${_nextUnique()}'));
      } else if (type != FileSystemEntityType.notFound) {
        throw const EpubImportException('同名本地书籍目录不可用，未覆盖现有文件');
      }
      await Directory(stage).rename(target);
      _records[prepared.book.id] = prepared;
      _revisions[prepared.book.id] = revisionFor(prepared.book.id) + 1;
      notifyListeners();
      return EpubImportResult(prepared.book, alreadyImported: false);
    } catch (_) {
      await _background(_removeKnownFilesJob, (base, stage, prepared));
      rethrow;
    }
  });

  Future<String> chapter(String bookId, String chapterId) async {
    final record = _record(bookId);
    final prefix = 'epub:${record.book.digest}:c';
    if (!chapterId.startsWith(prefix)) {
      throw const EpubImportException('本地章节编号无效');
    }
    final suffix = chapterId.substring(prefix.length);
    if (!RegExp(r'^(?:0|[1-9][0-9]{0,5})$').hasMatch(suffix)) {
      throw const EpubImportException('本地章节编号无效');
    }
    final index = int.parse(suffix);
    if (index >= record.chapters.length) {
      throw const EpubImportException('本地章节不存在');
    }
    final revision = revisionFor(bookId);
    final result = await _chapterCache.getOrLoad(
      '$bookId:$revision:$index',
      () async {
        final entry = record.chapters[index];
        final bytes = await _readOwned(record, entry.file, entry.length);
        final content = await _background(_decodeChapterJob, (
          bytes,
          entry.length,
          entry.digest,
        ));
        _assertCurrent(record, revision);
        return content;
      },
    );
    _assertCurrent(record, revision);
    return result;
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
    var directory = _join(base, record.book.digest);
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
    final directory = _join(base, record.book.digest);
    try {
      _checkOwnedDirectory(base, directory);
      final file = _checkedFile(directory, name);
      if (await file.length() != expectedLength) {
        throw const EpubImportException('本地书籍文件损坏，请移除后重新导入');
      }
      final bytes = await _readFileBytes(file);
      if (bytes.length != expectedLength) {
        throw const EpubImportException('本地书籍文件损坏，请移除后重新导入');
      }
      return bytes;
    } on FileSystemException {
      throw const EpubImportException('本地书籍文件缺失，请移除后重新导入');
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
String _hashInput(Uint8List bytes) => sha256.convert(bytes).toString();

// Only top-level callbacks and explicit data cross isolate boundaries. A closure
// created in an async library method can implicitly capture this and its queue.
String _decodeChapterJob((Uint8List, int, String) data) {
  _verifyBytes(data.$1, data.$2, data.$3);
  return utf8.decode(data.$1);
}

bool _verifyAssetJob((Uint8List, int, String) data) {
  _verifyBytes(data.$1, data.$2, data.$3);
  return true;
}

_StoredBook _prepareBookJob(
  (String, String, Uint8List, String, String, int, EpubBookParser) data,
) =>
    _prepareBook(data.$1, data.$2, data.$3, data.$4, data.$5, data.$6, data.$7);

bool _removeKnownFilesJob((String, String, _StoredBook) data) =>
    _removeKnownFiles(data.$1, data.$2, data.$3);

String _join(String base, String name) => '$base${Platform.pathSeparator}$name';
String _chapterFile(int index) => 'chapter_$index.txt';

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
  const _StoredBook(this.book, this.chapters, this.assets);
  final LocalEpubBook book;
  final List<_OwnedEntry> chapters;
  final Map<String, _OwnedEntry> assets;
  Map<String, Object?> toJson() => {
    'schema': 1,
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
    'chapters': [
      for (var i = 0; i < chapters.length; i++)
        {
          ...chapters[i].toJson(),
          'title': book.chapters[i].title,
          'href': book.chapters[i].href,
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

_LibrarySnapshot _loadSnapshot(String base) {
  final books = <String, _StoredBook>{};
  final warnings = <String>[];
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
      value['schema'] != 1 ||
      value['digest'] != expectedDigest) {
    throw const FormatException('invalid manifest');
  }
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
  var totalText = 0;
  for (var i = 0; i < chapterList.length; i++) {
    final item = chapterList[i];
    final entry = _readEntry(item, _maxChapterBytes);
    if (entry.file != _chapterFile(i) ||
        item is! Map ||
        item['title'] is! String ||
        (item['title'] as String).length > 4096 ||
        item['href'] is! String ||
        (item['href'] as String).length > 4096) {
      throw const FormatException('invalid chapter');
    }
    totalText += entry.length;
    chapterEntries.add(entry);
    chapters.add(LocalEpubChapter(title: item['title'], href: item['href']));
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
  if (totalText > _maxTextBytes ||
      totalAssets > _maxTotalAssetBytes ||
      (cover != null && !assets.containsKey(cover))) {
    throw const FormatException('invalid manifest totals or cover');
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
  );
  return _StoredBook(book, List.unmodifiable(chapterEntries), assets);
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
  Uint8List bytes,
  String digest,
  String fileName,
  int importedAtMs,
  EpubBookParser parser,
) {
  final parsed = parser(bytes, fallbackTitle: fileName);
  if (parsed.digest != digest) {
    throw const EpubImportException('EPUB 文件校验失败');
  }
  final chapterEntries = <_OwnedEntry>[];
  final assets = <String, _OwnedEntry>{};
  final chapterBytes = <Uint8List>[];
  for (var i = 0; i < parsed.chapters.length; i++) {
    final data = Uint8List.fromList(utf8.encode(parsed.chapters[i].content));
    chapterBytes.add(data);
    chapterEntries.add(
      _OwnedEntry(
        _chapterFile(i),
        data.length,
        sha256.convert(data).toString(),
      ),
    );
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
        for (final chapter in parsed.chapters)
          LocalEpubChapter(title: chapter.title, href: chapter.href),
      ],
      assetNames: assets.keys.toList(),
      coverAssetName: parsed.coverAssetName,
      warnings: parsed.warnings,
    ),
    chapterEntries,
    assets,
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

/// Deliberately nonrecursive: unknown files and links are retained. A removed
/// digest directory keeps its tombstone until an empty directory can be deleted.
bool _removeKnownFiles(String base, String directory, _StoredBook record) {
  try {
    _checkOwnedDirectory(base, directory);
    for (final name in [
      ...record.chapters.map((entry) => entry.file),
      ...record.assets.keys,
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
