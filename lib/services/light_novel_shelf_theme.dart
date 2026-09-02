import 'dart:convert';

import 'package:flutter/material.dart';

/// A presentation-only skin for the embedded, independently hosted catalogue.
/// It never reads account state or changes the site's data and event handlers.
class LightNovelShelfTheme {
  static const origin = 'https://www.lightnovel.app';
  static const fontHost = 'novels-assets.invalid';

  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).substring(2)}';

  static String css(ThemeData theme) {
    final colors = theme.colorScheme;
    return '''
@font-face {
  font-family: NovelsShelfUI;
  src: url("https://$fontHost/LXGWNeoZhiSongPlus.ttf") format("truetype");
  font-display: swap;
}
html.novels-shelf {
  --novels-bg: ${_hex(theme.scaffoldBackgroundColor)};
  --novels-surface: ${_hex(colors.surfaceContainerLow)};
  --novels-raised: ${_hex(colors.surfaceContainer)};
  --novels-text: ${_hex(colors.onSurface)};
  --novels-muted: ${_hex(colors.onSurfaceVariant)};
  --novels-border: ${_hex(colors.outlineVariant)};
  --novels-primary-container: ${_hex(colors.primaryContainer)};
  --novels-on-primary-container: ${_hex(colors.onPrimaryContainer)};
  --novels-on-primary: ${_hex(colors.onPrimary)};
  --novels-on-secondary: ${_hex(colors.onSecondary)};
  --q-primary: ${_hex(colors.primary)} !important;
  --q-secondary: ${_hex(colors.secondary)} !important;
  --q-accent: ${_hex(colors.primary)} !important;
  --q-dark: ${_hex(colors.surfaceContainerLow)} !important;
  --q-dark-page: ${_hex(theme.scaffoldBackgroundColor)} !important;
  color-scheme: ${theme.brightness == Brightness.dark ? 'dark' : 'light'};
  background: var(--novels-bg);
}
.novels-shelf body {
  font-family: NovelsShelfUI, "LXGWNeoZhiSongPlus", "Microsoft YaHei", sans-serif;
  color: var(--novels-text) !important;
  background: var(--novels-bg) !important;
}
.novels-shelf :is(button, input, textarea, select) { font-family: inherit; }
.novels-shelf :is(.q-layout, .q-page-container) {
  background: var(--novels-bg) !important;
  color: var(--novels-text);
}
.novels-shelf .q-header {
  background: var(--novels-bg) !important;
  color: var(--novels-text) !important;
  border-bottom: 1px solid var(--novels-border);
}
.novels-shelf .q-header:after { box-shadow: none !important; }
.novels-shelf .q-toolbar { gap: 8px; }
.novels-shelf .q-toolbar-title { font-size: 18px; }
.novels-shelf .q-drawer {
  background: var(--novels-surface) !important;
  color: var(--novels-text) !important;
  border-color: var(--novels-border) !important;
}
.novels-shelf .q-drawer .q-item { margin: 3px 10px; border-radius: 24px; }
.novels-shelf .q-drawer .q-item--active {
  background: var(--novels-primary-container);
  color: var(--novels-on-primary-container) !important;
}
.novels-shelf .q-drawer .q-item--active .q-icon { color: inherit !important; }
.novels-shelf :is(.q-card, .q-menu) {
  background: var(--novels-surface) !important;
  color: var(--novels-text) !important;
  border-radius: 12px;
  box-shadow: none;
}
.novels-shelf .q-menu { border: 1px solid var(--novels-border); }
.novels-shelf :is(.q-item__label--caption, .q-item__section--side,
    .q-field__label, .q-field__marginal, .q-field__bottom,
    .text-grey, .text-grey-6, .text-grey-7, .text-grey-8) {
  color: var(--novels-muted) !important;
}
.novels-shelf :is(.q-field__native, .q-field__input, .q-tab) {
  color: var(--novels-text) !important;
}
.novels-shelf :is(.q-field--filled, .q-field--standout) .q-field__control {
  background: var(--novels-raised) !important;
  border-radius: 10px 10px 0 0;
}
.novels-shelf .q-field--outlined .q-field__control:before {
  border-color: var(--novels-border);
}
.novels-shelf .q-field--error :is(.q-field__label, .q-field__bottom, .q-field__marginal) {
  color: var(--q-negative) !important;
}
.novels-shelf .q-separator { background: var(--novels-border) !important; }
.novels-shelf .q-list--separator > .q-item + .q-item { border-color: var(--novels-border); }
.novels-shelf .q-btn { border-radius: 20px; text-transform: none; }
.novels-shelf .q-btn:before { box-shadow: none; }
.novels-shelf .q-btn:is(.bg-primary, .bg-accent) { color: var(--novels-on-primary) !important; }
.novels-shelf .q-btn.bg-secondary { color: var(--novels-on-secondary) !important; }
.novels-shelf :is(a, button, input, textarea):focus-visible {
  outline: 2px solid var(--q-primary);
  outline-offset: 3px;
}
.novels-shelf a:not(.q-item):not(.q-btn) { color: var(--q-primary); }
.novels-shelf .q-page:has(.novels-book-grid) {
  max-width: none !important;
  padding: clamp(12px, 1.5vw, 24px);
}
.novels-shelf .top-bar { flex-wrap: wrap; gap: 12px; }
.novels-shelf .novels-book-grid {
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 180px), 1fr)) !important;
  gap: 20px 16px !important;
}
.novels-shelf .novels-book-grid > * { min-width: 0; }
.novels-shelf .novels-book-card {
  overflow: hidden;
  background: var(--novels-surface);
  border: 1px solid var(--novels-border);
  border-radius: 8px;
  height: 100%;
}
.novels-shelf .novels-book-card .book-cover .q-card { border-radius: 0; }
.novels-shelf .novels-book-card > a { display: block; }
.novels-shelf .novels-book-card .book-name {
  font-size: 14px;
  line-height: 1.6;
  height: 3.2em;
  margin: 4px 5px;
  color: var(--novels-text);
}
.novels-shelf .novels-book-card .extra {
  margin: 0 5px 10px;
  color: var(--novels-muted);
  opacity: 1;
  gap: 6px;
}
.novels-shelf .book-info-card { border: 1px solid var(--novels-border); }
.novels-shelf .novels-book-info-grid {
  grid-template-columns: clamp(170px, 20vw, 260px) minmax(0, 1fr) !important;
  gap: 24px !important;
  align-items: start;
}
.novels-shelf .novels-book-info-grid > * { grid-column: auto !important; min-width: 0; }
.novels-shelf .book-info-header .text-subtitle1 {
  font-size: 23px;
  line-height: 1.5;
  white-space: normal;
  overflow: visible;
}
.novels-shelf .book-info-card .introduction {
  line-height: 1.85 !important;
  opacity: 1 !important;
  color: var(--novels-muted);
  padding-top: 8px;
}
.novels-shelf .book-info-card .introduction p { margin-bottom: 8px; }
.novels-shelf .book-actions { gap: 12px; flex-wrap: wrap; }
.novels-shelf .book-info-card .q-list .q-item { border-radius: 8px; min-height: 48px; }
/* Deliberately leave .read, .read-bg and .flip-* alone: the site's book
   fonts, user reading preferences, illustrations and pagination must survive. */
@media (max-width: 640px) {
  .novels-shelf .novels-book-grid {
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 130px), 1fr)) !important;
    gap: 16px 12px !important;
  }
  .novels-shelf .novels-book-info-grid { grid-template-columns: minmax(0, 1fr) !important; }
  .novels-shelf .novels-book-info-grid > :first-child { width: 180px; justify-self: center; }
  .novels-shelf .book-info-header .text-subtitle1 { font-size: 20px; }
}
''';
  }

  /// Safe to run before DOM creation, after navigation and on theme changes.
  /// Child-list observation handles Vue's lazy/kept-alive routes, without
  /// replacing nodes or observing keystrokes, account data or reader styles.
  static String script(ThemeData theme) => '''
(() => {
  if (window.top !== window || location.origin !== ${jsonEncode(origin)}) return;
  window.__novelsShelfTheme?.dispose();
  const css = ${jsonEncode(css(theme))};
  let frame = 0;
  const decorate = () => {
    frame = 0;
    if (!document.documentElement) return;
    document.documentElement.classList.add('novels-shelf');
    let style = document.getElementById('novels-shelf-theme');
    if (!style) {
      style = document.createElement('style');
      style.id = 'novels-shelf-theme';
      (document.head || document.documentElement).appendChild(style);
    }
    if (style.textContent !== css) style.textContent = css;
    document.querySelectorAll('.book-cover').forEach(cover => {
      const link = cover.parentElement;
      if (!link?.matches('a') || !link.parentElement) return;
      link.parentElement.classList.add('novels-book-card');
      for (let parent = link.parentElement.parentElement; parent; parent = parent.parentElement) {
        if (parent.style.display === 'grid') {
          parent.classList.add('novels-book-grid');
          break;
        }
      }
    });
    document.querySelectorAll('.book-info-card .book-info-header').forEach(header => {
      for (let parent = header.parentElement; parent; parent = parent.parentElement) {
        if (parent.style.display === 'grid') {
          parent.classList.add('novels-book-info-grid');
          break;
        }
      }
    });
  };
  const observer = new MutationObserver(() => {
    if (!frame) frame = requestAnimationFrame(decorate);
  });
  observer.observe(document, {childList: true, subtree: true});
  window.__novelsShelfTheme = {dispose() {
    observer.disconnect();
    if (frame) cancelAnimationFrame(frame);
  }};
  decorate();
})();
''';
}
