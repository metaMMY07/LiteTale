import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/utils/wenku8_document_read.dart';
import 'package:wild/utils/wenku8_read_dom.dart';
import 'package:wild/utils/wenku8_home_dom.dart';
import 'package:wild/utils/wenku8_bookshelf_dom.dart';

void main() {
  final module = Platform.environment['PLAYWRIGHT_MODULE_PATH'];
  final executable = Platform.environment['PLAYWRIGHT_EXECUTABLE_PATH'];
  test(
    'browser document reads keep cookies/GBK and do not render assets or scripts',
    () async {
      const host = 'https://www.wenku8.net';
      String read(int timeoutMs) => wenku8DocumentReadScript(
        host: host,
        target: Uri.parse('$host/novel/0/101/19.htm'),
        extraction: wenku8ReadDomExtractionScript(
          host,
          kind: 'chapter',
          aid: '101',
        ),
        timeoutMs: timeoutMs,
      );
      final process = await Process.start(
        Platform.environment['NODE_EXECUTABLE'] ?? 'node',
        [
          File(
            'test/scripts/wenku8_document_playwright_harness.cjs',
          ).absolute.path,
        ],
      );
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.write(
        jsonEncode({
          'host': host,
          'park': wenku8ParkDocumentScript(host),
          'read': read(2000),
          'shortRead': read(50),
          'state': wenku8DocumentReadStateScript,
          'emptyContext': wenku8EmptyReadContextHtml,
          'pageState': Wenku8BrowserSession.pageStateScript,
          'bookshelfRead': wenku8DocumentReadScript(
            host: host,
            target: Uri.parse('$host/modules/article/bookcase.php?classid=0'),
            extraction: wenku8BookshelfScript(host, '0'),
            timeoutMs: 2000,
          ),
          'homeHtml':
              File('test/fixtures/wenku8_home_modern.html').readAsStringSync(),
          'homeRead': wenku8DocumentReadScript(
            host: host,
            target: Uri.parse('$host/'),
            extraction: wenku8HomeDomExtractionScript(host),
            timeoutMs: 2000,
          ),
        }),
      );
      await process.stdin.close();
      expect(await process.exitCode, 0, reason: await errors);
      expect((jsonDecode(await output) as Map)['passed'], isTrue);
    },
    skip:
        module == null || executable == null
            ? 'Chromium fixture runtime is optional'
            : false,
  );
}
