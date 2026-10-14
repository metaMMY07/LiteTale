import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/rule_book_source.dart';
import 'package:wild/sources/rules/rule_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final definitions =
      (jsonDecode(File('assets/book_sources/bundled.json').readAsStringSync())
              as List)
          .map(
            (v) => RuleSourceDefinition.fromJson(
              Map<String, dynamic>.from(v as Map),
            ),
          )
          .toList();
  test('bundled sources contain the retained light novel adapter', () {
    expect(definitions.map((d) => d.id), ['sfacg_public']);
    for (final definition in definitions) {
      expect(definition.capabilities.discover, isTrue);
      expect(definition.capabilities.detail, isTrue);
      expect(definition.capabilities.catalog, isTrue);
      expect(definition.capabilities.content, isTrue);
    }
  });

  for (final definition in definitions) {
    test(
      'live bundled source ${definition.id} discovery/detail/catalog/content',
      () async {
        final original = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = original);
        final source = RuleBookSource(definition);
        final home = await source.discover();
        expect(home.single.list, isNotEmpty);
        const url = 'https://book.sfacg.com/Novel/775264/';
        final id = ruleBookId(definition.id, url);
        final detail = await source.detail(id);
        expect(detail.info.title, isNotEmpty);
        final chapters = detail.volumes.single.chapters;
        expect(chapters, isNotEmpty);
        final content = await source.chapter(id, chapters.first.cid);
        expect(content.content.length, greaterThan(300));
        expect(content.content, isNot(contains('<script')));
        if (definition.capabilities.search) {
          const query = '转生';
          final result = await source.search(query, 'articlename', 1);
          expect(result.records.any((b) => b.title.contains(query)), isTrue);
        }
      },
      skip: !const bool.fromEnvironment('LITETALE_RULE_SOURCE_LIVE'),
      timeout: const Timeout(Duration(seconds: 110)),
    );
  }
}
