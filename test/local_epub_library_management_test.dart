import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/local_epub_library_page.dart';
import 'package:wild/services/epub/apple_books_opener.dart';
import 'package:wild/services/epub/local_epub_library.dart';

import 'support/epub_fixture.dart';

class _DelayedEpub extends XFile {
  _DelayedEpub(this.bytes) : super('慢文件.epub');
  final Uint8List bytes;
  final gate = Completer<Uint8List>();
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() => gate.future;
}

Future<void> settleIo(WidgetTester tester, bool Function() complete) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (complete()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('The operation did not complete');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('EPUB-QA')..addFont(
      File(
        'lib/assets/fonts/LXGWNeoZhiSongPlus.ttf',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await loader.load();
    await (FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late Directory root;
  late LocalEpubLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('litetale_epub_ui_');
    library = LocalEpubLibrary(useIsolates: false);
    await library.initialize(root.path);
  });
  tearDown(() async {
    library.dispose();
    debugDefaultTargetPlatformOverride = null;
    final entries =
        await root.list(recursive: true, followLinks: false).toList();
    for (final file in entries.where((e) => e is File || e is Link)) {
      await file.delete();
    }
    for (final folder
        in entries.whereType<Directory>().toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length))) {
      await folder.delete();
    }
    await root.delete();
  });

  XFile file(String title) =>
      XFile.fromData(buildEpubFixture(title: title), name: '$title.epub');
  Widget app({
    Future<List<XFile>> Function()? pickFiles,
    AppleBooksOpener? opener,
  }) => RepaintBoundary(
    key: const ValueKey('epub-ui-capture'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'EPUB-QA'),
      home: LocalEpubLibraryPage(
        library: library,
        pickFiles: pickFiles,
        opener: opener,
      ),
    ),
  );
  Future<void> capture(WidgetTester tester, String name) async {
    final path = Platform.environment['LITETALE_EPUB_QA_DIR'];
    if (path == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('epub-ui-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('$path/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  testWidgets(
    'iOS batch does not open Apple Books automatically; tapping a book still opens it',
    (tester) async {
      const channel = MethodChannel('litetale/test_books_batch');
      var opens = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        opens++;
        return {'completed': true};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        app(
          pickFiles: () async => [file('第一本'), file('第二本')],
          opener: AppleBooksOpener(channel: channel, isIOS: true),
        ),
      );
      await tester.tap(find.byTooltip('导入 EPUB'));
      await settleIo(
        tester,
        () => library.imports.hasResults && !library.imports.isRunning,
      );
      expect(library.books, hasLength(2));
      expect(opens, 0);
      expect(find.text('导入完成'), findsOneWidget);
      await tester.ensureVisible(find.text('第一本'));
      await tester.tap(find.text('第一本'));
      await settleIo(tester, () => opens == 1);
      expect(tester.takeException(), isNull);
      var flushed = false;
      unawaited(library.organization.flush().then((_) => flushed = true));
      await settleIo(tester, () => flushed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('single-book iOS import preserves the existing open action', (
    tester,
  ) async {
    const channel = MethodChannel('litetale/test_books_single');
    var opens = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      opens++;
      return {'completed': true};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      app(
        pickFiles: () async => [file('单本导入')],
        opener: AppleBooksOpener(channel: channel, isIOS: true),
      ),
    );
    await tester.tap(find.byTooltip('导入 EPUB'));
    await settleIo(tester, () => opens == 1);
    expect(library.books.single.title, '单本导入');
    expect(tester.takeException(), isNull);
    var flushed = false;
    unawaited(library.organization.flush().then((_) => flushed = true));
    await settleIo(tester, () => flushed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'filtered select-all classifies only visible books and removing membership keeps the book',
    (tester) async {
      await tester.runAsync(() async {
        await library.importFile(file('系列 第1卷'));
        await library.importFile(file('系列 第2卷'));
        await library.importFile(file('别的故事'));
        await library.organization.createCollection('测试分类');
      });
      final c = library.organization.collections.single;
      await tester.pumpWidget(app());
      await tester.enterText(find.byType(TextField), '系列');
      await tester.pumpAndSettle();
      await tester.longPress(find.text('系列 第1卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 本'), findsOneWidget);
      await tester.tap(find.text('加入分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入分类').last);
      await settleIo(
        tester,
        () =>
            library.books
                .where((b) => library.organization.contains(c.id, b.id))
                .length ==
            2,
      );
      final other = library.books.singleWhere((b) => b.title == '别的故事');
      expect(library.organization.contains(c.id, other.id), isFalse);
      await tester.tap(find.byTooltip('退出多选'));
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部 (3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试分类 (2)').last);
      await settleIo(
        tester,
        () => library.organization.selectedCollection == c.id,
      );
      expect(find.text('别的故事'), findsNothing);
      await tester.longPress(find.text('系列 第1卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从当前分类移出'));
      await settleIo(
        tester,
        () =>
            library.books
                .where((b) => library.organization.contains(c.id, b.id))
                .length ==
            1,
      );
      expect(library.books, hasLength(3));
      expect(tester.takeException(), isNull);
      var flushed = false;
      unawaited(library.organization.flush().then((_) => flushed = true));
      await settleIo(tester, () => flushed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('collection create rename and remove UI retains book files', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byTooltip('管理分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '待看');
    await tester.tap(find.text('保存'));
    await settleIo(tester, () => library.organization.collections.isNotEmpty);
    final id = library.organization.collections.single.id;
    await tester.tap(find.byTooltip('待看的分类操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '校园');
    await tester.tap(find.text('保存'));
    await settleIo(
      tester,
      () => library.organization.collections.single.name == '校园',
    );
    expect(library.organization.collections.single.id, id);
    await tester.tap(find.byTooltip('校园的分类操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除分类').last);
    await settleIo(tester, () => library.organization.collections.isEmpty);
    expect(tester.takeException(), isNull);
    var flushed = false;
    unawaited(library.organization.flush().then((_) => flushed = true));
    await settleIo(tester, () => flushed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('import queue survives leaving and reopening its route', (
    tester,
  ) async {
    final delayed = _DelayedEpub(buildEpubFixture(title: '等待中的故事'));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'EPUB-QA'),
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder:
                              (_) => LocalEpubLibraryPage(
                                library: library,
                                pickFiles: () async => [delayed, file('接着导入')],
                              ),
                        ),
                      ),
                  child: const Text('进入书库'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('进入书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导入 EPUB'));
    await tester.pump();
    expect(library.imports.isRunning, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    delayed.gate.complete(delayed.bytes);
    await settleIo(tester, () => !library.imports.isRunning);
    expect(library.books, hasLength(2));
    await tester.tap(find.text('进入书库'));
    await tester.pumpAndSettle();
    expect(find.text('导入完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
    var flushed = false;
    unawaited(library.organization.flush().then((_) => flushed = true));
    await settleIo(tester, () => flushed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'batch target collection becomes visible and contains every successful import',
    (tester) async {
      await tester.runAsync(() async {
        await library.organization.createCollection('新系列');
      });
      final c = library.organization.collections.single;
      await tester.pumpWidget(
        app(pickFiles: () async => [file('卷1'), file('卷2')]),
      );
      await tester.tap(find.byTooltip('导入 EPUB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新系列'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始导入'));
      await settleIo(
        tester,
        () => library.imports.hasResults && !library.imports.isRunning,
      );
      expect(library.organization.selectedCollection, c.id);
      expect(
        library.books.every((b) => library.organization.contains(c.id, b.id)),
        isTrue,
      );
      expect(find.text('卷1'), findsOneWidget);
      var flushed = false;
      unawaited(library.organization.flush().then((_) => flushed = true));
      await settleIo(tester, () => flushed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform populated library supports selection on a phone', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await library.importFile(file('系列 第1卷'));
        await library.importFile(file('系列 第2卷'));
        await library.importFile(file('海边来信'));
        await library.organization.createCollection('待看');
      });
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await capture(tester, 'local-epub-${platform.name}-library');
      await tester.longPress(find.text('系列 第1卷'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 本'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'local-epub-${platform.name}-selection');
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
    testWidgets('$platform narrow screen and large text remain scrollable', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = const Size(360, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('epub-ui-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'EPUB-QA'),
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.6)),
                  child: child!,
                ),
            home: LocalEpubLibraryPage(library: library),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'local-epub-${platform.name}-large-text');
      var flushed = false;
      unawaited(library.organization.flush().then((_) => flushed = true));
      await settleIo(tester, () => flushed);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
