import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;

import 'epub_models.dart';
import 'epub_browser_font.dart';

/// Inert original markup, not a translation of CSS into Flutter text styles.
/// Resources are content addressed and served only by the offline renderer.
class EpubPublicationDocument {
  const EpubPublicationDocument(this.html, this.resources, this.fixedLayout);
  final String html;
  final Map<String, Uint8List> resources;
  final bool fixedLayout;
}

class EpubPublicationBuilder {
  EpubPublicationBuilder({required this.resolve, required this.read});
  final String? Function(String base, String href) resolve;
  final Uint8List? Function(String path) read;
  final resources = <String, Uint8List>{};
  final _urls = <String, String?>{};
  int _resourceSize = 0, _cssSize = 0;

  String? resource(String base, String href) {
    if (href.startsWith('#')) return href;
    const prefix = 'https://litetale-epub.invalid/resource/';
    if (href.startsWith(prefix) &&
        resources.containsKey(href.substring(prefix.length))) {
      return href;
    }
    final target = resolve(base, href);
    if (target == null) return null;
    if (_urls.containsKey(target)) return _urls[target];
    var bytes = read(target);
    if (bytes == null ||
        bytes.length > 20 * 1024 * 1024 ||
        _resourceSize + bytes.length > 40 * 1024 * 1024) {
      return _urls[target] = null;
    }
    final extension = target.split('.').last.toLowerCase();
    if (const {'ttf', 'otf'}.contains(extension)) {
      bytes = epubBrowserFontBytes(bytes);
    }
    if (!const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
      'avif',
      'ttf',
      'otf',
      'woff',
      'woff2',
    }.contains(extension)) {
      return _urls[target] = null;
    }
    final name = '${sha256.convert(bytes)}.$extension';
    if (!resources.containsKey(name)) {
      resources[name] = bytes;
      _resourceSize += bytes.length;
    }
    return _urls[target] = 'https://litetale-epub.invalid/resource/$name';
  }

  String urls(String text, String base) => text.replaceAllMapped(
    RegExp(
      r'''url\s*\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)''',
      caseSensitive: false,
    ),
    (m) {
      final url = resource(base, (m[1] ?? m[2] ?? m[3] ?? '').trim());
      return url == null ? 'url("data:,")' : 'url("$url")';
    },
  );

  String sheet(String source, String base, Set<String> chain) {
    _cssSize += utf8.encode(source).length;
    if (_cssSize > 4 * 1024 * 1024 || chain.length >= 8) {
      throw const EpubImportException('本章 CSS 资源过大');
    }
    source = source.replaceAllMapped(
      RegExp(
        r'''@import\s+(?:url\(\s*)?["']([^"']+)["']\s*\)?\s*([^;]*);''',
        caseSensitive: false,
      ),
      (m) {
        final path = resolve(base, m[1]!);
        if (path == null || chain.contains(path)) return '';
        final data = read(path);
        if (data == null || data.length > 1024 * 1024) return '';
        final nested = sheet(utf8.decode(data, allowMalformed: true), path, {
          ...chain,
          path,
        });
        final media = m[2]!.trim();
        return media.isEmpty ? nested : '@media $media {$nested}';
      },
    );
    return urls(source, base);
  }

  EpubPublicationDocument build(
    dom.Document input,
    String path, {
    required bool fixedLayout,
    String startFragment = '',
    String endFragment = '',
  }) {
    final body = input.body;
    if (body == null) throw const EpubImportException('本章正文结构无效');
    final order = <dom.Node, int>{};
    void index(dom.Node node) {
      order[node] = order.length;
      for (final child in node.nodes) {
        index(child);
      }
    }

    index(body);
    int boundary(String id, int fallback) {
      if (id.isEmpty) return fallback;
      for (final node in order.keys) {
        if (node is dom.Element &&
            (node.id == id || node.attributes['name'] == id)) {
          return order[node]!;
        }
      }
      return fallback;
    }

    final low = boundary(startFragment, 0),
        high = boundary(endFragment, order.length);
    const drop = {
      'script',
      'iframe',
      'frame',
      'frameset',
      'object',
      'embed',
      'applet',
      'base',
      'link',
      'style',
      'meta',
      'form',
      'input',
      'button',
      'textarea',
      'select',
      'audio',
      'video',
      'animate',
      'animatetransform',
      'animatemotion',
      'set',
    };
    dom.Node? clean(dom.Node node) {
      final n = order[node]!;
      if (n >= high) return null;
      if (node is dom.Text) return n < low ? null : dom.Text(node.data);
      if (node is! dom.Element ||
          drop.contains(node.localName?.toLowerCase())) {
        return null;
      }
      final result = dom.Element.tag(node.localName ?? 'div');
      for (final entry in node.attributes.entries) {
        final key = entry.key.toString(), lower = key.toLowerCase();
        if (lower.startsWith('on') ||
            const {
              'src',
              'srcset',
              'href',
              'xlink:href',
              'action',
              'formaction',
              'integrity',
              'nonce',
            }.contains(lower)) {
          continue;
        }
        if (entry.value.length > 65536) continue;
        result.attributes[key] =
            lower == 'style' ? urls(entry.value, path) : entry.value;
      }
      final tag = node.localName?.toLowerCase();
      String? attribute(String name) =>
          node.attributes.entries
              .where((entry) => entry.key.toString() == name)
              .firstOrNull
              ?.value;
      if (tag == 'img' || tag == 'image') {
        final src =
            node.attributes['src'] ??
            node.attributes['href'] ??
            attribute('xlink:href') ??
            '';
        final url = resource(path, src);
        if (url != null) result.attributes[tag == 'img' ? 'src' : 'href'] = url;
      } else if (tag == 'use') {
        final href = node.attributes['href'] ?? attribute('xlink:href') ?? '';
        if (href.startsWith('#')) result.attributes['href'] = href;
      }
      for (final child in node.nodes) {
        final copy = clean(child);
        if (copy != null) result.append(copy);
      }
      if (n < low && result.nodes.isEmpty) return null;
      return result;
    }

    final doc = dom.Document.html('');
    for (final name in ['lang', 'dir', 'xml:lang', 'class', 'id']) {
      final value = input.documentElement?.attributes[name];
      if (value != null) doc.documentElement!.attributes[name] = value;
    }
    doc.head!.append(dom.Element.tag('meta')..attributes['charset'] = 'utf-8');
    doc.head!.append(
      dom.Element.tag('meta')
        ..attributes.addAll({
          'http-equiv': 'Content-Security-Policy',
          'content':
              "default-src 'none'; img-src https://litetale-epub.invalid data:; font-src https://litetale-epub.invalid; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'",
        }),
    );
    for (final meta in input.querySelectorAll('meta[name="viewport"]')) {
      doc.head!.append(meta.clone(true));
    }
    for (final element in input.querySelectorAll('style, link')) {
      var css = '';
      if (element.localName == 'style') {
        css = sheet(element.text, path, {});
      } else if ((element.attributes['rel'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .contains('stylesheet')) {
        final target = resolve(path, element.attributes['href'] ?? '');
        final data = target == null ? null : read(target);
        if (target != null && data != null && data.length <= 1024 * 1024) {
          css = sheet(utf8.decode(data, allowMalformed: true), target, {
            target,
          });
        }
      }
      if (css.isNotEmpty) {
        doc.head!.append(
          dom.Element.tag('style')..text = css.replaceAll('<', r'\3c '),
        );
      }
    }
    final cleanBody = clean(body) as dom.Element?;
    if (cleanBody != null) {
      doc.body!.attributes.addAll(cleanBody.attributes);
      doc.body!.nodes.addAll(cleanBody.nodes.toList());
    }
    final html = '<!doctype html>${doc.outerHtml}';
    if (utf8.encode(html).length > 12 * 1024 * 1024) {
      throw const EpubImportException('本章页面结构过大');
    }
    return EpubPublicationDocument(html, resources, fixedLayout);
  }
}
