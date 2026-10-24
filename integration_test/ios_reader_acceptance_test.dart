import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/curl_mesh_layer.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const pages = MethodChannel('litetale/epub_pages');
  Map<String, Object> options(bool fixed) => {
    'width': 300.0,
    'height': 400.0,
    'left': 12.0,
    'top': 20.0,
    'contentWidth': 276.0,
    'contentHeight': 360.0,
    'fontSize': 16.0,
    'lineHeight': 1.5,
    'paragraphGap': 14.0,
    'paper': '#ffffff',
    'ink': '#000000',
    'pixelRatio': 1.0,
    'fixed': fixed,
    'userFont': false,
    'direction': 'ltr',
  };
  testWidgets(
    'WebKit renders original CSS and paginates before taking a page snapshot',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.light),
          home: const Scaffold(
            body: Center(child: Text('Offline EPUB WebKit acceptance')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final caps = await pages.invokeMapMethod<String, dynamic>('capabilities');
      expect(caps!['engine'], 'webkit-foliate');
      final id = List.filled(64, 'a').join();
      final fixed = await pages.invokeMapMethod<String, dynamic>('prepare', {
        'id': id,
        'html':
            '''<!doctype html><html><head><meta name="viewport" content="width=300,height=400">
      <style>body{margin:0}#box{position:absolute;left:40px;top:50px;width:60px;height:80px;background:#ff0000}
      #title{position:absolute;left:180px;top:100px;writing-mode:vertical-rl;color:#00ff00;font-size:24px}</style>
      </head><body><div id="box"></div><div id="title">原书排版</div></body></html>''',
        'resources': <String, Uint8List>{},
        'options': options(true),
      });
      expect(fixed!['count'], 1);
      final bytes = await pages.invokeMethod<Uint8List>('capture', {
        'id': id,
        'page': 0,
      });
      final codec = await ui.instantiateImageCodec(bytes!);
      final frame = await codec.getNextFrame();
      final pixels = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      var red = 0, green = 0;
      for (var i = 0; i < pixels!.lengthInBytes; i += 4) {
        if (pixels.getUint8(i) > 210 &&
            pixels.getUint8(i + 1) < 70 &&
            pixels.getUint8(i + 2) < 70) {
          red++;
        }
        if (pixels.getUint8(i) < 70 &&
            pixels.getUint8(i + 1) > 70 &&
            pixels.getUint8(i + 1) < 190 &&
            pixels.getUint8(i + 2) < 70) {
          green++;
        }
      }
      expect(red, greaterThan(200));
      expect(green, greaterThan(30));
      frame.image.dispose();
      codec.dispose();
      final flowId = List.filled(64, 'b').join();
      final info = await pages.invokeMapMethod<String, dynamic>('prepare', {
        'id': flowId,
        'html':
            '<html><head><style>h1{text-align:center}p{text-indent:2em;line-height:1.8}</style></head><body><h1>分页验证</h1>${List.generate(35, (i) => '<p>第$i段。本段验证原书样式与连续阅读，不使用任何网络资源。</p>').join()}</body></html>',
        'resources': <String, Uint8List>{},
        'options': options(false),
      });
      expect(info!['count'], greaterThan(2));
      final first = await pages.invokeMethod<Uint8List>('capture', {
        'id': flowId,
        'page': 0,
      });
      final second = await pages.invokeMethod<Uint8List>('capture', {
        'id': flowId,
        'page': 1,
      });
      expect(first, isNot(equals(second)));
      await pages.invokeMethod<void>('close', {'all': true});
      final closed = await pages.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      expect(closed!['pool'], 0);
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
    await reveal.invokeMethod<void>('animate');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await binding.takeScreenshot('ios-theme-mid');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(await reveal.invokeMethod<bool>('status'), isFalse);
    await binding.takeScreenshot('ios-theme-dark');
  });

  testWidgets('textured page bends on the iOS GPU path', (tester) async {
    final point = ValueNotifier(const Offset(.54, .82));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurlMeshLayer(
            index: 0,
            target: 1,
            direction: 1,
            startY: .85,
            point: point,
            spread: false,
            paper: const Color(0xfff3ead8),
            pageBuilder:
                (context, index) => ColoredBox(
                  color: index == 0 ? const Color(0xfff3ead8) : Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        for (var i = 0; i < 16; i++)
                          Text(
                            '第 $i 行，文字应随着纸面弯曲。',
                            style: const TextStyle(fontSize: 19, height: 1.5),
                          ),
                      ],
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await binding.takeScreenshot('ios-textured-curl');
    expect(tester.takeException(), isNull);
  });
}
