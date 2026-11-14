import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/settings/rule_source_manager.dart';
import 'package:wild/sources/rule_source_registry.dart';

import 'support/huanmeng_source.dart';

void main() {
  testWidgets('opening source management only mounts nearby rules', (
    tester,
  ) async {
    final raw =
        jsonDecode(File('assets/book_sources/bundled.json').readAsStringSync())
            as List;
    final template = Map<String, dynamic>.from(raw.first as Map);
    final source = Map<String, dynamic>.from(template['source'] as Map);
    final registry = RuleSourceRegistry(read: () async => '');
    addTearDown(registry.dispose);
    await registry.load(
      builtIns: List.generate(
        100,
        (index) => {
          ...template,
          'source': {...source, 'id': 'fixture_$index', 'name': '导入书源 $index'},
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [RuleSourceManager(registry: registry)],
          ),
        ),
      ),
    );

    final first = find.text('导入书源 0');
    final last = find.text('导入书源 99');
    expect(first, findsOneWidget);
    expect(last, findsNothing);
    expect(find.textContaining('导入书源 ').evaluate().length, lessThan(20));

    await tester.scrollUntilVisible(last, 800);
    await tester.pumpAndSettle();
    expect(last.hitTestable(), findsOneWidget);
    expect(first, findsNothing);
  });

  testWidgets('Android paste imports the rule once and skips a repeat', (
    tester,
  ) async {
    var writes = 0;
    final registry = RuleSourceRegistry(
      read: () async => '',
      write: (_) async => writes++,
    );
    addTearDown(registry.dispose);
    await registry.load(builtIns: []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [RuleSourceManager(registry: registry)],
          ),
        ),
      ),
    );

    Future<void> openPreview() async {
      await tester.tap(find.text('粘贴规则'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), huanmengSourceJson);
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
    }

    await openPreview();
    expect(find.textContaining('新增 ·'), findsOneWidget);
    expect(writes, 0);
    final save = find.text('导入所选书源');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(registry.entries.single.definition.name, '幻梦轻小说');

    await openPreview();
    expect(find.textContaining('规则相同 ·'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(registry.entries, hasLength(1));
  });

  testWidgets(
    'import preview keeps incompatible source separate and saves selected valid source',
    (tester) async {
      final source =
          (jsonDecode(
                    File('assets/book_sources/bundled.json').readAsStringSync(),
                  )
                  as List)
              .first;
      final items = inspectSourceImport(
        jsonEncode([
          source,
          {'schema': 'litetale-rule-source', 'schemaVersion': 999},
        ]),
      );
      String saved = '';
      final registry = RuleSourceRegistry(
        read: () async => '',
        write: (raw) async => saved = raw,
      );
      await registry.load(builtIns: []);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed:
                        () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder:
                                (_) => RuleImportPreviewPage(
                                  items: items,
                                  registry: registry,
                                ),
                          ),
                        ),
                    child: const Text('打开导入'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('打开导入'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 项未通过'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      await tester.tap(find.text('导入所选书源'));
      await tester.pumpAndSettle();
      expect(registry.entries.length, 1);
      expect((jsonDecode(saved)['entries'] as List).length, 1);
      await tester.pumpWidget(const SizedBox());
      registry.dispose();
    },
  );
}
