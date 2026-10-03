import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const maxImportedFontBytes = 64 * 1024 * 1024;

class FontImportException implements Exception {
  const FontImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

@immutable
class ImportedFont {
  const ImportedFont({
    required this.name,
    required this.digest,
    required this.extension,
  });
  final String name;
  final String digest;
  final String extension;
  String get family => 'LiteTaleUser$digest';
  String get fileName => '$digest.$extension';
  Map<String, String> toJson() => {
    'name': name,
    'digest': digest,
    'extension': extension,
  };

  static ImportedFont? fromJson(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        value['name'] is! String ||
        value['digest'] is! String ||
        value['extension'] is! String) {
      throw const FormatException('字体设置已损坏');
    }
    final font = ImportedFont(
      name: value['name'],
      digest: value['digest'],
      extension: value['extension'],
    );
    // Persist only content-addressed names, never an external path or content URI.
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(font.digest) ||
        !['ttf', 'otf'].contains(font.extension) ||
        font.name.isEmpty) {
      throw const FormatException('字体设置已损坏');
    }
    return font;
  }
}

Future<XFile?> pickFontFile() => openFile(
  acceptedTypeGroups: const [
    XTypeGroup(
      label: '字体文件',
      extensions: ['ttf', 'otf'],
      // Providers can label a downloaded font as generic binary data.
      mimeTypes: [
        'font/ttf',
        'font/otf',
        'application/x-font-ttf',
        'application/x-font-opentype',
        'application/octet-stream',
      ],
      uniformTypeIdentifiers: ['public.font'],
    ),
  ],
);

/// Reject renamed non-fonts and truncated SFNT files before passing them to the
/// engine. Hashing and validation run off the UI isolate for large CJK fonts.
String inspectFontBytes(Uint8List bytes) {
  if (bytes.length > maxImportedFontBytes) {
    throw const FontImportException('字体文件不能超过 64 MB');
  }
  const invalid = FontImportException('字体文件已损坏或格式不支持，请选择有效的 TTF 或 OTF 字体');
  if (bytes.length < 12) throw invalid;
  final data = ByteData.sublistView(bytes);
  final signature = data.getUint32(0);
  if (signature != 0x00010000 && signature != 0x4f54544f) throw invalid;
  final count = data.getUint16(4);
  final directoryEnd = 12 + count * 16;
  if (count == 0 || count > 256 || directoryEnd > bytes.length) throw invalid;
  final tables = <String, ({int offset, int length})>{};
  for (var i = 0; i < count; i++) {
    final entry = 12 + i * 16;
    final tag = String.fromCharCodes(bytes.sublist(entry, entry + 4));
    final offset = data.getUint32(entry + 8);
    final length = data.getUint32(entry + 12);
    if (tables.containsKey(tag) ||
        offset < directoryEnd ||
        offset + length > bytes.length) {
      throw invalid;
    }
    tables[tag] = (offset: offset, length: length);
  }
  for (final tag in ['cmap', 'head', 'hhea', 'hmtx', 'maxp', 'name']) {
    if (tables[tag] == null || tables[tag]!.length == 0) throw invalid;
  }
  final head = tables['head']!;
  final maxp = tables['maxp']!;
  if (head.length < 54 ||
      maxp.length < 6 ||
      tables['hhea']!.length < 36 ||
      tables['cmap']!.length < 4 ||
      tables['name']!.length < 6 ||
      data.getUint32(head.offset + 12) != 0x5f0f3cf5 ||
      data.getUint16(maxp.offset + 4) == 0) {
    throw invalid;
  }
  final glyphs = data.getUint16(maxp.offset + 4);
  final metrics = data.getUint16(tables['hhea']!.offset + 34);
  if (metrics < 1 ||
      metrics > glyphs ||
      tables['hmtx']!.length < metrics * 4 + (glyphs - metrics) * 2) {
    throw invalid;
  }
  if (signature == 0x00010000) {
    if (tables['glyf'] == null || tables['loca'] == null) throw invalid;
    final format = data.getInt16(head.offset + 50);
    if ((format != 0 && format != 1) ||
        tables['loca']!.length < (glyphs + 1) * (format == 0 ? 2 : 4)) {
      throw invalid;
    }
  } else if (tables['CFF '] == null && tables['CFF2'] == null) {
    throw invalid;
  }
  return sha256.convert(bytes).toString();
}

Future<void> registerImportedFont(String family, Uint8List bytes) async {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

class ImportedFontStore {
  ImportedFontStore({Future<void> Function(String, Uint8List)? register})
    : _register = register ?? registerImportedFont;
  final Future<void> Function(String, Uint8List) _register;
  final _registered = <String>{};
  Directory? _directory;

  void initialize(String root) =>
      _directory = Directory('$root/imported_fonts');

  File _file(ImportedFont font) {
    if (_directory == null) throw const FontImportException('字体设置尚未初始化，请稍后重试');
    return File('${_directory!.path}/${font.fileName}');
  }

  Future<ImportedFont> importFile(XFile input) async {
    final name = input.name;
    if (await input.length() > maxImportedFontBytes) {
      throw const FontImportException('字体文件不能超过 64 MB');
    }
    final bytes = await input.readAsBytes();
    final digest = await compute(inspectFontBytes, bytes);
    // SAF providers can replace the extension based on an incorrect MIME type.
    // The validated SFNT header is authoritative, rather than the cache name.
    final extension =
        ByteData.sublistView(bytes).getUint32(0) == 0x4f54544f ? 'otf' : 'ttf';
    final font = ImportedFont(name: name, digest: digest, extension: extension);
    final file = _file(font);
    await _directory!.create(recursive: true);
    // Only our immutable, app-private copy is used after the picker returns.
    await file.writeAsBytes(bytes, flush: true);
    await _load(font, bytes);
    return font;
  }

  Future<void> restore(ImportedFont font) async {
    final file = _file(font);
    if (!await file.exists() || await file.length() > maxImportedFontBytes) {
      throw const FontImportException('已导入的字体文件不可用，请重新导入');
    }
    final bytes = await file.readAsBytes();
    if (await compute(inspectFontBytes, bytes) != font.digest) {
      throw const FontImportException('已导入的字体文件已损坏，请重新导入');
    }
    await _load(font, bytes);
  }

  Future<void> _load(ImportedFont font, Uint8List bytes) async {
    if (_registered.contains(font.family)) return;
    await _register(font.family, bytes);
    _registered.add(font.family);
  }
}
