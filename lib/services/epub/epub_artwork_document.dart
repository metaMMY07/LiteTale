import 'dart:convert';
import 'dart:typed_data';

import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as ast;
import 'package:html/dom.dart' as dom;

import 'epub_models.dart';

/// Preserve short, designed pages as artwork. Prose stays in the native,
/// user-styled text reader. Everything here is inert, book-local import data.
class EpubArtworkBuilder {
  EpubArtworkBuilder({
    required this.resolve,
    required this.readCss,
    required this.readResource,
  });
  final String? Function(String base, String href) resolve;
  final String? Function(String path) readCss;
  final Uint8List? Function(String path) readResource;
  int _bookBytes = 0, _pages = 0;

  EpubArtworkPage? build(dom.Document input, String path) {
    if (_pages >= 16 || _bookBytes >= 32 * 1024 * 1024) return null;
    final body = input.body;
    if (body == null || body.querySelectorAll('*').length > 800) return null;
    final measure = body.clone(true);
    for (final element in measure.querySelectorAll(
      _PageBuilder._drop.join(','),
    )) {
      element.remove();
    }
    if (measure.text.trim().isEmpty || measure.text.length > 3500) {
      return null;
    }
    try {
      final page = _PageBuilder(this, path, input);
      final sheets = <String>[];
      for (final element in input.querySelectorAll('link, style')) {
        if (element.localName == 'style') {
          sheets.add(page.sheet(element.text, path, {}));
        } else if ((element.attributes['rel'] ?? '')
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .contains('stylesheet')) {
          final target = resolve(path, element.attributes['href'] ?? '');
          if (target != null) sheets.add(page.linked(target, {}));
        }
      }
      // Merely having a shared float rule in the book is not sufficient.
      final role =
          '${body.attributes['epub:type'] ?? ''} '
          '${input.querySelector('title')?.text ?? ''} '
          '${path.split('/').last}';
      final titlePage = RegExp(
        r'(^|[\s/_.-])(title(?:page)?|half-title|扉页|標題|标题)([\s/_.-]|$)',
        caseSensitive: false,
      ).hasMatch(role);
      final designed =
          RegExp(
            r'(^|[\s/_.-])(title(?:page)?|half-title|frontispiece|illus\w*|'
            r'copyright|colophon|扉页|標題|标题|彩页|插画)([\s/_.-]|$)',
            caseSensitive: false,
          ).hasMatch(role) ||
          page.usedDesign ||
          input
              .querySelectorAll('[style]')
              .any(
                (element) => _PageBuilder._layoutProperty.hasMatch(
                  element.attributes['style'] ?? '',
                ),
              );
      if (!designed) return null;
      final cleanBody = page.clean(body);
      final doc = dom.Document.html('');
      doc.head!.append(
        dom.Element.tag('meta')..attributes.addAll({'charset': 'utf-8'}),
      );
      doc.head!.append(
        dom.Element.tag('meta')
          ..attributes.addAll({
            'http-equiv': 'Content-Security-Policy',
            'content':
                "default-src 'none'; img-src data:; font-src data: https://litetale-epub.invalid; "
                "style-src 'unsafe-inline'; script-src 'none'; "
                "base-uri 'none'; form-action 'none';",
          }),
      );
      doc.head!.append(
        dom.Element.tag('meta')
          ..attributes.addAll({
            'name': 'viewport',
            'content': 'width=360, initial-scale=1, maximum-scale=1',
          }),
      );
      doc.head!.append(
        dom.Element.tag('style')..text = ('html{font-size:16px;background:white;color:black;'
            'color-scheme:only light;-webkit-text-size-adjust:100%;'
            'text-size-adjust:100%;}'
            '@font-face{font-family:LiteTaleArtworkSerif;'
            'src:url("https://litetale-epub.invalid/reader-serif.ttf");}'
            'body{margin:8px;font-family:LiteTaleArtworkSerif,serif;}'
            'img{max-width:100%;}*{animation:none!important;'
            'transition:none!important;caret-color:transparent!important;}'
            '${sheets.join('\n')}'
            // Requested title-page typography, selected by page role,
            // not a particular book/class/text. Browser float/clear rules
            // calculate author placement after the font metrics change.
            '${titlePage ? '*{font-family:LiteTaleArtworkSerif,serif!important;}'
                    'html{font-size:18px!important;}'
                    'body{margin:0!important;padding:22px 2.2em 0!important;'
                    'box-sizing:border-box!important;}'
                    'body>div,body>section,body>article{'
                    'max-width:100%!important;margin-top:0!important;'
                    'box-sizing:border-box!important;}'
                    'body>div>:first-child,body>section>:first-child,'
                    'body>article>:first-child{margin-top:0!important;}'
                    'p,h1,h2,h3,h4,h5,h6,li{line-height:1.55em!important;}' : ''}').replaceAll('<', r'\3c '),
      );
      doc.body!.attributes.addAll(cleanBody.attributes);
      if (titlePage) {
        doc.body!.attributes['data-litetale-title-typography'] = 'true';
      }
      doc.body!.nodes.addAll(cleanBody.nodes.toList());
      final result = '<!doctype html>${doc.outerHtml}';
      final size = utf8.encode(result).length;
      if (size > 12 * 1024 * 1024 || _bookBytes + size > 32 * 1024 * 1024) {
        return null;
      }
      _pages++;
      _bookBytes += size;
      return EpubArtworkPage(result);
    } on Object {
      // Missing/malformed design resources never take the readable text away.
      return null;
    }
  }
}

class _PageBuilder {
  _PageBuilder(this.owner, this.path, this.input);
  final EpubArtworkBuilder owner;
  final String path;
  final dom.Document input;
  int cssBytes = 0, resourceBytes = 0;
  bool usedDesign = false;
  final Map<String, String?> resources = {};

  String linked(String target, Set<String> chain) {
    if (chain.length >= 8 || chain.contains(target)) return '';
    final source = owner.readCss(target);
    return source == null ? '' : sheet(source, target, {...chain, target});
  }

  String sheet(String source, String base, Set<String> chain) {
    cssBytes += utf8.encode(source).length;
    if (source.length > 512 * 1024 || cssBytes > 2 * 1024 * 1024) return '';
    final tree = css.parse(source);
    final imports = StringBuffer();
    for (final node in tree.topLevels) {
      if (node is ast.ImportDirective) {
        final target = owner.resolve(base, node.import);
        if (target != null && node.mediaQueries.isEmpty) {
          imports.writeln(linked(target, chain));
        }
      } else if (node is ast.RuleSet &&
          _layoutProperty.hasMatch(node.declarationGroup.span.text)) {
        for (final selector
            in node.selectorGroup?.selectors ?? <ast.Selector>[]) {
          try {
            if (input.querySelector(selector.span?.text ?? '') != null) {
              usedDesign = true;
            }
          } on Object {
            /* Unsupported selector: native text remains available. */
          }
        }
      }
    }
    source = source.replaceAll(
      RegExp(r'@import\b[^;]*;', caseSensitive: false),
      '',
    );
    return '$imports${urls(source, base)}';
  }

  String urls(String source, String base) => source
      .replaceAllMapped(
        RegExp(
          r'''url\s*\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)''',
          caseSensitive: false,
        ),
        (match) {
          final href = (match[1] ?? match[2] ?? match[3] ?? '').trim();
          final value = dataUrl(base, href);
          return value == null ? 'none' : 'url("$value")';
        },
      )
      .replaceAll(
        RegExp(r'local\s*\([^)]*\)', caseSensitive: false),
        'url("data:,")',
      );

  String? dataUrl(String base, String href) {
    final target = owner.resolve(base, href);
    if (target == null) return null;
    if (resources.containsKey(target)) return resources[target];
    final data = owner.readResource(target);
    String? mime;
    if (data != null && data.length >= 12 && data.length <= 8 * 1024 * 1024) {
      final magic = ascii.decode(data.sublist(0, 4), allowInvalid: true);
      if (magic == 'OTTO' ||
          magic == 'true' ||
          (data[0] == 0 && data[1] == 1 && data[2] == 0 && data[3] == 0)) {
        mime = magic == 'OTTO' ? 'font/otf' : 'font/ttf';
      } else if (magic == 'wOFF' || magic == 'wOF2') {
        mime = magic == 'wOFF' ? 'font/woff' : 'font/woff2';
      } else if (data[0] == 137 && magic.substring(1) == 'PNG') {
        mime = 'image/png';
      } else if (data[0] == 255 && data[1] == 216 && data[2] == 255) {
        mime = 'image/jpeg';
      } else if (magic == 'GIF8') {
        mime = 'image/gif';
      } else if (magic == 'RIFF' &&
          ascii.decode(data.sublist(8, 12), allowInvalid: true) == 'WEBP') {
        mime = 'image/webp';
      }
    }
    if (mime == null || resourceBytes + data!.length > 8 * 1024 * 1024) {
      resources[target] = null;
      return null;
    }
    resourceBytes += data.length;
    return resources[target] = 'data:$mime;base64,${base64Encode(data)}';
  }

  dom.Element clean(dom.Element input) {
    final output = dom.Element.tag(input.localName ?? 'div');
    for (final name in [
      'class',
      'id',
      'lang',
      'dir',
      'colspan',
      'rowspan',
      'width',
      'height',
      'alt',
    ]) {
      final value = input.attributes[name];
      if (value != null && value.length <= 2048) {
        output.attributes[name] = value;
      }
    }
    final style = input.attributes['style'];
    if (style != null) {
      output.attributes['style'] = urls(style, path);
      if (_layoutProperty.hasMatch(style)) usedDesign = true;
    }
    if (input.localName == 'img') {
      final data = dataUrl(path, input.attributes['src'] ?? '');
      if (data != null && data.startsWith('data:image/')) {
        output.attributes['src'] = data;
      }
    }
    for (final node in input.nodes) {
      if (node is dom.Text) {
        output.append(dom.Text(node.data));
      } else if (node is dom.Element) {
        if (_drop.contains(node.localName)) continue;
        final child = clean(node);
        if (_tags.contains(node.localName)) {
          output.append(child);
        } else {
          output.nodes.addAll(child.nodes.toList());
        }
      }
    }
    return output;
  }

  static final _layoutProperty = RegExp(
    r'(?:^|[;{\s])(?:float|(?:-webkit-)?transform|writing-mode|'
    r'background-image)\s*:|position\s*:\s*(?:absolute|fixed)',
    caseSensitive: false,
  );
  static const _drop = {
    'script',
    'style',
    'link',
    'meta',
    'base',
    'iframe',
    'frame',
    'object',
    'embed',
    'audio',
    'video',
    'source',
    'track',
    'form',
    'input',
    'button',
    'textarea',
    'select',
    'canvas',
    'svg',
    'math',
  };
  static const _tags = {
    'div',
    'p',
    'span',
    'img',
    'br',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'b',
    'strong',
    'i',
    'em',
    'u',
    's',
    'small',
    'sup',
    'sub',
    'blockquote',
    'section',
    'article',
    'header',
    'footer',
    'main',
    'aside',
    'figure',
    'figcaption',
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
    'ul',
    'ol',
    'li',
    'dl',
    'dt',
    'dd',
    'ruby',
    'rt',
    'rp',
    'pre',
    'code',
    'a',
  };
}
