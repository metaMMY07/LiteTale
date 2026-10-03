import 'dart:typed_data';

import 'package:flutter/services.dart';

// Generated from Python's standard GBK codec, not from any website response.
// Wenku8's search/tag parameters use GBK even inside a Chromium WebView.
Future<Map<int, int>>? _table;

Future<String> wenku8EncodeQuery(String value) async {
  _table ??= _loadTable();
  final table = await _table!;
  final out = StringBuffer();
  for (final rune in value.runes) {
    if (rune <= 0x7f) {
      out.write(Uri.encodeComponent(String.fromCharCode(rune)));
    } else {
      final encoded = table[rune];
      if (encoded == null) {
        throw const FormatException('文库8不支持这个搜索字符，请使用中文、字母或数字。');
      }
      out.write(
        '%${(encoded >> 8).toRadixString(16).padLeft(2, '0').toUpperCase()}',
      );
      out.write(
        '%${(encoded & 255).toRadixString(16).padLeft(2, '0').toUpperCase()}',
      );
    }
  }
  return out.toString();
}

Future<Map<int, int>> _loadTable() async {
  final ByteData bytes = await rootBundle.load(
    'lib/assets/encodings/gbk-to-unicode.bin',
  );
  if (bytes.lengthInBytes != 126 * 191 * 2) {
    throw StateError('GBK table length');
  }
  final table = <int, int>{};
  for (var index = 0; index < 126 * 191; index++) {
    final rune = bytes.getUint16(index * 2, Endian.little);
    if (rune == 0) continue;
    table[rune] = ((0x81 + index ~/ 191) << 8) | (0x40 + index % 191);
  }
  return table;
}
