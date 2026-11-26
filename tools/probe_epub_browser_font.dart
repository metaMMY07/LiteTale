import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:wild/services/epub/epub_browser_font.dart';

/// Exercise the production repair on a private QA copy, never the source font.
void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('input.ttf output.ttf');
  final source = File(args[0]), output = File(args[1]);
  if (source.absolute.path.toLowerCase() ==
      output.absolute.path.toLowerCase()) {
    throw ArgumentError('The output must be a separate QA copy');
  }
  final original = source.readAsBytesSync();
  final digest = sha256.convert(original).toString();
  final fixed = epubBrowserFontBytes(original);
  output.writeAsBytesSync(fixed);
  if (sha256.convert(source.readAsBytesSync()).toString() != digest) {
    throw StateError('Source font changed');
  }
  stdout.writeln(
    'bytes=${fixed.length}; originalPreserved=true; '
    'changed=${sha256.convert(fixed).toString() != digest}',
  );
}
