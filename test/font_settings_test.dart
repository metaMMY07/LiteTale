import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/home/font_settings_page.dart';
import 'package:wild/services/imported_fonts.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/theme/imported_font_theme.dart';
import 'package:wild/theme/material_you.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List fontBytes;
  late Directory root;
  late FontSettingsCubit cubit;
  late String saved;
  XFile? input;
  var failWrite = false;
  final registrations = <String>[];

  setUpAll(() async {
    fontBytes =
        (await rootBundle.load(
          'lib/assets/fonts/LXGWNeoZhiSongPlus.ttf',
        )).buffer.asUint8List();
  });
  setUp(() async {
    root = await Directory('build/font-tests').create(recursive: true);
    root =
        await Directory(
          '${root.path}/${DateTime.now().microsecondsSinceEpoch}',
        ).create();
    saved = '';
    failWrite = false;
    registrations.clear();
    input = XFile.fromData(fontBytes, name: '用户字体.ttf', path: '用户字体.ttf');
    cubit = FontSettingsCubit(
      store: ImportedFontStore(
        register: (family, bytes) async => registrations.add(family),
      ),
      pick: () async => input,
      read: () async => saved,
      write: (value) async {
        if (failWrite) throw const FileSystemException('disk unavailable');
        saved = value;
      },
    );
    await cubit.initialize(root.path);
  });
  tearDown(() async => cubit.close());

  test(
    'imports independent fonts, copies bytes, reloads without picker file, resets one scope',
    () async {
      expect(await cubit.importFont(FontScope.app), isTrue);
      final imported = cubit.state.app!;
      expect(cubit.state.reader, isNull);
      expect(cubit.state.readerFamily, appFontFamily);
      final copy = File('${root.path}/imported_fonts/${imported.fileName}');
      expect(await copy.readAsBytes(), fontBytes);
      // Simulate a provider naming a valid binary font .bin.
      input = XFile.fromData(fontBytes, name: '阅读.bin', path: '阅读.bin');
      expect(await cubit.importFont(FontScope.reader), isTrue);
      expect(cubit.state.app!.name, '用户字体.ttf');
      expect(cubit.state.reader!.name, '阅读.bin');
      expect(registrations.length, 1, reason: 'same font bytes load once');
      input = null;
      final restarted = FontSettingsCubit(
        read: () async => saved,
        write: (value) async => saved = value,
        store: ImportedFontStore(
          register: (family, bytes) async {
            expect(bytes, fontBytes);
            registrations.add(family);
          },
        ),
      );
      await restarted.initialize(root.path);
      expect(restarted.state.appFamily, imported.family);
      expect(restarted.state.readerFamily, imported.family);
      expect(registrations.length, 2);
      await restarted.reset(FontScope.app);
      expect(restarted.state.appFamily, isNull);
      expect(restarted.state.readerFamily, imported.family);
      expect(jsonDecode(saved)['app'], isNull);
      expect(jsonDecode(saved)['reader']['digest'], imported.digest);
      await restarted.close();
    },
  );

  test(
    'cancel, corrupt font and failed persistence keep the existing choice',
    () async {
      await cubit.importFont(FontScope.reader);
      final family = cubit.state.readerFamily;
      final previousSaved = saved;
      input = null;
      expect(await cubit.importFont(FontScope.reader), isFalse);
      input = XFile.fromData(Uint8List.fromList([1, 2, 3]), path: 'fake.ttf');
      await expectLater(
        cubit.importFont(FontScope.reader),
        throwsA(isA<FontImportException>()),
      );
      input = XFile.fromData(fontBytes, path: 'valid.ttf');
      failWrite = true;
      await expectLater(
        cubit.importFont(FontScope.app),
        throwsA(isA<FontImportException>()),
      );
      await expectLater(
        cubit.reset(FontScope.reader),
        throwsA(isA<FontImportException>()),
      );
      expect(cubit.state.busy, isNull);
      expect(cubit.state.app, isNull);
      expect(cubit.state.readerFamily, family);
      expect(saved, previousSaved);
    },
  );

  test(
    'rejects invalid table bounds, bad signature, oversized and font collections',
    () {
      expect(inspectFontBytes(fontBytes), matches(RegExp(r'^[a-f0-9]{64}$')));
      final truncated = Uint8List.fromList(
        fontBytes.sublist(0, fontBytes.length ~/ 2),
      );
      expect(
        () => inspectFontBytes(truncated),
        throwsA(isA<FontImportException>()),
      );
      final corrupt = Uint8List.fromList(fontBytes);
      ByteData.sublistView(corrupt).setUint32(20, 0xffffffff);
      expect(
        () => inspectFontBytes(corrupt),
        throwsA(isA<FontImportException>()),
      );
      ByteData.sublistView(corrupt).setUint32(0, 0x74746366);
      expect(
        () => inspectFontBytes(corrupt),
        throwsA(isA<FontImportException>()),
      );
      expect(
        () => inspectFontBytes(Uint8List(maxImportedFontBytes + 1)),
        throwsA(isA<FontImportException>()),
      );
    },
  );

  test(
    'missing or changed private copy falls back without breaking other font',
    () async {
      await cubit.importFont(FontScope.app);
      final app = cubit.state.app!;
      final invalidReader = ImportedFont(
        name: 'missing.otf',
        digest: 'a' * 64,
        extension: 'otf',
      );
      final restarted = FontSettingsCubit(
        read:
            () async =>
                FontSettingsState(app: app, reader: invalidReader).toJson(),
        store: ImportedFontStore(register: (_, _) async {}),
      );
      await restarted.initialize(root.path);
      expect(restarted.state.appFamily, app.family);
      expect(restarted.state.readerFamily, appFontFamily);
      expect(restarted.state.restoreWarning, isNotNull);
      await File(
        '${root.path}/imported_fonts/${app.fileName}',
      ).writeAsBytes([1, 2, 3]);
      await restarted.initialize(root.path);
      expect(restarted.state.appFamily, isNull);
      expect(restarted.state.readerFamily, appFontFamily);
      await restarted.close();
    },
  );

  test(
    'saved path traversal is rejected and source font keeps decoding priority',
    () async {
      const invalid =
          '{"version":1,"app":{"name":"oops.ttf","digest":"../../oops","extension":"ttf"}}';
      final restarted = FontSettingsCubit(read: () async => invalid);
      await restarted.initialize(root.path);
      expect(restarted.state.appFamily, isNull);
      expect(restarted.state.restoreWarning, isNotNull);
      await cubit.importFont(FontScope.reader);
      expect(cubit.state.resolveReaderFamily('ShelfEncoded'), 'ShelfEncoded');
      expect(cubit.state.resolveReaderFamily(null), cubit.state.readerFamily);
      await restarted.close();
    },
  );

  test(
    'concurrent picker/reset is blocked and a late restore cannot replace a new import',
    () async {
      final pendingRead = Completer<String>();
      final pendingPick = Completer<XFile?>();
      final racing = FontSettingsCubit(
        read: () => pendingRead.future,
        pick: () => pendingPick.future,
        write: (_) async {},
        store: ImportedFontStore(register: (_, _) async {}),
      );
      final load = racing.initialize(root.path);
      final importing = racing.importFont(FontScope.reader);
      expect(await racing.importFont(FontScope.app), isFalse);
      expect(await racing.reset(FontScope.reader), isFalse);
      pendingPick.complete(input);
      expect(await importing, isTrue);
      final family = racing.state.readerFamily;
      pendingRead.complete('');
      await load;
      expect(racing.state.readerFamily, family);
      await racing.close();
    },
  );

  test('real Flutter font loader registers imported TTF', () async {
    final store = ImportedFontStore()..initialize(root.path);
    final imported = await store.importFile(input!);
    final painter = TextPainter(
      text: TextSpan(
        text: '山海有故事，LiteTale 0123',
        style: TextStyle(fontFamily: imported.family, fontSize: 20),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(painter.width, greaterThan(0));
    expect(painter.height, greaterThan(0));
    painter.dispose();
  });

  testWidgets(
    'UI provides independent previews, picker cancellation and native theme/Icons survive',
    (tester) async {
      final native = materialYouTheme(Brightness.light);
      final imported = applyImportedAppFont(native, 'UserFont');
      expect(imported.textTheme.bodyMedium!.fontFamily, 'UserFont');
      expect(imported.appBarTheme.titleTextStyle!.fontFamily, 'UserFont');
      expect(
        imported.textTheme.bodyMedium!.fontFamilyFallback,
        contains(appFontFamily),
      );
      expect(applyImportedAppFont(native, null), same(native));
      input = null;
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(theme: native, home: const FontSettingsPage()),
        ),
      );
      expect(find.text('全局界面字体'), findsOneWidget);
      expect(find.text('小说阅读字体'), findsOneWidget);
      final appPreview = tester.widget<Text>(
        find.byKey(const ValueKey('font-preview-app')),
      );
      final readerPreview = tester.widget<Text>(
        find.byKey(const ValueKey('font-preview-reader')),
      );
      expect(appPreview.style!.fontFamily, isNull);
      expect(appPreview.style!.fontFamilyFallback, isNull);
      expect(readerPreview.style!.fontFamily, appFontFamily);
      expect(Icons.file_open_outlined.fontFamily, 'MaterialIcons');
      await tester.tap(find.byKey(const ValueKey('font-import-app')));
      await tester.pumpAndSettle();
      expect(cubit.state.busy, isNull);
      expect(cubit.state.app, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
