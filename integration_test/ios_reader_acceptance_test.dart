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
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/app_launch_screen.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/services/reader_page_controller.dart';

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
            rgba[offset + 2] < 100)
          labelPixels++;
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
