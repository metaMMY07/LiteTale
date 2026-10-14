import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/bili_site_source.dart';

void main() {
  test(
    'parses public fragments produced by the actual mobile browser scripts',
    () async {
      final data =
          jsonDecode(
                File(
                  'build/bili-site-2026-10/mobile-public-documents.json',
                ).readAsStringSync(),
              )
              as Map;
      final paths = <String>[];
      final source = BiliSiteSource(
        searcher: (_, __) => throw StateError('not used'),
        chapterLoader: (_, __) => throw StateError('not used'),
        documentLoader: (uri) async {
          paths.add(uri.path);
          return data[uri.path == '/'
                  ? 'home'
                  : uri.path.endsWith('/catalog')
                  ? 'catalog'
                  : 'detail']
              as String;
        },
      );
      final home = await source.discover();
      expect(home.single.list, isNotEmpty);
      expect(home.single.list.length, lessThanOrEqualTo(100));
      expect(
        home.single.list.every(
          (b) => b.img.startsWith('https://www.bilinovel.net/'),
        ),
        true,
      );
      final detail = await source.detail('bili:2844');
      expect(detail.info.title, 'SeaBed');
      expect(detail.info.author, 'Paleontology');
      expect(detail.info.introduce, isNotEmpty);
      expect(detail.volumes, hasLength(16));
      final chapters = detail.volumes.expand((v) => v.chapters).toList();
      expect(chapters.first.cid, 'bili:2844:278138');
      expect(chapters.every((c) => c.aid == 'bili:2844'), true);
      expect(paths, hasLength(3));
      // Only book metadata/counts, never prose or session values.
      // ignore: avoid_print
      print(
        'Actual browser fragments: ${home.single.list.length} home books, ${detail.volumes.length} SeaBed volumes, ${chapters.length} chapters',
      );
    },
    skip: !const bool.fromEnvironment('BILI_BROWSER_DOCUMENTS'),
  );
}
