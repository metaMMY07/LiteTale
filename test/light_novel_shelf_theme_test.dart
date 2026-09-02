import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/light_novel_shelf_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    test('embedded catalogue follows the $brightness application theme', () {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: brightness,
        ),
      );
      final css = LightNovelShelfTheme.css(theme);
      expect(css, contains('color-scheme: ${brightness.name}'));
      expect(
        css,
        contains(
          theme.colorScheme.primary.toARGB32().toRadixString(16).substring(2),
        ),
      );
      expect(css, contains('NovelsShelfUI'));
      expect(css, contains('novels-book-grid'));
      expect(css, contains('novels-book-info-grid'));
    });
  }

  test('skin is restricted to the trusted top-level website', () {
    final script = LightNovelShelfTheme.script(ThemeData());
    expect(script, contains('window.top !== window'));
    expect(
      script,
      contains('location.origin !== "https://www.lightnovel.app"'),
    );
    expect(
      script.indexOf('location.origin'),
      lessThan(script.indexOf('document.')),
    );
    for (final forbidden in [
      'localStorage',
      'sessionStorage',
      'document.cookie',
      'fetch(',
      'XMLHttpRequest',
      '.innerHTML',
      'history.pushState',
      '.click(',
    ]) {
      expect(script, isNot(contains(forbidden)));
    }
  });

  test(
    'repeated installs disconnect old observers and preserve reader rules',
    () {
      final script = LightNovelShelfTheme.script(ThemeData());
      expect(script, contains('window.__novelsShelfTheme?.dispose()'));
      expect(script, contains('observer.disconnect()'));
      expect(script, contains('style.textContent !== css'));
      expect(script, isNot(contains('attributes: true')));
      final css = LightNovelShelfTheme.css(ThemeData());
      expect(css, isNot(contains('.novels-shelf .read {')));
      expect(css, isNot(contains('.novels-shelf .read-bg {')));
      expect(css, contains('.q-field--error'));
    },
  );
}
