import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:wild/methods.dart';
import 'package:wild/services/imported_fonts.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/src/rust/api/backup.dart' as native;
import 'package:wild/src/rust/api/system.dart';

const maxSnapshotBytes = 256 * 1024 * 1024;
const snapshotSettingKeys = {
  'font_size',
  'line_height',
  'paragraph_spacing',
  'top_bar_height',
  'bottom_bar_height',
  'left_padding',
  'right_padding',
  'reader_type',
  'reader_theme_mode',
  'reader_light_background_color',
  'reader_light_text_color',
  'reader_dark_background_color',
  'reader_dark_text_color',
  'app_accent_v1',
  'reader_page_curl_v1',
  '_volumeControlProperty',
  '_screenUpOnReadingProperty',
  '_screenUpOnScrollProperty',
  'litetale.settings_v1',
  'litetale.font_settings_v1',
  'reader_background_v1',
};
const snapshotShelfKeys = {
  'litetale.lns.local_shelf',
  'litetale.lns.search_history',
  'litetale.lnovel.local_shelf',
  'litetale.lnovel.search_history',
};

class SnapshotDocument {
  const SnapshotDocument(this.json, this.data, {this.warnings = const []});
  final String json;
  final Map<String, dynamic> data;
  final List<String> warnings;
  bool get hasSettings => data.containsKey('settings');
  bool get hasReading => data.containsKey('reading');
  bool get hasBookshelves => data.containsKey('bookshelves');
  int get historyCount => (data['reading']?['history'] as List?)?.length ?? 0;
  int get eventCount =>
      (data['reading']?['statistics']?['events'] as List?)?.length ?? 0;
  String get createdAt => '${data['createdAt']}';
}

typedef SnapshotRead =
    Future<String> Function(bool bookshelves, bool reading, bool settings);
typedef SnapshotWrite = Future<String> Function(String json, bool overwrite);

class DataSnapshotService {
  DataSnapshotService({
    String? root,
    SnapshotRead? read,
    SnapshotWrite? write,
    Future<String> Function(String)? inspect,
  }) : _root = root,
       _read =
           read ??
           ((b, r, s) => native.exportSnapshot(
             includeBookshelves: b,
             includeReading: r,
             includeSettings: s,
           )),
       _write =
           write ??
           ((data, overwrite) =>
               native.importSnapshot(json: data, overwrite: overwrite)),
       _inspect = inspect ?? ((data) => native.inspectSnapshot(json: data));
  String? _root;
  final SnapshotRead _read;
  final SnapshotWrite _write;
  final Future<String> Function(String) _inspect;

  Future<String> _directory() async =>
      _root ??=
          Platform.isAndroid || Platform.isIOS
              ? await dataRoot()
              : await desktopRoot();

  Future<SnapshotDocument> build({
    bool bookshelves = true,
    bool reading = true,
    bool settings = true,
  }) async {
    if (!bookshelves && !reading && !settings) {
      throw const FormatException('请选择要导出的数据');
    }
    final data =
        jsonDecode(await _read(bookshelves, reading, settings))
            as Map<String, dynamic>;
    final warnings = <String>[];
    if (settings) {
      final root = await _directory();
      final domain = data['settings'] as Map;
      final props = domain['properties'] as Map;
      final files = <String, String>{};
      final fontRaw = props['litetale.font_settings_v1'];
      if (fontRaw is String) {
        final fonts = jsonDecode(fontRaw) as Map;
        for (final scope in ['app', 'reader']) {
          final font = ImportedFont.fromJson(fonts[scope]);
          if (font == null) continue;
          final file = File('$root/imported_fonts/${font.fileName}');
          if (!await file.exists()) {
            fonts[scope] = null;
            warnings.add('缺失的${scope == 'app' ? '界面' : '阅读'}字体未导出');
            continue;
          }
          if (await file.length() > maxImportedFontBytes) {
            throw const FormatException('字体文件过大');
          }
          files[font.fileName] = base64Encode(await file.readAsBytes());
        }
        props['litetale.font_settings_v1'] = jsonEncode(fonts);
      }
      final paperRaw = props['reader_background_v1'];
      final paper =
          paperRaw is String
              ? jsonDecode(paperRaw) as Map
              : <String, dynamic>{
                'version': 1,
                'enabled': true,
                'builtin': false,
                'opacity': 0.1,
              };
      for (final light in [true, false]) {
        final name =
            light
                ? 'light_reader_background.png'
                : 'dark_reader_background.png';
        final field = light ? 'lightFile' : 'darkFile';
        final stored = paper[field] ?? name;
        if (!_safePaperName(stored)) throw const FormatException('纸张文件名无效');
        if (stored == '') continue;
        final file = File('$root/$stored');
        if (await file.exists()) {
          if (await file.length() > 20 * 1024 * 1024) {
            throw const FormatException('纸张图片不能超过20 MB');
          }
          files[name] = base64Encode(await file.readAsBytes());
          paper[field] = name;
        } else {
          paper[field] = '';
        }
      }
      props['reader_background_v1'] = jsonEncode(paper);
      domain['media'] = {'files': files};
    }
    final encoded = await compute(_encodeSnapshot, data);
    final document = await parse(encoded);
    return SnapshotDocument(document.json, document.data, warnings: warnings);
  }

  Future<SnapshotDocument> parse(String raw) async {
    final data = await compute(_validateSnapshot, raw);
    await _checkPaperDecoding(data);
    await _inspect(raw); // Rust independently validates the database payload.
    return SnapshotDocument(raw, data);
  }

  Future<void> restore(
    SnapshotDocument document, {
    bool overwrite = false,
  }) async {
    // Revalidate immutable input before doing any work, even for callers that
    // constructed a document outside the file picker.
    final prepared = await compute(_prepareSnapshotFiles, document.json);
    await _checkPaperDecoding(
      jsonDecode(prepared['json'] as String) as Map<String, dynamic>,
    );
    await _inspect(prepared['json'] as String);
    final root = await _directory();
    for (final item in prepared['files'] as List) {
      final row = item as Map;
      final relative = row['path'] as String;
      final file = File('$root/$relative');
      await file.parent.create(recursive: true);
      // All new files are addressed by their digest. Failed database imports
      // leave an unused copy; they never replace the user's current paper/font.
      await file.writeAsBytes(row['bytes'] as Uint8List, flush: true);
    }
    await _write(prepared['json'] as String, overwrite);
  }
}

String _encodeSnapshot(Map<String, dynamic> data) => jsonEncode(data);
bool _safePaperName(Object? value) =>
    value is String &&
    (value.isEmpty ||
        [
          'light_reader_background.png',
          'dark_reader_background.png',
        ].contains(value) ||
        RegExp(r'^snapshot_[a-f0-9]{64}\.png$').hasMatch(value));

Map<String, dynamic> _validateSnapshot(String raw) {
  if (utf8.encode(raw).length > maxSnapshotBytes) {
    throw const FormatException('快照不能超过256 MB');
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map ||
      decoded['format'] != 'litetale' ||
      decoded['version'] != 1) {
    throw const FormatException(
      '请选择LiteTale的.litetale快照；LightNovelReader的.lnr格式不能直接导入',
    );
  }
  final data = Map<String, dynamic>.from(decoded);
  if (data.keys.any(
    (k) =>
        !{
          'format',
          'version',
          'createdAt',
          'settings',
          'bookshelves',
          'reading',
        }.contains(k),
  )) {
    throw const FormatException('快照字段无效');
  }
  if (DateTime.tryParse('${data['createdAt']}') == null) {
    throw const FormatException('快照时间无效');
  }
  if (!data.keys.any(
    (k) => {'settings', 'bookshelves', 'reading'}.contains(k),
  )) {
    throw const FormatException('快照没有数据');
  }
  final settings = data['settings'];
  if (settings != null) {
    if (settings is! Map || settings['properties'] is! Map) {
      throw const FormatException('快照设置无效');
    }
    final props = settings['properties'] as Map;
    if (props.entries.any(
      (e) => !snapshotSettingKeys.contains(e.key) || e.value is! String,
    )) {
      throw const FormatException('快照包含不支持的设置');
    }
    if (props['litetale.settings_v1'] != null) {
      SettingsPreferences.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(props['litetale.settings_v1']) as Map,
        ),
      );
    }
    final files = settings['media']?['files'] ?? <String, dynamic>{};
    if (files is! Map || files.length > 4) {
      throw const FormatException('快照媒体无效');
    }
    final decodedFiles = <String, Uint8List>{};
    for (final entry in files.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('快照媒体无效');
      }
      final name = entry.key as String;
      final bytes = base64Decode(entry.value);
      if ([
        'light_reader_background.png',
        'dark_reader_background.png',
      ].contains(name)) {
        _validatePaperImage(bytes);
      } else {
        if (!RegExp(r'^[a-f0-9]{64}\.(ttf|otf)$').hasMatch(name) ||
            inspectFontBytes(bytes) != name.split('.').first) {
          throw const FormatException('快照字体内容与摘要不匹配');
        }
      }
      decodedFiles[name] = bytes;
    }
    final fontRaw = props['litetale.font_settings_v1'];
    if (fontRaw != null) {
      final fonts = jsonDecode(fontRaw) as Map;
      if (fonts['version'] != 1) throw const FormatException('字体设置版本无效');
      for (final scope in ['app', 'reader']) {
        final font = ImportedFont.fromJson(fonts[scope]);
        if (font != null && !decodedFiles.containsKey(font.fileName)) {
          throw const FormatException('快照缺少已选择的字体文件');
        }
      }
    }
    final paperRaw = props['reader_background_v1'];
    if (paperRaw != null) {
      final paper = jsonDecode(paperRaw) as Map;
      if (paper['version'] != 1 ||
          paper['enabled'] is! bool ||
          paper['builtin'] is! bool ||
          paper['opacity'] is! num ||
          !(paper['opacity'] as num).toDouble().isFinite ||
          (paper['opacity'] as num) < 0 ||
          (paper['opacity'] as num) > 1) {
        throw const FormatException('纸张设置无效');
      }
      for (final field in ['lightFile', 'darkFile']) {
        final value = paper[field];
        if (value != null && !_safePaperName(value)) {
          throw const FormatException('纸张文件名无效');
        }
        if (value is String && value.isNotEmpty) {
          final name =
              field == 'lightFile'
                  ? 'light_reader_background.png'
                  : 'dark_reader_background.png';
          final bytes = decodedFiles[name];
          if (bytes == null) {
            throw const FormatException('快照缺少已选择的纸张图片');
          }
          if (value != name &&
              value != 'snapshot_${sha256.convert(bytes)}.png') {
            throw const FormatException('纸张摘要不匹配');
          }
        }
        if (value == null) paper[field] = '';
      }
      props['reader_background_v1'] = jsonEncode(paper);
    }
  }
  final reading = data['reading'];
  if (reading != null) {
    if (reading is! Map ||
        reading['history'] is! List ||
        (reading['history'] as List).length > 100000 ||
        reading['statistics'] is! Map) {
      throw const FormatException('阅读数据无效');
    }
    final events = reading['statistics']['events'];
    if (reading['statistics']['version'] != 1 ||
        events is! List ||
        events.length > readingStatisticsMaximumEvents) {
      throw const FormatException('阅读统计无效');
    }
    for (final e in events) {
      ReadingStatisticsEvent.fromJson(e);
    }
  }
  final shelves = data['bookshelves'];
  if (shelves != null) {
    if (shelves is! Map || shelves['properties'] is! Map) {
      throw const FormatException('收藏格式无效');
    }
    for (final e in (shelves['properties'] as Map).entries) {
      if (!snapshotShelfKeys.contains(e.key) ||
          e.value is! String ||
          jsonDecode(e.value) is! List) {
        throw const FormatException('收藏键无效');
      }
    }
  }
  return data;
}

Map<String, dynamic> _prepareSnapshotFiles(String raw) {
  final data = _validateSnapshot(raw);
  final output = <Map<String, dynamic>>[];
  final settings = data['settings'] as Map?;
  if (settings != null) {
    final props = settings['properties'] as Map;
    final files = settings['media']?['files'] as Map? ?? {};
    Map? paper =
        props['reader_background_v1'] is String
            ? jsonDecode(props['reader_background_v1']) as Map
            : null;
    for (final entry in files.entries) {
      final bytes = base64Decode(entry.value as String);
      final name = entry.key as String;
      if (name.endsWith('.ttf') || name.endsWith('.otf')) {
        output.add({'path': 'imported_fonts/$name', 'bytes': bytes});
      } else {
        final filename = 'snapshot_${sha256.convert(bytes)}.png';
        output.add({'path': filename, 'bytes': bytes});
        paper ??= {
          'version': 1,
          'enabled': true,
          'builtin': false,
          'opacity': 0.1,
        };
        paper[name.startsWith('light') ? 'lightFile' : 'darkFile'] = filename;
      }
    }
    if (paper != null) props['reader_background_v1'] = jsonEncode(paper);
  }
  return {'json': jsonEncode(data), 'files': output};
}

void _validatePaperImage(Uint8List bytes) {
  if (bytes.length < 24 || bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('快照纸张图片大小无效');
  }
  int width = 0, height = 0;
  if (bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71) {
    final data = ByteData.sublistView(bytes);
    width = data.getUint32(16);
    height = data.getUint32(20);
  } else if (bytes[0] == 255 && bytes[1] == 216) {
    var index = 2;
    while (index + 8 < bytes.length) {
      if (bytes[index] != 255) break;
      final marker = bytes[index + 1];
      if (marker == 218 || marker == 217) break;
      final length = (bytes[index + 2] << 8) + bytes[index + 3];
      if (length < 2 || index + length + 2 > bytes.length) break;
      if ({
        192,
        193,
        194,
        195,
        197,
        198,
        199,
        201,
        202,
        203,
        205,
        206,
        207,
      }.contains(marker)) {
        height = (bytes[index + 5] << 8) + bytes[index + 6];
        width = (bytes[index + 7] << 8) + bytes[index + 8];
        break;
      }
      index += length + 2;
    }
  }
  if (width <= 0 || height <= 0 || width * height > 24000000) {
    throw const FormatException('纸张图片无效或分辨率过大');
  }
}

Future<void> _checkPaperDecoding(Map<String, dynamic> data) async {
  final files = data['settings']?['media']?['files'] as Map? ?? {};
  for (final e in files.entries) {
    if (![
      'light_reader_background.png',
      'dark_reader_background.png',
    ].contains(e.key)) {
      continue;
    }
    try {
      // Header checks run in the isolate first. Decode the full compressed
      // stream to a thumbnail to catch truncated data without a 24 MP bitmap.
      final codec = await ui.instantiateImageCodec(
        base64Decode(e.value as String),
        targetWidth: 64,
        targetHeight: 64,
      );
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } catch (_) {
      throw const FormatException('快照纸张图片损坏');
    }
  }
}
