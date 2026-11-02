import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'epub_models.dart';
import 'local_epub_organization.dart';

enum EpubImportStatus {
  queued,
  importing,
  imported,
  duplicate,
  failed,
  cancelled,
}

@immutable
class EpubImportItem {
  const EpubImportItem({
    required this.file,
    this.status = EpubImportStatus.queued,
    this.result,
    this.error,
    this.classificationError,
    this.warning,
  });
  final XFile file;
  final EpubImportStatus status;
  final EpubImportResult? result;
  final String? error, classificationError;
  final String? warning;
  String get name => file.name.isEmpty ? 'EPUB 文件' : file.name;
}

/// Owns a batch independently of the route. Holds file references, not a batch
/// of EPUB bytes, and feeds the existing atomic single-book importer one by one.
class EpubImportQueue extends ChangeNotifier {
  EpubImportQueue({
    required Future<EpubImportResult> Function(XFile) importFile,
    required this.organization,
  }) : _importFile = importFile;
  final Future<EpubImportResult> Function(XFile) _importFile;
  final LocalEpubOrganizationStore organization;
  List<EpubImportItem> _items = [];
  bool _running = false, _disposed = false;
  int _generation = 0;
  String? _collection;
  void Function(EpubImportResult)? _afterImport;

  List<EpubImportItem> get items => List.unmodifiable(_items);
  bool get isRunning => _running;
  int get generation => _generation;
  bool get hasResults => _items.isNotEmpty;
  String? get targetCollection => _collection;
  int count(EpubImportStatus status) =>
      _items.where((i) => i.status == status).length;
  int get completed =>
      _items
          .where(
            (i) =>
                i.status != EpubImportStatus.queued &&
                i.status != EpubImportStatus.importing,
          )
          .length;
  int get classificationFailures =>
      _items.where((i) => i.classificationError != null).length;

  Future<void> start(
    List<XFile> files, {
    String? collectionId,
    void Function(EpubImportResult)? afterImport,
  }) {
    _requireIdle();
    if (files.isEmpty) return Future<void>.value();
    _generation++;
    _collection = collectionId;
    _afterImport = afterImport;
    _items = [for (final file in files) EpubImportItem(file: file)];
    return _run();
  }

  void stop() {
    if (!_running) return;
    _items = [
      for (final item in _items)
        if (item.status == EpubImportStatus.queued)
          EpubImportItem(file: item.file, status: EpubImportStatus.cancelled)
        else
          item,
    ];
    _notify();
  }

  Future<void> retryFailed() => _retry(EpubImportStatus.failed);
  Future<void> resumeCancelled() => _retry(EpubImportStatus.cancelled);
  Future<void> _retry(EpubImportStatus status) {
    _requireIdle();
    if (count(status) == 0) return Future<void>.value();
    _generation++;
    _items = [
      for (final item in _items)
        if (item.status == status) EpubImportItem(file: item.file) else item,
    ];
    return _run();
  }

  Future<void> _run() async {
    _running = true;
    _notify();
    try {
      for (var index = 0; index < _items.length; index++) {
        if (_disposed) break;
        final item = _items[index];
        if (item.status != EpubImportStatus.queued) continue;
        _items[index] = EpubImportItem(
          file: item.file,
          status: EpubImportStatus.importing,
        );
        _notify();
        try {
          final result = await _importFile(item.file);
          // Presentation invalidation is supplied by the app, without retaining
          // a page or its BuildContext. It must run even after that page leaves.
          String? warning;
          try {
            _afterImport?.call(result);
          } catch (_) {
            // The archive has already committed; a presentation error must not
            // misreport it as a failed import or cause a second import.
            warning = '书籍已入库，请重新打开以更新阅读样式。';
          }
          String? classificationError;
          if (_collection != null) {
            try {
              await organization.addBooks(_collection!, [result.book.id]);
            } catch (_) {
              classificationError = '书籍已入库，但分类未保存，可重试分类。';
            }
          }
          _items[index] = EpubImportItem(
            file: item.file,
            result: result,
            status:
                result.alreadyImported
                    ? EpubImportStatus.duplicate
                    : EpubImportStatus.imported,
            classificationError: classificationError,
            warning: warning,
          );
        } catch (error) {
          _items[index] = EpubImportItem(
            file: item.file,
            status: EpubImportStatus.failed,
            error:
                error is EpubImportException
                    ? error.message
                    : '无法导入此文件，请检查文件或重新选择。',
          );
        }
        _notify();
        // Yield between books so stop/navigation can run, even for fast duplicates.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _running = false;
      _notify();
    }
  }

  Future<void> retryClassification() async {
    _requireIdle();
    if (_collection == null || classificationFailures == 0) return;
    _running = true;
    _notify();
    try {
      for (var index = 0; index < _items.length; index++) {
        if (_disposed) break;
        final item = _items[index];
        if (item.classificationError == null || item.result == null) continue;
        try {
          await organization.addBooks(_collection!, [item.result!.book.id]);
          _items[index] = EpubImportItem(
            file: item.file,
            status: item.status,
            result: item.result,
            warning: item.warning,
          );
          _notify();
        } catch (_) {
          // Keep the successful book and allow another retry. Never reparse it.
        }
      }
    } finally {
      _running = false;
      _notify();
    }
  }

  void dismiss() {
    _requireIdle();
    _items = [];
    _afterImport = null;
    _collection = null;
    _notify();
  }

  void _requireIdle() {
    if (_disposed) throw StateError('Import queue disposed');
    if (_running) throw StateError('A batch import is already running');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
