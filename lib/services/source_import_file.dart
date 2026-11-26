import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';

const maxSourceImportBytes = 2 * 1024 * 1024;

// Some Files providers label downloaded JSON as text or generic data. Content
// validation remains mandatory after selection; these are picker hints only.
const sourceImportTypeGroups = [
  XTypeGroup(
    label: 'JSON 书源',
    extensions: ['json'],
    mimeTypes: ['application/json'],
    uniformTypeIdentifiers: ['public.json', 'public.plain-text', 'public.data'],
  ),
];

Future<XFile?> pickSourceImportFile() =>
    openFile(acceptedTypeGroups: sourceImportTypeGroups);

Future<String> readSourceImportFile(XFile file) async {
  if (await file.length() > maxSourceImportBytes) {
    throw const FormatException('书源文件不能超过 2 MB');
  }
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final part in file.openRead()) {
    length += part.length;
    if (length > maxSourceImportBytes) {
      throw const FormatException('书源文件不能超过 2 MB');
    }
    bytes.add(part);
  }
  String raw;
  try {
    raw = utf8.decode(bytes.takeBytes());
  } on FormatException {
    throw const FormatException('书源文件编码不支持，请选择 UTF-8 JSON 文件');
  }
  if (raw.startsWith('\uFEFF')) raw = raw.substring(1);
  if (raw.trim().isEmpty) throw const FormatException('书源文件为空');
  return raw;
}
