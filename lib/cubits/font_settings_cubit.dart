import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/imported_fonts.dart';
import 'package:wild/src/rust/api/database.dart';
import 'package:wild/theme/app_fonts.dart';

enum FontScope { app, reader }

@immutable
class FontSettingsState {
  const FontSettingsState({
    this.app,
    this.reader,
    this.busy,
    this.restoreWarning,
  });
  final ImportedFont? app;
  final ImportedFont? reader;
  final FontScope? busy;
  final String? restoreWarning;
  String? get appFamily => app?.family;
  String get readerFamily => reader?.family ?? appFontFamily;
  ImportedFont? fontFor(FontScope scope) =>
      scope == FontScope.app ? app : reader;
  // A chapter's obfuscation font is required to decode its glyphs correctly.
  String resolveReaderFamily(String? chapterFamily) =>
      chapterFamily ?? readerFamily;

  String toJson() => jsonEncode({
    'version': 1,
    'app': app?.toJson(),
    'reader': reader?.toJson(),
  });

  FontSettingsState withFont(FontScope scope, ImportedFont? font) =>
      FontSettingsState(
        app: scope == FontScope.app ? font : app,
        reader: scope == FontScope.reader ? font : reader,
      );
  FontSettingsState withBusy(FontScope? value) => FontSettingsState(
    app: app,
    reader: reader,
    busy: value,
    restoreWarning: restoreWarning,
  );
}

class FontSettingsCubit extends Cubit<FontSettingsState> {
  FontSettingsCubit({
    ImportedFontStore? store,
    Future<XFile?> Function()? pick,
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _store = store ?? ImportedFontStore(),
       _pick = pick ?? pickFontFile,
       _read = read ?? (() => loadProperty(key: propertyKey)),
       _write =
           write ?? ((value) => saveProperty(key: propertyKey, value: value)),
       super(const FontSettingsState());

  static const propertyKey = 'litetale.font_settings_v1';
  final ImportedFontStore _store;
  final Future<XFile?> Function() _pick;
  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  int _revision = 0;

  Future<void> initialize(String root) async {
    _store.initialize(root);
    final revision = _revision;
    ImportedFont? app;
    ImportedFont? reader;
    String? warning;
    try {
      final raw = await _read();
      if (raw.isNotEmpty) {
        final saved = jsonDecode(raw) as Map;
        if (saved['version'] != 1) throw const FormatException('字体设置版本不支持');
        // One damaged font must not disable the other selection or app startup.
        for (final scope in FontScope.values) {
          try {
            final font = ImportedFont.fromJson(saved[scope.name]);
            if (font != null) await _store.restore(font);
            if (scope == FontScope.app) {
              app = font;
            } else {
              reader = font;
            }
          } catch (_) {
            warning = '部分字体不可用，已恢复默认；你可以重新导入。';
          }
        }
      }
    } catch (_) {
      warning = '字体设置读取失败，已使用默认字体；你可以重新导入。';
    }
    if (!isClosed && revision == _revision) {
      emit(
        FontSettingsState(app: app, reader: reader, restoreWarning: warning),
      );
    }
  }

  Future<bool> importFont(FontScope scope) async {
    if (state.busy != null) return false;
    _revision++;
    emit(state.withBusy(scope));
    try {
      final input = await _pick();
      if (input == null || isClosed) return false;
      final font = await _store.importFile(input);
      if (isClosed) return false;
      final next = state.withFont(scope, font);
      await _write(next.toJson());
      if (!isClosed) emit(next);
      return true;
    } on FontImportException {
      rethrow;
    } catch (_) {
      throw const FontImportException('字体导入或保存失败，请重新选择文件后重试');
    } finally {
      if (!isClosed) emit(state.withBusy(null));
    }
  }

  Future<bool> reset(FontScope scope) async {
    if (state.busy != null) return false;
    _revision++;
    emit(state.withBusy(scope));
    try {
      final next = state.withFont(scope, null);
      await _write(next.toJson());
      if (!isClosed) emit(next);
      return true;
    } catch (_) {
      throw const FontImportException('字体设置保存失败，请重试');
    } finally {
      if (!isClosed) emit(state.withBusy(null));
    }
  }
}
