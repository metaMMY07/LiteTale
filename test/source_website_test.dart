import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_website.dart';

void main() {
  test('online source addresses point to the public website, not an API', () {
    final websites = {
      SourceId.wenku8: 'https://www.wenku8.net/',
      SourceId.lightNovelShelf: 'https://www.lightnovel.app/',
      SourceId.lnovel: 'https://lnovel.tw/',
      SourceId.bili: 'https://www.bilinovel.net/',
      SourceId.huanmeng: 'https://www.huanmengacg.com/',
      SourceId.esj: 'https://www.esjzone.cc/',
    };
    for (final entry in websites.entries) {
      expect(sourceWebsite(entry.key).toString(), entry.value);
    }
    expect(sourceWebsite(SourceId.localEpub), isNull);
  });

  test(
    'Wenku8 follows the configured mirror and safely defaults invalid values',
    () {
      expect(
        sourceWebsite(SourceId.wenku8, wenku8Host: 'https://m.wenku8.net/'),
        Uri.parse('https://m.wenku8.net/'),
      );
      for (final host in [
        '',
        'http://www.wenku8.net',
        'https://www.wenku8.net.evil.example',
        'https://user:password@www.wenku8.net',
        'https://www.wenku8.net/?token=secret',
      ]) {
        expect(
          sourceWebsite(SourceId.wenku8, wenku8Host: host),
          Uri.parse('https://www.wenku8.net/'),
        );
      }
    },
  );

  test('imported source links contain only the configured website origin', () {
    final source = SourceId.rule('example');
    expect(
      sourceWebsite(
        source,
        ruleBaseUrl: Uri.parse(
          'https://novel.example/api/v1?key=secret#chapter',
        ),
      ),
      Uri.parse('https://novel.example/'),
    );
    // Existing rule sources also support HTTP; the external browser must see
    // their real address rather than silently changing the scheme.
    expect(
      sourceWebsite(
        source,
        ruleBaseUrl: Uri.parse('http://novel.example/books/'),
      ),
      Uri.parse('http://novel.example/'),
    );
    for (final invalid in [
      'javascript:alert(1)',
      'file:///tmp/book',
      '/books',
      'https://user:password@novel.example/',
    ]) {
      expect(sourceWebsite(source, ruleBaseUrl: Uri.parse(invalid)), isNull);
    }
    expect(sourceWebsite(SourceId.rule('not-installed')), isNull);
  });
}
