import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const allEpubs = 'all';
const unfiledEpubs = 'unfiled';
const _maxBytes = 4 * 1024 * 1024;
final _bookId = RegExp(r'^epub:[a-f0-9]{64}$');
final _collectionId = RegExp(r'^c_[a-f0-9]{32}$');

enum EpubLibrarySort { imported, title, author, recent }

class EpubOrganizationException implements Exception {
  const EpubOrganizationException(this.message);
  final String message;
  @override
  String toString() => message;
}

@immutable
class EpubCollection {
  const EpubCollection({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });
  final String id, name;
  final int createdAt, updatedAt;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

/// Organization never changes an EPUB archive, manifest, ID or reading anchor.
/// Two alternating, checksummed snapshots retain the previous committed state;
/// a temporary write is never considered committed during startup recovery.
class LocalEpubOrganizationStore extends ChangeNotifier {
  LocalEpubOrganizationStore({
    DateTime Function()? now,
    Future<void> Function(File file, String contents)? writeFile,
  }) : _now = now ?? DateTime.now,
       _writeFile = writeFile ?? _write;

  final DateTime Function() _now;
  final Future<void> Function(File, String) _writeFile;
  _Data _data = _Data.empty();
  Future<void> _tail = Future<void>.value();
  String? _directory, _root;
  int _generation = 0;
  int? _slot;
  bool _disposed = false;
  String? loadError, warning;

  bool get isReady => _directory != null && loadError == null;
  List<EpubCollection> get collections => _data.collections;
  EpubLibrarySort get sort => _data.sort;
  String get selectedCollection => _data.selected;
  int lastOpened(String bookId) => _data.opened[bookId] ?? 0;

  /// Completes after all already-enqueued writes (e.g. before a backup/teardown).
  Future<void> flush() => _tail;
  bool hasCollection(String id) => collections.any((c) => c.id == id);
  bool contains(String id, String bookId) =>
      _data.members[id]?.contains(bookId) ?? false;
  bool isUnfiled(String bookId) =>
      !_data.members.values.any((ids) => ids.contains(bookId));
  bool matches(String id, String bookId) =>
      id == allEpubs ||
      (id == unfiledEpubs ? isUnfiled(bookId) : contains(id, bookId));

  Future<void> initialize(String root) => _serial(() async {
    if (_root != root) {
      _data = _Data.empty();
      _directory = null;
      _generation = 0;
      _slot = null;
    }
    _root = root;
    try {
      final parent = Directory(root).absolute;
      await parent.create(recursive: true);
      final canonical = await parent.resolveSymbolicLinks();
      final path = '$canonical${Platform.pathSeparator}local_epub_organization';
      await _checkPath(path, directory: true);
      // Legacy readers need no new directory until the first organization write.
      if (await Directory(path).exists() &&
          await Directory(path).resolveSymbolicLinks() != path) {
        throw const FormatException('linked organization directory');
      }
      final snapshots = <(int, int, _Data)>[];
      var damaged = false;
      var futureSchema = false;
      for (var slot = 0; slot < 2; slot++) {
        final file = File(
          '$path${Platform.pathSeparator}organization-$slot.json',
        );
        try {
          await _checkPath(file.path);
          if (!await file.exists()) continue;
          if (await file.length() > _maxBytes) {
            throw const FormatException('size');
          }
          final envelope = jsonDecode(await file.readAsString());
          if (envelope is! Map) throw const FormatException('envelope');
          if (envelope['schema'] != 1) {
            futureSchema = true;
            continue;
          }
          final generation = envelope['generation'];
          final payload = envelope['payload'];
          if (generation is! int ||
              generation < 1 ||
              payload is! String ||
              envelope['sha256'] != _checksum(generation, payload)) {
            throw const FormatException('checksum');
          }
          snapshots.add((generation, slot, _Data.decode(payload)));
        } catch (_) {
          damaged = true;
        }
      }
      if (futureSchema) {
        throw const EpubOrganizationException('分类记录来自较新版本，请更新应用后再试。书籍文件不受影响。');
      }
      if (snapshots.isEmpty && damaged) {
        throw const EpubOrganizationException('分类记录无法读取，未覆盖原记录。书籍仍可在「全部」中打开。');
      }
      snapshots.sort((a, b) => b.$1.compareTo(a.$1));
      final snapshot = snapshots.firstOrNull;
      _directory = path;
      _generation = snapshot?.$1 ?? 0;
      _slot = snapshot?.$2;
      _data = snapshot?.$3 ?? _Data.empty();
      loadError = null;
      warning = damaged ? '部分分类记录损坏，已恢复上一次有效保存。请检查最近的整理结果。' : null;
    } catch (error) {
      loadError =
          error is EpubOrganizationException
              ? error.message
              : '分类记录暂不可用，请检查存储空间后重试。书籍文件不受影响。';
    }
    _notify();
  });

  Future<void> retryInitialization() async {
    final root = _root;
    if (root != null) await initialize(root);
  }

  Future<EpubCollection> createCollection(String name) => _serial(() async {
    final label = _name(name);
    if (collections.length >= 256) {
      throw const EpubOrganizationException('最多创建 256 个分类。');
    }
    _uniqueName(label);
    final random = Random.secure();
    final id =
        'c_${List.generate(4, (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')).join()}';
    final now = _now().millisecondsSinceEpoch;
    final collection = EpubCollection(
      id: id,
      name: label,
      createdAt: now,
      updatedAt: now,
    );
    await _commit(_data.copy(collections: [...collections, collection]));
    return collection;
  });

  Future<void> renameCollection(String id, String name) => _serial(() async {
    _requireCollection(id);
    final label = _name(name);
    _uniqueName(label, except: id);
    await _commit(
      _data.copy(
        collections: [
          for (final c in collections)
            if (c.id == id)
              EpubCollection(
                id: id,
                name: label,
                createdAt: c.createdAt,
                updatedAt: _now().millisecondsSinceEpoch,
              )
            else
              c,
        ],
      ),
    );
  });

  Future<void> moveCollection(String id, int delta) => _serial(() async {
    _requireCollection(id);
    final list = [...collections];
    final old = list.indexWhere((c) => c.id == id);
    final next = (old + delta).clamp(0, list.length - 1);
    if (old == next) return;
    list.insert(next, list.removeAt(old));
    await _commit(_data.copy(collections: list));
  });

  /// Removes only metadata; every member remains in the local book library.
  Future<void> removeCollection(String id) => _serial(() async {
    _requireCollection(id);
    await _commit(
      _data.copy(
        collections: collections.where((c) => c.id != id).toList(),
        members: {..._data.members}..remove(id),
        selected: _data.selected == id ? allEpubs : _data.selected,
      ),
    );
  });

  Future<void> addBooks(String id, Iterable<String> books) {
    final ids = _checkedIds(books);
    return _serial(() async {
      _requireCollection(id);
      if (ids.every((book) => contains(id, book))) return;
      await _commit(
        _data.copy(
          members: {
            ..._data.members,
            id: {...?_data.members[id], ...ids},
          },
        ),
      );
    });
  }

  Future<void> removeBooks(String id, Iterable<String> books) {
    final ids = _checkedIds(books);
    return _serial(() async {
      _requireCollection(id);
      await _commit(
        _data.copy(
          members: {
            ..._data.members,
            id: {...?_data.members[id]}..removeAll(ids),
          },
        ),
      );
    });
  }

  Future<void> forgetBook(String bookId) {
    _checkedIds([bookId]);
    return _serial(() async {
      if (isUnfiled(bookId) && !_data.opened.containsKey(bookId)) return;
      await _commit(
        _data.copy(
          members: {
            for (final e in _data.members.entries)
              e.key: {...e.value}..remove(bookId),
          },
          opened: {..._data.opened}..remove(bookId),
        ),
      );
    });
  }

  Future<void> recordOpened(String bookId) {
    _checkedIds([bookId]);
    return _serial(
      () => _commit(
        _data.copy(
          opened: {..._data.opened, bookId: _now().millisecondsSinceEpoch},
        ),
      ),
    );
  }

  Future<void> selectCollection(String id) => _serial(() async {
    if (id != allEpubs && id != unfiledEpubs) _requireCollection(id);
    if (_data.selected != id) await _commit(_data.copy(selected: id));
  });
  Future<void> setSort(EpubLibrarySort value) => _serial(() async {
    if (_data.sort != value) await _commit(_data.copy(sort: value));
  });

  void _requireCollection(String id) {
    if (!hasCollection(id)) {
      throw const EpubOrganizationException('此分类已被移除，请重新选择。');
    }
  }

  void _uniqueName(String name, {String? except}) {
    if (name == '全部' || name == '未分类') {
      throw const EpubOrganizationException('请使用与「全部」「未分类」不同的分类名称。');
    }
    if (collections.any(
      (c) => c.id != except && c.name.toLowerCase() == name.toLowerCase(),
    )) {
      throw const EpubOrganizationException('已有同名分类，请使用其他名称。');
    }
  }

  static String _name(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.runes.length > 80 ||
        RegExp(r'[\x00-\x1f]').hasMatch(trimmed)) {
      throw const EpubOrganizationException('分类名称须为 1–80 个字符。');
    }
    return trimmed;
  }

  static Set<String> _checkedIds(Iterable<String> ids) {
    final values = ids.toSet();
    if (values.any((id) => !_bookId.hasMatch(id))) {
      throw const EpubOrganizationException('只能整理本地 EPUB 书籍。');
    }
    return values;
  }

  Future<void> _commit(_Data next) async {
    if (!isReady) throw EpubOrganizationException(loadError ?? '分类尚未准备好，请重试。');
    final payload = next.encode();
    final text = jsonEncode({
      'schema': 1,
      'generation': _generation + 1,
      'payload': payload,
      'sha256': _checksum(_generation + 1, payload),
    });
    if (utf8.encode(text).length > _maxBytes) {
      throw const EpubOrganizationException('分类记录过大，本次整理未保存。');
    }
    final targetSlot = _slot == 0 ? 1 : 0;
    final target =
        '$_directory${Platform.pathSeparator}organization-$targetSlot.json';
    final pending = File('$target.pending');
    try {
      await _checkPath(_directory!, directory: true);
      final parent = Directory(_directory!).parent;
      if (await parent.resolveSymbolicLinks() != parent.path) {
        throw const FormatException('linked parent');
      }
      await Directory(_directory!).create();
      if (await Directory(_directory!).resolveSymbolicLinks() != _directory) {
        throw const FormatException('linked directory');
      }
      await _checkPath(target);
      await _checkPath(pending.path);
      await _writeFile(pending, text);
      await pending.rename(target);
    } catch (_) {
      throw const EpubOrganizationException('分类未能保存，请检查存储空间后重试。原有整理结果已保留。');
    }
    _data = next;
    _generation++;
    _slot = targetSlot;
    warning = null;
    _notify();
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) {
      if (_disposed) throw StateError('Organization store disposed');
      return operation();
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

Future<void> _write(File file, String contents) async {
  await file.writeAsString(contents, flush: true);
}

String _checksum(int generation, String payload) =>
    sha256.convert(utf8.encode('$generation:$payload')).toString();

Future<void> _checkPath(String path, {bool directory = false}) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type !=
          (directory
              ? FileSystemEntityType.directory
              : FileSystemEntityType.file)) {
    throw const FormatException('unexpected organization path type');
  }
}

class _Data {
  _Data({
    required List<EpubCollection> collections,
    required Map<String, Set<String>> members,
    required Map<String, int> opened,
    required this.selected,
    required this.sort,
  }) : collections = List.unmodifiable(collections),
       members = Map.unmodifiable(
         members.map((k, v) => MapEntry(k, Set<String>.unmodifiable(v))),
       ),
       opened = Map.unmodifiable(opened);
  factory _Data.empty() => _Data(
    collections: [],
    members: {},
    opened: {},
    selected: allEpubs,
    sort: EpubLibrarySort.imported,
  );
  final List<EpubCollection> collections;
  final Map<String, Set<String>> members;
  final Map<String, int> opened;
  final String selected;
  final EpubLibrarySort sort;
  _Data copy({
    List<EpubCollection>? collections,
    Map<String, Set<String>>? members,
    Map<String, int>? opened,
    String? selected,
    EpubLibrarySort? sort,
  }) => _Data(
    collections: collections ?? this.collections,
    members: members ?? this.members,
    opened: opened ?? this.opened,
    selected: selected ?? this.selected,
    sort: sort ?? this.sort,
  );
  String encode() => jsonEncode({
    'collections': collections.map((c) => c.toJson()).toList(),
    'members': members.map((k, v) => MapEntry(k, v.toList()..sort())),
    'opened': opened,
    'selected': selected,
    'sort': sort.name,
  });
  factory _Data.decode(String payload) {
    final raw = jsonDecode(payload);
    if (raw is! Map ||
        raw['collections'] is! List ||
        raw['members'] is! Map ||
        raw['opened'] is! Map ||
        raw['selected'] is! String) {
      throw const FormatException('organization data');
    }
    final collections = <EpubCollection>[];
    final ids = <String>{}, names = <String>{};
    for (final c in raw['collections'] as List) {
      if (c is! Map ||
          c['id'] is! String ||
          !_collectionId.hasMatch(c['id'] as String) ||
          c['name'] is! String ||
          c['createdAt'] is! int ||
          c['updatedAt'] is! int ||
          !ids.add(c['id'] as String) ||
          !names.add((c['name'] as String).toLowerCase())) {
        throw const FormatException('collection');
      }
      final name = LocalEpubOrganizationStore._name(c['name'] as String);
      collections.add(
        EpubCollection(
          id: c['id'] as String,
          name: name,
          createdAt: c['createdAt'] as int,
          updatedAt: c['updatedAt'] as int,
        ),
      );
    }
    if (collections.length > 256) {
      throw const FormatException('collection count');
    }
    final members = <String, Set<String>>{};
    var count = 0;
    for (final entry in (raw['members'] as Map).entries) {
      if (!ids.contains(entry.key) || entry.value is! List) {
        throw const FormatException('members');
      }
      final list = entry.value as List;
      count += list.length;
      if (count > 100000 ||
          list.any((id) => id is! String || !_bookId.hasMatch(id))) {
        throw const FormatException('member ID');
      }
      members[entry.key as String] = list.cast<String>().toSet();
    }
    final opened = <String, int>{};
    for (final entry in (raw['opened'] as Map).entries) {
      if (entry.key is! String ||
          !_bookId.hasMatch(entry.key as String) ||
          entry.value is! int ||
          (entry.value as int) < 0) {
        throw const FormatException('opened');
      }
      opened[entry.key as String] = entry.value as int;
    }
    final selected = raw['selected'] as String;
    if (selected != allEpubs &&
        selected != unfiledEpubs &&
        !ids.contains(selected)) {
      throw const FormatException('selected');
    }
    final sort =
        EpubLibrarySort.values.where((s) => s.name == raw['sort']).firstOrNull;
    if (sort == null) throw const FormatException('sort');
    return _Data(
      collections: collections,
      members: members,
      opened: opened,
      selected: selected,
      sort: sort,
    );
  }
}
