import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/epub_browser_font.dart';

void main() {
  Uint8List fixture(int version) {
    final bytes = Uint8List(192), d = ByteData.sublistView(bytes);
    d.setUint32(0, 0x00010000);
    d.setUint16(4, 3);
    final tables = [
      (0x68656164, 60, 54),
      (0x76686561, 116, 36),
      (0x676c7966, 152, 40),
    ];
    for (var i = 0; i < tables.length; i++) {
      final e = 12 + i * 16, t = tables[i];
      d.setUint32(e, t.$1);
      d.setUint32(e + 8, t.$2);
      d.setUint32(e + 12, t.$3);
    }
    d.setUint32(116, version);
    for (var i = 152; i < bytes.length; i++) {
      bytes[i] = i % 251;
    }
    return bytes;
  }

  test(
    'only the known invalid vertical version is repaired; original and glyph bytes stay unchanged',
    () {
      final bytes = fixture(0x00010001), d = ByteData.sublistView(bytes);
      final result = epubBrowserFontBytes(bytes),
          out = ByteData.sublistView(result);
      expect(d.getUint32(116), 0x00010001);
      expect(out.getUint32(116), 0x00011000);
      expect(result.sublist(152), bytes.sublist(152));
      var checksum = 0;
      for (var i = 0; i < result.length; i += 4) {
        checksum = (checksum + out.getUint32(i)) & 0xffffffff;
      }
      expect(checksum, 0xb1b0afba);
      expect(identical(epubBrowserFontBytes(result), result), isTrue);
    },
  );
  test('truncated directories and unrelated versions are never modified', () {
    for (final bytes in [Uint8List(0), Uint8List(11), fixture(0x00010000)]) {
      expect(identical(epubBrowserFontBytes(bytes), bytes), isTrue);
    }
  });
}
