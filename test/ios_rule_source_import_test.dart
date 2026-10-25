// The picker regression must exercise the installed platform plugin directly.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:file_selector_ios/file_selector_ios.dart';
// The actual plugin's codec is required to exercise the failing platform boundary.
// ignore: implementation_imports
import 'package:file_selector_ios/src/messages.g.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/source_import_file.dart';
import 'package:wild/settings/rule_source_manager.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/sources/rules/rule_source_definition.dart';
import 'package:wild/pages/home/recommend_page.dart';
import 'package:wild/theme/ios_glass_theme.dart';

import 'support/huanmeng_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the real iOS plugin accepts the configured file types and cancellation',
    () async {
      final old = FileSelectorPlatform.instance;
      addTearDown(() => FileSelectorPlatform.instance = old);
      FileSelectorIOS.registerWith();
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.file_selector_ios.FileSelectorApi.openFile',
        FileSelectorApi.pigeonChannelCodec,
      );
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(channel, (message) async {
            calls++;
            final config = (message as List).single as FileSelectorConfig;
            expect(
              config.utis,
              containsAll(['public.json', 'public.plain-text', 'public.data']),
            );
            expect(config.allowMultiSelection, isFalse);
            return [<String>[]];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(channel, null),
      );
      expect(await pickSourceImportFile(), isNull);
      expect(calls, 1);
    },
  );

  test(
    'source files accept BOM and reject invalid encoding or excessive size',
    () async {
      final raw = await readSourceImportFile(
        XFile.fromData(
          Uint8List.fromList([
            0xef,
            0xbb,
            0xbf,
            ...utf8.encode(huanmengSourceJson),
          ]),
          name: '幻梦轻小说.json',
        ),
      );
      expect(
        inspectSourceImport(raw, platform: TargetPlatform.iOS).single.error,
        isNull,
      );
      await expectLater(
        readSourceImportFile(
          XFile.fromData(Uint8List.fromList([0xff]), name: 'wrong.json'),
        ),
        throwsFormatException,
      );
      await expectLater(
        readSourceImportFile(
          XFile.fromData(
            Uint8List(maxSourceImportBytes + 1),
            name: 'large.json',
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'original source is accepted on iOS, while the existing Android subset stays unchanged',
    () {
      final item =
          inspectSourceImport(
            huanmengSourceJson,
            platform: TargetPlatform.iOS,
          ).single;
      expect(item.error, isNull);
      expect(item.definition!.name, '幻梦轻小说');
      expect(item.definition!.capabilities.search, isTrue);
      expect(item.definition!.capabilities.discover, isFalse);
      expect(item.notices, isNotEmpty);
      expect(
        inspectSourceImport(
          huanmengSourceJson,
          platform: TargetPlatform.android,
        ).single.error,
        isNotNull,
      );
      final invalid = jsonDecode(huanmengSourceJson) as List;
      invalid.single['ruleContent']['content'] = '@js:java.getSecret()';
      expect(
        inspectSourceImport(
          jsonEncode(invalid),
          platform: TargetPlatform.iOS,
        ).single.error,
        isNotNull,
      );
    },
  );

  test(
    'stable identity survives name and rule changes, reload and a disabled replacement',
    () async {
      var saved = '';
      final registry = RuleSourceRegistry(
        read: () async => saved,
        write: (value) async => saved = value,
      );
      addTearDown(registry.dispose);
      await registry.load(builtIns: []);
      final original =
          inspectSourceImport(
            huanmengSourceJson,
            platform: TargetPlatform.iOS,
          ).single.definition!;
      await registry.install([original]);
      await registry.setEnabled(original.id, false);
      final updated = jsonDecode(huanmengSourceJson) as List;
      updated.single['bookSourceName'] = '幻梦新名称';
      updated.single['ruleSearch']['name'] = 'dt@text##^新';
      final replacement =
          inspectSourceImport(
            jsonEncode(updated),
            platform: TargetPlatform.iOS,
          ).single.definition!;
      expect(replacement.id, original.id);
      await registry.install([replacement], replace: true);
      expect(registry[original.id]!.enabled, isFalse);
      expect(registry.entries, hasLength(1));
      final restored = RuleSourceRegistry(
        read: () async => saved,
        write: (_) async {},
      );
      addTearDown(restored.dispose);
      await restored.load(builtIns: []);
      final definition = restored[original.id]!.definition;
      expect(definition.importKey, 'https://www.huanmengacg.com');
      expect(definition.userAgent, contains('Chrome/124'));
      expect(definition.cookieJar, isTrue);
      expect(
        definition.searchRule!.items!.fields['title']!.legado!.expression,
        'dt@text##^新',
      );
    },
  );

  test('a failed save leaves installed rules unchanged', () async {
    var fail = false;
    final registry = RuleSourceRegistry(
      read: () async => '',
      write: (_) async {
        if (fail) throw StateError('fixture disk full');
      },
    );
    addTearDown(registry.dispose);
    await registry.load(builtIns: []);
    final definition =
        inspectSourceImport(
          huanmengSourceJson,
          platform: TargetPlatform.iOS,
        ).single.definition!;
    await registry.install([definition]);
    fail = true;
    await expectLater(
      registry.install([
        definition.withIdentity(name: 'not saved'),
      ], replace: true),
      throwsStateError,
    );
    expect(registry[definition.id]!.definition.name, '幻梦轻小说');
  });

  test(
    'a later simplified rule keeps the already imported URL identity',
    () async {
      final installed =
          inspectSourceImport(
            huanmengSourceJson,
            platform: TargetPlatform.iOS,
          ).single.definition!;
      final simpler = <String, dynamic>{
        'bookSourceName': '改名后的幻梦',
        'bookSourceUrl': 'https://www.huanmengacg.com',
        'searchUrl': '/search?q={{key}}',
        'ruleSearch': {
          'bookList': '.book',
          'name': '.name@text',
          'bookUrl': 'a@href',
        },
        'ruleBookInfo': {'name': 'h1@text', 'tocUrl': 'a.toc@href'},
        'ruleToc': {
          'chapterList': '.chapter',
          'chapterName': '.name@text',
          'chapterUrl': 'a@href',
        },
        'ruleContent': {'content': '#content@html'},
      };
      expect(
        RuleSourceDefinition.fromLegadoJson(simpler).id,
        isNot(installed.id),
      );
      final updated =
          inspectSourceImport(
            jsonEncode(simpler),
            platform: TargetPlatform.iOS,
            installedSources: [InstalledRuleSource(installed)],
          ).single.definition!;
      expect(updated.id, installed.id);
      expect(updated.importKey, installed.importKey);
      expect(updated.name, '改名后的幻梦');
    },
  );

  testWidgets(
    'a search-only source shows a usable search entry instead of a blank home',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Scaffold(
            body: SearchOnlySourceNotice(
              name: '幻梦轻小说',
              onSearch: () => opened++,
            ),
          ),
        ),
      );
      expect(find.text('此书源通过搜索查找书籍，未提供首页推荐。'), findsOneWidget);
      await tester.tap(find.text('搜索书名或作者'));
      expect(opened, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS local file action previews the original source and commits after confirmation',
    (tester) async {
      var saved = '';
      var writes = 0;
      final registry = RuleSourceRegistry(
        read: () async => saved,
        write: (value) async {
          saved = value;
          writes++;
        },
      );
      addTearDown(registry.dispose);
      await registry.load(builtIns: []);
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RuleSourceManager(
                registry: registry,
                pickFile:
                    () async => XFile.fromData(
                      Uint8List.fromList(utf8.encode(huanmengSourceJson)),
                      name: '幻梦轻小说.json',
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('本地文件'));
      await tester.pumpAndSettle();
      expect(find.text('确认导入书源'), findsOneWidget);
      expect(find.text('幻梦轻小说'), findsOneWidget);
      expect(find.text('此书源通过搜索使用，未提供首页推荐。'), findsOneWidget);
      expect(find.textContaining('JSON.stringify'), findsNothing);
      expect(writes, 0);
      expect(registry.entries, isEmpty);
      await tester.ensureVisible(find.text('导入所选书源'));
      await tester.tap(find.text('导入所选书源'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(registry.entries.single.definition.name, '幻梦轻小说');
      expect(find.text('确认导入书源'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
