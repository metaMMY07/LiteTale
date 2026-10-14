import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/settings/rule_source_manager.dart';
import 'package:wild/sources/rule_source_registry.dart';

void main() {
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
