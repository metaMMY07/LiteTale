import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import '../test/support/epub_fixture.dart';
import '../test/support/huanmeng_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/app_launch_screen.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/services/reader_page_controller.dart';
import 'package:wild/services/source_import_file.dart';
import 'package:wild/settings/rule_source_manager.dart';
import 'package:wild/sources/rule_source_registry.dart';
import 'package:wild/services/huanmeng_api_session.dart';
import 'package:wild/services/huanmeng_http_transport.dart';
import 'package:wild/sources/huanmeng_source.dart';
import 'package:wild/widgets/wenku_webview.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'built-in Huanmeng uses direct HTTP on iOS and reads real public chapters',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(api.availableSources, contains(SourceId.huanmeng));
      expect(api.availableSources, isNot(contains(SourceId.esj)));
      final source = api.huanmengSource;
      expect(source.transport, isA<HuanmengHttpTransport>());
      final stopwatch = Stopwatch()..start();
      final first = await source.list();
      final second = await source.list(page: 2);
      expect(first.records, isNotEmpty);
      expect(
        second.records.any(
          (book) => !first.records.any((a) => a.aid == book.aid),
        ),
        isTrue,
      );
      final search = await source.search('败北', 'title', 1);
      expect(search.records.any((book) => book.aid == 'hm:4799'), isTrue);
      final detail = await source.detail('hm:4799');
      final chapters = detail.volumes.expand((volume) => volume.chapters);
      expect(chapters.any((chapter) => chapter.cid == 'hm:4799:1841'), isTrue);
      final chapter = await source.chapter('hm:4799', 'hm:4799:1841');
      expect(chapter.content.length, greaterThan(200));
      expect(chapter.content, isNot(contains('接口密码错误')));
      expect(chapter.content, isNot(contains('书籍下架通知')));
      final result = {
        'platform': 'iOS simulator native Dart HTTP',
        'list': first.records.length,
        'next': second.records.length,
        'search': search.records.length,
        'chapters': chapters.length,
        'chapterCharacters': chapter.content.length,
        'elapsedMs': stopwatch.elapsedMilliseconds,
      };
      stdout.writeln('HUANMENG_IOS_LIVE_RESULT=${jsonEncode(result)}');
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Scaffold(
            appBar: AppBar(title: const Text('幻梦轻小说')),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('原站公开接口：搜索、目录、正文通过'),
                Text('书名：${detail.info.title}'),
                Text('目录：${chapters.length}章'),
                Text('正文：${chapter.content.length}字符'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await binding.takeScreenshot('huanmeng-ios-direct-api-live');
      expect(tester.takeException(), isNull);
    },
    skip: !const bool.fromEnvironment('HUANMENG_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  testWidgets(
    'native Huanmeng browser protocol handles JSON, 429 and byte bounds with offline fixtures',
    (tester) async {
      expect(api.availableSources, contains(SourceId.huanmeng));
      final web = WenkuWebView();
      try {
        await web.initialize(
          onLoaded: () {},
          onError: (_) {},
          normalBrowserUserAgent: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: iosGlassTheme(Brightness.light),
            home: Scaffold(body: web.build()),
          ),
        );
        await web.loadUrl('about:blank');
        await tester.pump(const Duration(milliseconds: 300));
        final uri = Uri.parse(
          'https://www.huanmengacg.com/index.php/bookapi/content?password=${HuanmengSource.publicApiKey}&bid=7&cid=11',
        );
        // Only the app-authored request/probe runs in real WebKit. Fetch is stubbed;
        // no successful live-source request or Cloudflare clearance is implied.
        Future<Map<String, dynamic>> readFixture(
          String response,
          String token,
        ) async {
          await web.executeScript(
            'window.fetch=async(url,options)=>{window.__fixtureRequest={url,credentials:options.credentials,redirect:options.redirect};return $response;};true;',
          );
          await web.executeScript(HuanmengApiSession.fetchScript(uri, token));
          for (var i = 0; i < 35; i++) {
            final result = HuanmengApiSession.decodeProbe(
              await web.executeScript(HuanmengApiSession.fetchProbe),
            );
            if (result['token'] == token && result['done'] == true) {
              return result;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          throw StateError('Offline WebKit protocol fixture did not complete');
        }

        final data = {
          'data': {'content': '<p>离线协议测试</p>'},
        };
        final normal = await readFixture(
          'new Response(${jsonEncode(jsonEncode(data))},{status:200,headers:{"Content-Type":"application/json"}})',
          'native_json',
        );
        expect(HuanmengApiSession.decodeEnvelope(normal['text']), data);
        final request = HuanmengApiSession.decodeProbe(
          await web.executeScript('JSON.stringify(window.__fixtureRequest)'),
        );
        expect(request, {
          'url': uri.toString(),
          'credentials': 'same-origin',
          'redirect': 'error',
        });
        final limited = await readFixture(
          'new Response(new ReadableStream({start(){}}),{status:429,headers:{"Retry-After":"240"}})',
          'native_429',
        );
        expect(limited['status'], 429);
        expect(limited['retryAfter'], '240');
        final large = await readFixture(
          'new Response(new Uint8Array(2097153),{status:200})',
          'native_size',
        );
        expect(large['tooLarge'], isTrue);
        expect(large['text'], isNull);
        final text = jsonEncode({
          'data': {
            'content': 'Sorry, you have been blocked; 429 Too Many Requests',
          },
        });
        await web.executeScript(
          'document.body.textContent=${jsonEncode(text)};true;',
        );
        final document = HuanmengApiSession.decodeProbe(
          await web.executeScript(HuanmengApiSession.documentProbe),
        );
        expect(document['challenge'], isFalse);
        expect(document['rateLimited'], isFalse);
        expect(
          HuanmengApiSession.decodeEnvelope(document['text'])['data'],
          isA<Map>(),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: iosGlassTheme(Brightness.light),
            home: Scaffold(
              body: Column(
                children: [
                  AppleGlassSegments(
                    index: 2,
                    lastLabel: '全部',
                    thirdLabel: '完结',
                    onSelect: (_) {},
                  ),
                  const Text('幻梦：离线 WebKit 协议检查通过'),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await binding.takeScreenshot('huanmeng-offline-webkit-protocol');
        expect(tester.takeException(), isNull);
      } finally {
        await web.dispose();
      }
    },
  );
  testWidgets(
    'native JSON document picker imports original Huanmeng source and reloads',
    (tester) async {
      var saved = '';
      final registry = RuleSourceRegistry(
        read: () async => saved,
        write: (value) async => saved = value,
      );
      addTearDown(registry.dispose);
      await registry.load(builtIns: []);
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: Scaffold(
            appBar: AppBar(title: const Text('书源与账号')),
            body: SingleChildScrollView(
              child: RuleSourceManager(registry: registry),
            ),
          ),
        ),
      );
      final root = await getApplicationSupportDirectory();
      final file = File('${root.path}/ios-source-import-fixture.json');
      await file.writeAsString(huanmengSourceJson);
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      await tester.tap(find.text('本地文件'));
      await tester.pump();
      const methods = MethodChannel('methods');
      var visible = false;
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        visible =
            await methods.invokeMethod<bool>('testSourceDocumentPicker') ??
            false;
        if (visible) break;
      }
      expect(visible, isTrue);
      await Future<void>.delayed(const Duration(seconds: 2));
      await binding.takeScreenshot('ios-source-json-native-picker');
      expect(
        await methods.invokeMethod<bool>('testSourceDocumentPicker', {
          'selectPath': file.path,
        }),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('确认导入书源'), findsOneWidget);
      expect(find.text('幻梦轻小说'), findsOneWidget);
      expect(saved, isEmpty);
      await binding.takeScreenshot('ios-source-import-preview');
      await tester.ensureVisible(find.text('导入所选书源'));
      await tester.tap(find.text('导入所选书源'));
      await tester.pumpAndSettle();
      expect(registry.entries.single.definition.name, '幻梦轻小说');
      final reload = RuleSourceRegistry(
        read: () async => saved,
        write: (_) async {},
      );
      addTearDown(reload.dispose);
      await reload.load(builtIns: []);
      expect(
        reload.entries.single.definition.importKey,
        'https://www.huanmengacg.com',
      );
      expect(
        reload.entries.single.definition.catalogRule?.next?.legado,
        isNotNull,
      );
      await binding.takeScreenshot('ios-source-installed');
      final canceled = pickSourceImportFile();
      visible = false;
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        visible =
            await methods.invokeMethod<bool>('testSourceDocumentPicker') ??
            false;
        if (visible) break;
      }
      expect(visible, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await methods.invokeMethod<bool>('testSourceDocumentPicker', {
        'cancel': true,
      });
      expect(await canceled, isNull);
      expect(reload.entries, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('native glass and theme overlay survive a real theme change', (
    tester,
  ) async {
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<Brightness>(
        valueListenable: brightness,
        builder:
            (_, value, __) => MaterialApp(
              themeAnimationDuration: Duration.zero,
              theme: iosGlassTheme(value),
              home: Scaffold(
                backgroundColor:
                    value == Brightness.light ? Colors.white : Colors.black,
                body: Column(
                  children: [
                    AppleGlassToolbar(
                      source: '哔哩轻小说',
                      onSource: () {},
                      onSearch: () {},
                      onTheme: () {},
                    ),
                    const AppleGlassCard(
                      child: ListTile(
                        title: Text('主题与纸张'),
                        subtitle: Text('原生玻璃分组'),
                      ),
                    ),
                    AppleGlassMenu(
                      label: '分类',
                      items: const [
                        {'group': '日常', 'label': '校园', 'value': 'school'},
                      ],
                      onSelect: (_) {},
                    ),
                    const Text('主题切换期间正文保留在原位'),
                  ],
                ),
                bottomNavigationBar: AppleGlassBottomBar(
                  index: 0,
                  onSelect: (_) {},
                ),
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await binding.takeScreenshot('ios-native-glass');
    const reveal = MethodChannel('litetale/theme_reveal');
    expect(await reveal.invokeMethod<bool>('prepare'), isTrue);
    expect(await reveal.invokeMethod<bool>('status'), isTrue);
    brightness.value = Brightness.dark;
    await tester.pump();
    expect(
      await reveal.invokeMethod<bool>('status'),
      isTrue,
      reason: 'Changing the theme must preserve the frozen overlay',
    );
    await reveal.invokeMethod<void>('animate');
    final details = await reveal.invokeMapMethod<String, dynamic>('details');
    expect(details!['visible'], isTrue);
    if (details['reducedMotion'] != true) {
      expect(details['maskWidth'], details['width']);
      expect(details['animating'], isTrue);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (details['reducedMotion'] != true) {
      expect(await reveal.invokeMethod<bool>('freezeForCapture'), isTrue);
    }
    final middle = await binding.takeScreenshot('ios-theme-mid');
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(middle));
    final frame = await codec.getNextFrame();
    final rgba = (await frame.image.toByteData())!;
    var light = 0;
    for (var i = 0; i < rgba.lengthInBytes; i += 4) {
      if (rgba.getUint8(i) > 240 &&
          rgba.getUint8(i + 1) > 240 &&
          rgba.getUint8(i + 2) > 240) {
        light++;
      }
    }
    if (details['reducedMotion'] != true) {
      expect(light / (frame.image.width * frame.image.height), greaterThan(.4));
    }
    frame.image.dispose();
    codec.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(await reveal.invokeMethod<bool>('status'), isFalse);
    await binding.takeScreenshot('ios-theme-dark');
  });

  testWidgets('startup shows the book and ordinary themed spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: iosGlassTheme(Brightness.light),
        home: const AppLaunchScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await binding.takeScreenshot('ios-startup-book');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS controls and ordinary paging use system colors', (
    tester,
  ) async {
    await IosSystemColors.initialize();
    const palette = MethodChannel('litetale/apple_palette');
    final native = await palette.invokeMapMethod<String, dynamic>('colors');
    expect(
      IosSystemColors.color('ios-blue', Brightness.light).toARGB32(),
      (native!['light'] as Map)['ios-blue'],
    );
    final controller = ReaderPageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: iosGlassTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              const AppleGlassCard(child: ListTile(title: Text('系统颜色与玻璃卡片'))),
              AppButton.filledIcon(
                onPressed: () {},
                icon: const Icon(Icons.book),
                label: const Text('继续阅读'),
              ),
              AppSwitchListTile(
                title: const Text('音量键翻页'),
                value: true,
                onChanged: (_) {},
              ),
              AppSlider(value: .5, onChanged: (_) {}),
              AppTextFormField(
                decoration: const InputDecoration(labelText: '用户名'),
                autofillHints: const [AutofillHints.username],
              ),
              AppleGlassFilterBar(
                labels: const ['更新', '发布', '总访问', '总推荐', '总收藏', '月访问'],
                index: 2,
                onSelect: (_) {},
              ),
              Expanded(
                child: PageView(
                  controller: controller,
                  children: const [
                    Center(child: Text('普通分页：第一页')),
                    Center(child: Text('普通分页：第二页')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // UIKit platform views finish composition after Flutter's last scheduled frame.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 50));
    final bar = tester.getRect(find.byType(AppleGlassFilterBar));
    final screen = tester.getSize(find.byType(Scaffold));
    final screenshot = await binding.takeScreenshot('ios-unified-controls');
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(screenshot),
    );
    final frame = await codec.getNextFrame();
    final rgba =
        (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
    final scale = frame.image.width / screen.width;
    var labelPixels = 0;
    for (
      var y = ((bar.top + 8) * scale).round();
      y < ((bar.bottom - 8) * scale).round();
      y++
    ) {
      for (
        var x = ((bar.left + 16) * scale).round();
        x < ((bar.right - 16) * scale).round();
        x++
      ) {
        final offset = (y * frame.image.width + x) * 4;
        if (rgba[offset] < 100 &&
            rgba[offset + 1] < 100 &&
            rgba[offset + 2] < 100) {
          labelPixels++;
        }
      }
    }
    frame.image.dispose();
    codec.dispose();
    expect(
      labelPixels,
      greaterThan(50),
      reason:
          'UIKit selector text must be visible in the actual composited frame',
    );
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(AppleGlassFilterBar),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.drag(find.byType(AppleGlassFilterBar), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(
      scroll.position.pixels,
      greaterThan(0),
      reason: 'Native selector must let horizontal pans scroll the strip',
    );
    await controller.turn(1);
    await tester.pumpAndSettle();
    expect(controller.page, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system EPUB handoff presents and cancellation keeps the original',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: const Scaffold(body: Center(child: Text('在系统菜单中选择图书'))),
        ),
      );
      await tester.pumpAndSettle();
      final root = await getTemporaryDirectory();
      final file = File('${root.path}/litetale-books-acceptance.epub');
      final bytes = buildEpubFixture();
      await file.writeAsBytes(bytes);
      const books = MethodChannel('litetale/apple_books');
      final opening = books.invokeMapMethod<String, dynamic>('open', {
        'path': file.path,
        'title': '原书样式测试',
      });
      var visible = false;
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        visible = await books.invokeMethod<bool>('status') ?? false;
        if (visible) break;
      }
      expect(visible, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await binding.takeScreenshot('ios-books-handoff');
      await books.invokeMethod<void>('cancel');
      expect((await opening)?['completed'], isFalse);
      expect(await file.readAsBytes(), bytes);
      await file.delete();
    },
  );
}
