import 'dart:io';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import '../test/support/epub_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/curl_mesh_layer.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
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
    expect(light / (frame.image.width * frame.image.height), greaterThan(.4));
    frame.image.dispose();
    codec.dispose();
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
