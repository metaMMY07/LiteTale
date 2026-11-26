import 'dart:typed_data';

/// A few legacy fonts encode vhea version 1.1 as 0x00010001. OpenType defines
/// that version as 0x00011000; Chromium OTS rejects the former. Correct only
/// this known marker in an ephemeral copy, preserving every glyph/layout table.
/// The imported original, its identity and Flutter's global font stay intact.
Uint8List epubBrowserFontBytes(Uint8List input) {
  if (input.length < 12 || input.length > 64 * 1024 * 1024) return input;
  final data = ByteData.sublistView(input);
  final count = data.getUint16(4);
  if (count == 0 || count > 256 || 12 + count * 16 > input.length) return input;
  int? vheaEntry, headOffset;
  for (var i = 0; i < count; i++) {
    final at = 12 + i * 16,
        tag = data.getUint32(at),
        offset = data.getUint32(at + 8),
        length = data.getUint32(at + 12);
    if (offset < 12 + count * 16 || offset + length > input.length) {
      return input;
    }
    if (tag == 0x76686561 && length == 36) vheaEntry = at;
    if (tag == 0x68656164 && length >= 54) headOffset = offset;
  }
  if (vheaEntry == null || headOffset == null) return input;
  final vheaOffset = data.getUint32(vheaEntry + 8);
  if (data.getUint32(vheaOffset) != 0x00010001) return input;
  final bytes = Uint8List.fromList(input), output = ByteData.sublistView(bytes);
  output.setUint32(vheaOffset, 0x00011000);
  int sum(int start, int length) {
    var checksum = 0;
    for (var i = 0; i < length; i += 4) {
      var word = 0;
      for (var j = 0; j < 4; j++) {
        word = (word << 8) | (i + j < length ? bytes[start + i + j] : 0);
      }
      checksum = (checksum + word) & 0xffffffff;
    }
    return checksum;
  }

  output.setUint32(vheaEntry + 4, sum(vheaOffset, 36));
  output.setUint32(headOffset + 8, 0);
  output.setUint32(
    headOffset + 8,
    (0xb1b0afba - sum(0, bytes.length)) & 0xffffffff,
  );
  return bytes;
}
