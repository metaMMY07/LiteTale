import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/database.dart';

const bookshelfOrganizationKey = 'litetale.bookshelf_organization.v1';

class BookshelfFolder {
  BookshelfFolder({
    required this.id,
    required this.title,
    required this.sourceName,
    Iterable<String> books = const [],
  }) : books = List.unmodifiable(books);

  final String id, title;
  final String? sourceName;
  final List<String> books;

  bool accepts(String bookId) =>
      sourceName == null || sourceOf(bookId).name == sourceName;

  bool visibleFor(SourceId? source) =>
      source == null || sourceName == null || sourceName == source.name;

  BookshelfFolder withBooks(Iterable<String> ids) =>
      BookshelfFolder(id: id, title: title, sourceName: sourceName, books: ids);
}

/// Stores folder membership and display order by the existing source-prefixed
/// book ID. Shelf contents and authorization still come from the source.
class BookshelfOrganization extends ChangeNotifier {
  BookshelfOrganization({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => loadProperty(key: bookshelfOrganizationKey)),
       _write =
           write ??
           ((value) =>
               saveProperty(key: bookshelfOrganizationKey, value: value));

  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  Map<String, BookshelfFolder> _folders = const {};
  List<String> _rootOrder = const [];
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  bool _ready = false, _loadFailed = false, _disposed = false;

  bool get isReady => _ready;
  bool get loadFailed => _loadFailed;
  Iterable<BookshelfFolder> get folders => _folders.values;
  BookshelfFolder? folder(String id) => _folders[id];

  Future<void> load() {
    if (_ready || _disposed) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final raw = await _read();
      if (_disposed) return;
      if (raw.isNotEmpty) _restore(raw);
      _ready = true;
      _loadFailed = false;
    } catch (_) {
      _loadFailed = true;
    }
    if (!_disposed) notifyListeners();
  }

  void _restore(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['version'] != 1) throw const FormatException('bookshelf version');
    final folders = <String, BookshelfFolder>{};
    final filed = <String>{};
    for (final row in data['folders'] as List) {
      final id = row['id'] as String;
      if (!id.startsWith('folder:') || folders.containsKey(id)) {
        throw const FormatException('bookshelf folder identity');
      }
      final folder = BookshelfFolder(
        id: id,
        title: _name(row['title'] as String),
        sourceName: row['source'] as String?,
        books: (row['books'] as List).cast<String>(),
      );
      for (final book in folder.books) {
        if (!filed.add(book) || !folder.accepts(book)) {
          throw const FormatException('bookshelf folder membership');
        }
      }
      folders[id] = folder;
    }
    final order = (data['order'] as List).cast<String>().toSet();
    _folders = Map.unmodifiable(folders);
    _rootOrder = List.unmodifiable(order);
  }

  List<String> rootKeys(Iterable<String> bookIds, {SourceId? source}) {
    final filed = {for (final folder in folders) ...folder.books};
    final visible = {
      for (final folder in folders)
        if (folder.visibleFor(source)) folder.id,
      for (final id in bookIds)
        if (!filed.contains(id)) id,
    };
    return [
      for (final id in _rootOrder)
        if (visible.remove(id)) id,
      ...visible,
    ];
  }

  Future<void> createFolder(String title, {SourceId? source}) =>
      _edit((folders, order) {
        var next = DateTime.now().microsecondsSinceEpoch;
        while (folders.containsKey('folder:$next')) {
          next++;
        }
        final id = 'folder:$next';
        folders[id] = BookshelfFolder(
          id: id,
          title: _name(title),
          sourceName: source?.name,
        );
        order.insert(0, id);
      });

  Future<void> renameFolder(String id, String title) => _edit((folders, _) {
    final current = folders[id];
    if (current == null) return;
    folders[id] = BookshelfFolder(
      id: id,
      title: _name(title),
      sourceName: current.sourceName,
      books: current.books,
    );
  });

  Future<void> moveBooks(Set<String> ids, {required String? folderId}) =>
      _edit((folders, order) {
        final destination = folders[folderId];
        if (folderId != null &&
            (destination == null || !ids.every(destination.accepts))) {
          throw StateError('请选择适用于所选书籍的文件夹');
        }
        for (final entry in folders.entries.toList()) {
          final folder = entry.value;
          folders[entry.key] = folder.withBooks([
            ...folder.books.where((id) => !ids.contains(id)),
            if (entry.key == folderId) ...ids,
          ]);
        }
        order.removeWhere(ids.contains);
      });

  Future<void> removeItems({
    Set<String> books = const {},
    Set<String> folderIds = const {},
  }) => _edit((folders, order) {
    for (final id in folderIds) {
      folders.remove(id);
    }
    for (final entry in folders.entries.toList()) {
      folders[entry.key] = entry.value.withBooks(
        entry.value.books.where((id) => !books.contains(id)),
      );
    }
    order.removeWhere((id) => books.contains(id) || folderIds.contains(id));
  });

  /// Replaces only visible slots. A source filter never reorders its hidden
  /// siblings and a folder keeps members from other sources in their slots.
  Future<void> reorder(
    List<String> visibleOrder, {
    required String? folderId,
    required Iterable<String> allRootKeys,
  }) => _edit((folders, order) {
    final folder = folders[folderId];
    if (folderId != null && folder == null) return;
    final current = folder?.books ?? {...order, ...allRootKeys}.toList();
    final known = current.toSet();
    final moving = visibleOrder.where(known.contains).toSet();
    final replacements = moving.iterator;
    final next = [
      for (final key in current)
        if (moving.contains(key) && replacements.moveNext())
          replacements.current
        else
          key,
    ];
    if (folder == null) {
      order
        ..clear()
        ..addAll(next);
    } else {
      folders[folder.id] = folder.withBooks(next);
    }
  });

  Future<void> _edit(
    void Function(Map<String, BookshelfFolder>, List<String>) change,
  ) {
    final pending = _writes.then((_) async {
      await load();
      if (_disposed || !_ready) throw StateError('书架整理暂时无法保存');
      final folders = Map<String, BookshelfFolder>.of(_folders);
      final order = List<String>.of(_rootOrder);
      change(folders, order);
      await _write(
        jsonEncode({
          'version': 1,
          'order': order,
          'folders': [
            for (final folder in folders.values)
              {
                'id': folder.id,
                'title': folder.title,
                'source': folder.sourceName,
                'books': folder.books,
              },
          ],
        }),
      );
      _folders = Map.unmodifiable(folders);
      _rootOrder = List.unmodifiable(order);
      if (!_disposed) notifyListeners();
    });
    _writes = pending.catchError((Object _) {});
    return pending;
  }

  static String _name(String text) {
    final name = text.trim();
    if (name.isEmpty) throw const FormatException('请输入文件夹名称');
    return name;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
