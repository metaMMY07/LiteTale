import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:wild/services/light_novel_shelf_theme.dart';

// Offline WebView2 regression test. The mapped host serves only our synthetic
// fixture in an isolated temporary profile: no real accounts or books touched.
// flutter test -d windows integration_test/light_novel_shelf_theme_test.dart
//   --dart-define=SHELF_FIXTURE_DIR=<absolute integration_test/fixtures path>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('embedded skin: layout, fonts, SPA updates and origin isolation', (
    tester,
  ) async {
    const fixturePath = String.fromEnvironment('SHELF_FIXTURE_DIR');
    expect(
      fixturePath,
      isNotEmpty,
      reason: 'Provide the local fixture directory',
    );
    final profile = await Directory.systemTemp.createTemp(
      'novels-shelf-ui-test-',
    );
    await WebviewController.initializeEnvironment(userDataPath: profile.path);
    final controller = WebviewController();
    await controller.initialize();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final host in ['www.lightnovel.app', 'unrelated.invalid']) {
      await controller.addVirtualHostNameMapping(
        host,
        fixturePath,
        WebviewHostResourceAccessKind.deny,
      );
    }
    final fontPath =
        Directory(
          fixturePath,
        ).parent.parent.uri.resolve('lib/assets/fonts/').toFilePath();
    await controller.addVirtualHostNameMapping(
      LightNovelShelfTheme.fontHost,
      fontPath,
      WebviewHostResourceAccessKind.allow,
    );
    final dark = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      ),
    );
    await controller.addScriptToExecuteOnDocumentCreated(
      LightNovelShelfTheme.script(dark),
    );

    Future<void> showAt(double width) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Webview(controller, width: width, height: 1000)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> waitFor(String condition) async {
      for (var i = 0; i < 100; i++) {
        if (await controller.executeScript(condition) == true) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      fail('WebView condition did not become true: $condition');
    }

    await showAt(1702);
    await controller.loadUrl('${LightNovelShelfTheme.origin}/shelf.html');
    await waitFor(
      "document.querySelectorAll('.novels-book-card').length === 24",
    );
    await controller.executeScript(
      "document.fonts.load('16px NovelsShelfUI').then(fonts => window.testFontLoaded = fonts.length > 0)",
    );
    await waitFor('window.testFontLoaded === true');

    for (final width in [1702.0, 390.0, 2560.0]) {
      await showAt(width);
      await waitFor('Math.abs(innerWidth - $width) < 2');
      final metrics =
          await controller.executeScript('''(() => {
        const grid = document.getElementById('books');
        const rect = grid.getBoundingClientRect();
        const cards = [...grid.children].map(c => c.getBoundingClientRect());
        const row = cards.filter(c => Math.abs(c.top - cards[0].top) < 1);
        return {width: cards[0].width, gap: rect.right - row.at(-1).right,
          overflow: document.documentElement.scrollWidth > innerWidth};
      })()''')
              as Map;
      expect(metrics['width'], lessThan(250));
      expect(metrics['gap'], closeTo(0, 1));
      expect(metrics['overflow'], false);
    }

    await controller.executeScript(
      "document.getElementById('catalogue').hidden=true;document.getElementById('details').hidden=false;addBook(25)",
    );
    await waitFor(
      "document.querySelectorAll('.novels-book-card').length === 25",
    );
    final detail = await controller.executeScript(
      "document.getElementById('detailGrid').children[0].getBoundingClientRect().width",
    );
    expect(detail, lessThanOrEqualTo(260));
    await controller.executeScript(LightNovelShelfTheme.script(ThemeData()));
    await controller.executeScript(LightNovelShelfTheme.script(ThemeData()));
    expect(
      await controller.executeScript(
        "document.querySelectorAll('#novels-shelf-theme').length",
      ),
      1,
    );
    expect(
      await controller.executeScript(
        "getComputedStyle(document.documentElement).colorScheme",
      ),
      'light',
    );
    expect(
      await controller.executeScript(
        "getComputedStyle(document.querySelector('.read')).fontSize",
      ),
      '23px',
    );
    expect(
      await controller.executeScript(
        "document.getElementById('loginInput').value",
      ),
      'synthetic-test-only',
    );
    await controller.executeScript(
      "document.getElementById('readButton').click()",
    );
    expect(await controller.executeScript('window.testReadClicked'), true);
    await controller.loadUrl('https://unrelated.invalid/shelf.html');
    await waitFor("!!document.getElementById('books')");
    expect(
      await controller.executeScript(
        "document.querySelector('#novels-shelf-theme') === null",
      ),
      true,
    );
    expect(
      await controller.executeScript(
        "document.documentElement.classList.contains('novels-shelf')",
      ),
      false,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
