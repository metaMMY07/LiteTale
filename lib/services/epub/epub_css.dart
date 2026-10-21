import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as ast;
import 'package:html/dom.dart' as dom;

import '../../models/reader_document.dart';

/// Bounded, offline CSS cascade for the native reader's supported style subset.
/// Reader fonts/base paper remain user controlled. Explicit book accents and
/// bounded boxes are preserved; positioning and active content are excluded.
class EpubCssLimits {
  const EpubCssLimits({
    this.maxSheetBytes = 512 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024,
    this.maxImportDepth = 8,
    this.maxRules = 6000,
    this.maxDeclarations = 24000,
    this.maxMatches = 1500000,
  });
  final int maxSheetBytes, maxTotalBytes, maxImportDepth;
  final int maxRules, maxDeclarations, maxMatches;
}

class EpubComputedStyle {
  const EpubComputedStyle({
    this.inline = const ReaderInlineStyle(),
    this.block = const ReaderBlockStyle(),
    this.display = 'inline',
    this.hidden = false,
    this.preformatted = false,
    this.lineHeightFactor,
    this.lineHeightLength,
  });
  final ReaderInlineStyle inline;
  final ReaderBlockStyle block;
  final String display;
  final bool hidden, preformatted;
  // A unitless line-height inherits as a multiplier, while a length inherits
  // its computed size. Keeping both prevents a child font-size changing CSS
  // length-based line spacing accidentally.
  final double? lineHeightFactor;
  final ReaderLength? lineHeightLength;
  bool get isBlock => display == 'block';
}

/// Shared only during one book conversion. EPUBs usually reuse the same CSS
/// across hundreds of spine documents, so retain bounded parsed syntax trees.
class EpubCssSheetCache {
  final _sheets = <String, (int, ast.StyleSheet)>{};
  var _bytes = 0;
  ast.StyleSheet parse(String source) {
    final encoded = utf8.encode(source);
    final key = sha256.convert(encoded).toString();
    final cached = _sheets.remove(key);
    if (cached != null) {
      _sheets[key] = cached;
      return cached.$2;
    }
    final messages = <css.Message>[];
    final tree = css.parse(_rewriteAttributeFlags(source), errors: messages);
    while (_sheets.isNotEmpty &&
        (_bytes + encoded.length > 2 * 1024 * 1024 || _sheets.length >= 32)) {
      final removed = _sheets.remove(_sheets.keys.first)!;
      _bytes -= removed.$1;
    }
    if (encoded.length <= 2 * 1024 * 1024) {
      _sheets[key] = (encoded.length, tree);
      _bytes += encoded.length;
    }
    return tree;
  }
}

class EpubCssCascade {
  EpubCssCascade.fromDocument(
    dom.Document document,
    String documentPath, {
    required String? Function(String path) readLocalCss,
    required String? Function(String base, String href) resolveLocalPath,
    void Function(String message)? onWarning,
    EpubCssSheetCache? sheetCache,
    this.limits = const EpubCssLimits(),
    this.dark = false,
  }) : _read = readLocalCss,
       _resolve = resolveLocalPath,
       _warn = onWarning,
       _sheets = sheetCache ?? EpubCssSheetCache() {
    _remainingMatches = limits.maxMatches;
    for (final element in document.querySelectorAll('link, style')) {
      if (!_mediaTextApplies(element.attributes['media'] ?? '', dark: dark)) {
        continue;
      }
      if (element.localName == 'style') {
        _sheet(element.text, documentPath, <String>{}, 0);
      } else if ((element.attributes['rel'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .contains('stylesheet')) {
        final path = _resolve(documentPath, element.attributes['href'] ?? '');
        if (path == null) {
          _warning('EPUB 的外部网络样式已忽略，阅读无需联网。');
        } else {
          _linked(path, <String>{}, 0);
        }
      }
    }
  }

  final EpubCssLimits limits;
  final bool dark;
  final String? Function(String path) _read;
  final String? Function(String base, String href) _resolve;
  final void Function(String message)? _warn;
  final EpubCssSheetCache _sheets;
  final _indexed = <String, List<_Rule>>{};
  final _cache = <dom.Element, EpubComputedStyle>{};
  final _firstLetters = <dom.Element, ReaderInlineStyle?>{};
  final _ordinals = <dom.Element, int>{};
  final _warned = <String>{};
  var _totalBytes = 0, _ruleCount = 0, _declarationCount = 0, _order = 0;
  var _remainingMatches = 0;
  double _rootScale = 1;

  void _warning(String message) {
    if (_warned.add(message)) _warn?.call(message);
  }

  void _linked(String path, Set<String> chain, int depth) {
    if (depth > limits.maxImportDepth || chain.contains(path)) {
      _warning('部分 CSS 导入存在循环或层级过深，已保留可读取的样式。');
      return;
    }
    try {
      final source = _read(path);
      if (source == null) {
        _warning('部分本地 CSS 文件缺失，已使用其余样式。');
        return;
      }
      _sheet(source, path, {...chain, path}, depth);
    } on Object {
      _warning('部分本地 CSS 文件无法读取，已使用其余样式。');
    }
  }

  void _sheet(String source, String path, Set<String> chain, int depth) {
    if (source.length > limits.maxSheetBytes) {
      _warning('部分 CSS 文件过大，已使用其余样式。');
      return;
    }
    final byteCount = utf8.encode(source).length;
    if (byteCount > limits.maxSheetBytes ||
        _totalBytes + byteCount > limits.maxTotalBytes) {
      _warning('EPUB 样式总量过大，已保留预算内的样式。');
      return;
    }
    _totalBytes += byteCount;
    try {
      final tree = _sheets.parse(source);
      _nodes(tree.topLevels, path, chain, depth);
    } on Object {
      _warning('部分 CSS 格式不完整，已使用其余样式。');
    }
  }

  void _nodes(
    List<ast.TreeNode> nodes,
    String path,
    Set<String> chain,
    int depth,
  ) {
    var pastImports = false;
    for (final node in nodes) {
      if (node is ast.ImportDirective) {
        if (pastImports || !_mediaApplies(node.mediaQueries, dark: dark)) {
          continue;
        }
        final target = _resolve(path, node.import);
        if (target == null) {
          _warning('EPUB 的外部网络样式已忽略，阅读无需联网。');
        } else {
          _linked(target, chain, depth + 1);
        }
      } else if (node is ast.RuleSet) {
        pastImports = true;
        if (_ruleCount >= limits.maxRules) {
          _warning('EPUB 样式规则过多，已保留预算内的样式。');
          return;
        }
        final declarations = _declarations(node.declarationGroup);
        if (declarations.isEmpty) continue;
        for (final selectorNode
            in node.selectorGroup?.selectors ?? <ast.Selector>[]) {
          if (_ruleCount >= limits.maxRules) break;
          final authored = selectorNode.span?.text ?? '';
          final firstLetter =
              authored.endsWith('::first-letter') ||
              authored.endsWith(':first-letter');
          final selector = _Selector.parse(
            authored.replaceFirst(RegExp(r'::?first-letter$'), ''),
          );
          if (selector == null) continue;
          final rule = _Rule(
            selector,
            declarations,
            _order++,
            firstLetter: firstLetter,
          );
          _indexed.putIfAbsent(selector.indexKey, () => []).add(rule);
          _ruleCount++;
        }
      } else if (node is ast.MediaDirective) {
        pastImports = true;
        if (_mediaApplies(node.mediaQueries, dark: dark) &&
            depth < limits.maxImportDepth) {
          _nodes(node.rules, path, chain, depth + 1);
        }
      }
      // @font-face, @keyframes, @page, @supports and script-like properties are
      // deliberately not evaluated by this native text layout engine.
    }
  }

  List<_Declaration> _declarations(ast.DeclarationGroup group) {
    final result = <_Declaration>[];
    for (final declaration in group.declarations.whereType<ast.Declaration>()) {
      if (_declarationCount >= limits.maxDeclarations) {
        _warning('EPUB 样式声明过多，已保留预算内的样式。');
        break;
      }
      _declarationCount++;
      final property = declaration.property.toLowerCase();
      // csslib's expression spans omit unit suffixes ("2em" becomes "2").
      // Declaration spans retain the authored value and are already delimited
      // by its real CSS parser, including quoted semicolons and comments.
      final raw = declaration.span.text;
      final colon = raw.indexOf(':');
      if (colon < 0) continue;
      final value =
          raw
              .substring(colon + 1)
              .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
              .replaceFirst(
                RegExp(r'!\s*important\s*;?\s*$', caseSensitive: false),
                '',
              )
              .replaceFirst(RegExp(r';\s*$'), '')
              .trim();
      if (value.isEmpty || value.length > 1024) continue;
      final expanded = _expand(property, value);
      if (expanded.entries.any(
        (entry) =>
            _supported.contains(entry.key) &&
            !_validValue(entry.key, entry.value),
      )) {
        continue;
      }
      for (final entry in expanded.entries) {
        if (_supported.contains(entry.key) &&
            _validValue(entry.key, entry.value)) {
          result.add(
            _Declaration(entry.key, entry.value, declaration.important),
          );
        }
      }
    }
    return result;
  }

  List<_Declaration> _inlineDeclarations(String source) {
    if (source.length > 8192) return const [];
    try {
      final messages = <css.Message>[];
      final tree = css.parse('x{$source}', errors: messages);
      final node = tree.topLevels.whereType<ast.RuleSet>().firstOrNull;
      return node == null ? const [] : _declarations(node.declarationGroup);
    } on Object {
      return const [];
    }
  }

  EpubComputedStyle styleFor(dom.Element element) {
    final cached = _cache[element];
    if (cached != null) return cached;
    final parent =
        element.parent is dom.Element
            ? styleFor(element.parent as dom.Element)
            : const EpubComputedStyle();
    final winners = <String, _Winner>{};
    if (_remainingMatches > 0) {
      final candidates = <_Rule>{
        ...?_indexed['*'],
        ...?_indexed['t:${element.localName}'],
        if (element.id.isNotEmpty) ...?_indexed['i:${element.id}'],
        for (final name in element.classes) ...?_indexed['c:$name'],
      };
      for (final rule in candidates) {
        if (rule.firstLetter) continue;
        if (!_budget()) break;
        if (!rule.selector.matches(element, _budget, _ordinal)) continue;
        for (var i = 0; i < rule.declarations.length; i++) {
          final declaration = rule.declarations[i];
          final winner = _Winner(
            declaration,
            rule.selector.specificity,
            rule.order,
            i,
            false,
          );
          final previous = winners[declaration.property];
          if (previous == null || winner.compareTo(previous) >= 0) {
            winners[declaration.property] = winner;
          }
        }
      }
      final inline = _inlineDeclarations(element.attributes['style'] ?? '');
      for (var i = 0; i < inline.length; i++) {
        final declaration = inline[i];
        final winner = _Winner(declaration, const [0, 0, 0], _order, i, true);
        final previous = winners[declaration.property];
        if (previous == null || winner.compareTo(previous) >= 0) {
          winners[declaration.property] = winner;
        }
      }
    }
    final values = {
      for (final entry in winners.entries)
        entry.key: entry.value.declaration.value,
    };
    final style = _compute(element, parent, values);
    _cache[element] = style;
    if (element.localName == 'html') _rootScale = style.inline.scale;
    return style;
  }

  bool _budget() {
    if (_remainingMatches-- > 0) return true;
    _warning('EPUB 样式匹配过于复杂，后续文字使用继承样式。');
    return false;
  }

  int _ordinal(dom.Element element) {
    final cached = _ordinals[element];
    if (cached != null) return cached;
    final parent = element.parent;
    if (parent == null) return 0;
    var index = 0;
    for (final child in parent.children) {
      if (!_budget()) break;
      _ordinals[child] = ++index;
    }
    return _ordinals[element] ?? 0;
  }

  ReaderInlineStyle? firstLetterStyleFor(dom.Element element) {
    if (_firstLetters.containsKey(element)) return _firstLetters[element];
    final candidates = <_Rule>{
      ...?_indexed['*'],
      ...?_indexed['t:${element.localName}'],
      if (element.id.isNotEmpty) ...?_indexed['i:${element.id}'],
      for (final name in element.classes) ...?_indexed['c:$name'],
    };
    final winners = <String, _Winner>{};
    for (final r in candidates) {
      if (!r.firstLetter || !r.selector.matches(element, _budget, _ordinal)) {
        continue;
      }
      for (var i = 0; i < r.declarations.length; i++) {
        final d = r.declarations[i];
        final w = _Winner(d, r.selector.specificity, r.order, i, false);
        if (winners[d.property] == null ||
            w.compareTo(winners[d.property]!) >= 0) {
          winners[d.property] = w;
        }
      }
    }
    final result =
        winners.isEmpty
            ? null
            : _compute(element, styleFor(element), {
              for (final e in winners.entries) e.key: e.value.declaration.value,
            }).inline;
    _firstLetters[element] = result;
    return result;
  }

  EpubComputedStyle _compute(
    dom.Element element,
    EpubComputedStyle parent,
    Map<String, String> values,
  ) {
    final tag = element.localName ?? '';
    final inherited = parent.inline;
    String? value(String name, {bool inherits = false}) {
      final v = values[name]?.trim().toLowerCase();
      if (v == 'unset') return inherits ? 'inherit' : 'initial';
      if (v == 'revert' || v == 'revert-layer') return null;
      return v;
    }

    var scale = inherited.scale;
    if (const {
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'small',
      'big',
      'sub',
      'sup',
    }.contains(tag)) {
      scale *=
          const {
            'h1': 2.0,
            'h2': 1.5,
            'h3': 1.17,
            'h4': 1.0,
            'h5': .83,
            'h6': .67,
            'small': .8333,
            'big': 1.2,
            'sub': .75,
            'sup': .75,
          }[tag]!;
    }
    final fontSize = value('font-size', inherits: true);
    if (fontSize != null) {
      scale =
          fontSize == 'inherit'
              ? inherited.scale
              : fontSize == 'initial'
              ? 1
              : _fontSize(fontSize, inherited.scale, _rootScale) ?? scale;
    }
    scale = scale.clamp(.5, 3).toDouble();
    var bold =
        inherited.bold ||
        const {
          'b',
          'strong',
          'th',
          'h1',
          'h2',
          'h3',
          'h4',
          'h5',
          'h6',
        }.contains(tag);
    final weight = value('font-weight', inherits: true);
    if (weight != null) {
      bold =
          weight == 'inherit'
              ? inherited.bold
              : weight == 'bold' ||
                  weight == 'bolder' ||
                  (double.tryParse(weight) ?? 0) >= 600;
    }
    var italic =
        inherited.italic ||
        const {'i', 'em', 'cite', 'dfn', 'var'}.contains(tag);
    final fontStyle = value('font-style', inherits: true);
    if (fontStyle != null) {
      italic =
          fontStyle == 'inherit'
              ? inherited.italic
              : fontStyle == 'italic' || fontStyle.startsWith('oblique');
    }
    var ownUnderline = const {'u', 'ins'}.contains(tag);
    var ownStrike = const {'s', 'strike', 'del'}.contains(tag);
    final decoration =
        value('text-decoration-line') ?? value('text-decoration');
    if (decoration != null) {
      ownUnderline =
          decoration == 'inherit'
              ? inherited.underline
              : decoration.split(RegExp(r'\s+')).contains('underline');
      ownStrike =
          decoration == 'inherit'
              ? inherited.strike
              : decoration.split(RegExp(r'\s+')).contains('line-through');
    }
    var letterSpacing = inherited.letterSpacing;
    final spacing = value('letter-spacing', inherits: true);
    if (spacing != null && spacing != 'inherit') {
      letterSpacing =
          spacing == 'normal' || spacing == 'initial'
              ? const ReaderLength()
              : _length(spacing, scale, _rootScale) ?? letterSpacing;
    }
    var align = parent.block.align;
    final alignment = value('text-align', inherits: true);
    if (alignment != null && alignment != 'inherit') {
      if (alignment == 'initial') {
        align = 'start';
      } else if (const {
        'start',
        'left',
        'center',
        'right',
        'end',
        'justify',
      }.contains(alignment)) {
        align = alignment;
      }
    }
    var indent = parent.block.indent;
    final indentation = value('text-indent', inherits: true);
    if (indentation != null && indentation != 'inherit') {
      indent =
          indentation == 'initial'
              ? const ReaderLength()
              : _length(indentation, scale, _rootScale) ?? indent;
    }
    ReaderLength margin(String side, ReaderLength parentValue) {
      final length = value('margin-$side');
      if (length == 'inherit') return parentValue;
      if (length == null || length == 'initial' || length == 'auto') {
        return const ReaderLength();
      }
      return _length(length, scale, _rootScale, relativeToWidth: true) ??
          const ReaderLength();
    }

    var lineFactor = parent.lineHeightFactor;
    var lineLength = parent.lineHeightLength;
    final line = value('line-height', inherits: true);
    if (line != null && line != 'inherit') {
      if (line == 'normal' || line == 'initial') {
        lineFactor = null;
        lineLength = null;
      } else {
        final number = double.tryParse(line);
        if (number != null && number > 0) {
          lineFactor = number.clamp(.8, 4).toDouble();
          lineLength = null;
        } else {
          final length = _length(line, scale, _rootScale, percent: true);
          if (length != null) {
            lineLength = length;
            lineFactor = null;
          }
        }
      }
    }
    final lineHeight =
        lineFactor ??
        (lineLength == null
            ? null
            : ((lineLength.em + lineLength.px / 16) / scale)
                .clamp(.8, 4)
                .toDouble());
    bool pageBreak(String name) {
      final page = value(name);
      if (page == 'inherit') {
        return name == 'break-before'
            ? parent.block.breakBefore
            : parent.block.breakAfter;
      }
      return const {
        'always',
        'page',
        'left',
        'right',
        'recto',
        'verso',
      }.contains(page);
    }

    final inside = value('break-inside');
    final keep =
        inside == 'inherit'
            ? parent.block.keepTogether
            : const {'avoid', 'avoid-page'}.contains(inside);
    var display = _blockTags.contains(tag) ? 'block' : 'inline';
    final displayValue = value('display');
    if (displayValue == 'none') display = 'none';
    if (displayValue == 'inline' ||
        displayValue == 'contents' ||
        displayValue == 'initial') {
      display = 'inline';
    }
    if (const {
      'block',
      'list-item',
      'table',
      'table-row',
      'flex',
      'grid',
    }.contains(displayValue)) {
      display = 'block';
    }
    final whiteSpace = value('white-space', inherits: true);
    final pre =
        whiteSpace == null || whiteSpace == 'inherit'
            ? parent.preformatted || tag == 'pre'
            : const {'pre', 'pre-wrap', 'break-spaces'}.contains(whiteSpace);
    final isRoot = tag == 'body' || tag == 'html';
    int? colorValue(String name, int? inheritedValue) {
      final raw = value(name, inherits: name == 'color');
      if (raw == 'initial') return null;
      if (raw == null || raw == 'inherit' || raw == 'currentcolor') {
        return inheritedValue;
      }
      return parseEpubColor(raw) ?? inheritedValue;
    }

    ReaderLength padding(String side) =>
        _length(
          value('padding-$side') ?? '0',
          scale,
          _rootScale,
          relativeToWidth: true,
        ) ??
        const ReaderLength();
    ReaderBorderStyle border(String side) {
      final mode = value('border-$side-style');
      if (mode == null || mode == 'none' || mode == 'hidden') {
        return const ReaderBorderStyle();
      }
      final raw = value('border-$side-width') ?? 'medium';
      final width =
          _length(
            const {'thin': '1px', 'medium': '3px', 'thick': '5px'}[raw] ?? raw,
            scale,
            _rootScale,
          ) ??
          const ReaderLength();
      return ReaderBorderStyle(
        width: width,
        color: colorValue('border-$side-color', null),
      );
    }

    return EpubComputedStyle(
      inline: ReaderInlineStyle(
        bold: bold,
        italic: italic,
        underline: inherited.underline || ownUnderline,
        strike: inherited.strike || ownStrike,
        scale: scale,
        letterSpacing: letterSpacing,
        color: isRoot ? null : colorValue('color', inherited.color),
        background:
            styleIsInline(tag, display)
                ? colorValue('background-color', null)
                : null,
      ),
      block: ReaderBlockStyle(
        align: align,
        indent: indent,
        marginTop: margin('top', parent.block.marginTop),
        marginBottom: margin('bottom', parent.block.marginBottom),
        marginLeft: margin('left', parent.block.marginLeft),
        marginRight: margin('right', parent.block.marginRight),
        hasMargins:
            values.containsKey('margin-top') ||
            values.containsKey('margin-bottom'),
        lineHeight: lineHeight,
        breakBefore: pageBreak('break-before'),
        breakAfter: pageBreak('break-after'),
        keepTogether: keep,
        box: ReaderBoxStyle(
          paddingTop: padding('top'),
          paddingBottom: padding('bottom'),
          paddingLeft: padding('left'),
          paddingRight: padding('right'),
          top: border('top'),
          bottom: border('bottom'),
          left: border('left'),
          right: border('right'),
          radius:
              _length(value('border-radius') ?? '0', scale, _rootScale) ??
              const ReaderLength(),
          background: isRoot ? null : colorValue('background-color', null),
        ),
      ),
      display: display,
      hidden:
          parent.hidden ||
          display == 'none' ||
          value('visibility', inherits: true) == 'hidden',
      preformatted: pre,
      lineHeightFactor: lineFactor,
      lineHeightLength: lineLength,
    );
  }
}

const _blockTags = {
  'html',
  'body',
  'p',
  'div',
  'section',
  'article',
  'blockquote',
  'header',
  'footer',
  'figure',
  'figcaption',
  'table',
  'tr',
  'ul',
  'ol',
  'dl',
  'dt',
  'dd',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'pre',
  'li',
  'aside',
};
const _supported = {
  'color',
  'background-color',
  'border-radius',
  'padding-top',
  'padding-bottom',
  'padding-left',
  'padding-right',
  'border-top-width',
  'border-bottom-width',
  'border-left-width',
  'border-right-width',
  'border-top-style',
  'border-bottom-style',
  'border-left-style',
  'border-right-style',
  'border-top-color',
  'border-bottom-color',
  'border-left-color',
  'border-right-color',
  'font-size',
  'font-style',
  'font-weight',
  'text-decoration',
  'text-decoration-line',
  'letter-spacing',
  'text-align',
  'text-indent',
  'line-height',
  'margin-top',
  'margin-bottom',
  'margin-left',
  'margin-right',
  'break-before',
  'break-after',
  'break-inside',
  'display',
  'visibility',
  'white-space',
};

Map<String, String> _expand(String property, String value) {
  if (property == 'all' &&
      const {
        'inherit',
        'initial',
        'unset',
        'revert',
        'revert-layer',
      }.contains(value.trim().toLowerCase())) {
    return {for (final name in _supported) name: value};
  }
  if (property.startsWith('page-break-')) {
    property = property.replaceFirst('page-', '');
  }
  if (property == 'background') {
    return parseEpubColor(value) == null
        ? const {}
        : {'background-color': value};
  }
  if (property == 'border' ||
      RegExp(r'^border-(top|right|bottom|left)$').hasMatch(property)) {
    final words = _valueTokens(value);
    final sides =
        property == 'border'
            ? ['top', 'right', 'bottom', 'left']
            : [property.substring(7)];
    final mode = words.firstWhere(
      (w) => const {
        'none',
        'hidden',
        'solid',
        'dashed',
        'dotted',
        'double',
      }.contains(w),
      orElse: () => 'solid',
    );
    final width = words.firstWhere(
      (w) =>
          _length(w, 1, 1) != null ||
          const {'thin', 'medium', 'thick'}.contains(w),
      orElse: () => 'medium',
    );
    final color = words.firstWhere(
      (w) => parseEpubColor(w) != null,
      orElse: () => 'currentcolor',
    );
    return {
      for (final side in sides) ...{
        'border-$side-style': mode,
        'border-$side-width': width,
        'border-$side-color': color,
      },
    };
  }
  if (property == 'margin' ||
      property == 'padding' ||
      const {
        'border-width',
        'border-color',
        'border-style',
      }.contains(property)) {
    final parts = _valueTokens(value);
    if (parts.isEmpty || parts.length > 4) return const {};
    String key(String side) =>
        property.startsWith('border-')
            ? 'border-$side-${property.substring(7)}'
            : '$property-$side';
    return {
      key('top'): parts[0],
      key('right'): parts.length > 1 ? parts[1] : parts[0],
      key('bottom'): parts.length > 2 ? parts[2] : parts[0],
      key('left'):
          parts.length > 3
              ? parts[3]
              : parts.length > 1
              ? parts[1]
              : parts[0],
    };
  }
  if (property == 'margin-block' || property == 'margin-inline') {
    final parts = _valueTokens(value);
    if (parts.isEmpty || parts.length > 2) return const {};
    return {
      property == 'margin-block' ? 'margin-top' : 'margin-left': parts[0],
      property == 'margin-block' ? 'margin-bottom' : 'margin-right':
          parts.length == 2 ? parts[1] : parts[0],
    };
  }
  if (property == 'font') {
    if (const {
      'inherit',
      'initial',
      'unset',
      'revert',
      'revert-layer',
    }.contains(value.trim().toLowerCase())) {
      return {
        for (final key in [
          'font-size',
          'font-style',
          'font-weight',
          'line-height',
        ])
          key: value,
      };
    }
    final match = RegExp(
      r'(?:(?:^|\s))((?:\d*\.)?\d+(?:px|pt|pc|em|rem|ex|%|cm|mm|in)|xx-small|x-small|small|medium|large|x-large|xx-large|smaller|larger)(?:\s*/\s*([^\s]+))?(?=\s|$)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return const {};
    final prefix = value
        .substring(0, match.start)
        .toLowerCase()
        .split(RegExp(r'\s+'));
    return {
      'font-size': match[1]!,
      'line-height': match[2] ?? 'normal',
      'font-style':
          prefix.any((word) => word == 'italic' || word == 'oblique')
              ? 'italic'
              : 'normal',
      'font-weight': prefix.firstWhere(
        (word) =>
            word == 'bold' ||
            word == 'bolder' ||
            word == 'lighter' ||
            double.tryParse(word) != null,
        orElse: () => 'normal',
      ),
    };
  }
  return {property: value};
}

List<String> _valueTokens(String source) =>
    RegExp(
      r'(?:[^\s(]+|\([^)]*\))+',
    ).allMatches(source).map((m) => m[0]!).toList();

bool _validValue(String property, String source) {
  final value = source.trim().toLowerCase();
  if (const {
    'inherit',
    'initial',
    'unset',
    'revert',
    'revert-layer',
  }.contains(value)) {
    return true;
  }
  if (property.startsWith('margin-') || property.startsWith('padding-')) {
    return value == 'auto' ||
        _length(value, 1, 1, relativeToWidth: true) != null;
  }
  if (property == 'color' ||
      property == 'background-color' ||
      property.endsWith('-color')) {
    return value == 'currentcolor' || parseEpubColor(value) != null;
  }
  if (property.startsWith('border-') && property.endsWith('-style')) {
    return const {
      'none',
      'hidden',
      'solid',
      'dashed',
      'dotted',
      'double',
    }.contains(value);
  }
  if (property == 'border-radius' ||
      property.startsWith('border-') && property.endsWith('-width')) {
    return const {'thin', 'medium', 'thick'}.contains(value) ||
        _length(value, 1, 1) != null;
  }
  switch (property) {
    case 'font-size':
      final size = _fontSize(value, 1, 1);
      return size != null && size >= 0;
    case 'font-weight':
      final weight = double.tryParse(value);
      return const {'normal', 'bold', 'bolder', 'lighter'}.contains(value) ||
          weight != null && weight >= 1 && weight <= 1000;
    case 'font-style':
      return value == 'normal' ||
          value == 'italic' ||
          RegExp(
            r'^oblique(?:\s+[+-]?(?:\d*\.)?\d+(?:deg|grad|rad|turn))?$',
          ).hasMatch(value);
    case 'text-align':
      return const {
        'start',
        'left',
        'center',
        'right',
        'end',
        'justify',
      }.contains(value);
    case 'text-indent':
      return _length(value, 1, 1) != null;
    case 'letter-spacing':
      return value == 'normal' || _length(value, 1, 1) != null;
    case 'line-height':
      if (value == 'normal') return true;
      final number = double.tryParse(value);
      final length = _length(value, 1, 1, percent: true);
      return number != null && number > 0 ||
          length != null && length.em + length.px / 16 > 0;
    case 'text-decoration':
    case 'text-decoration-line':
      final words = value.split(RegExp(r'\s+'));
      if (words.contains('none')) return words.length == 1;
      return words.any(
        const {'underline', 'line-through', 'overline'}.contains,
      );
    case 'break-before':
    case 'break-after':
      return const {
        'auto',
        'avoid',
        'avoid-page',
        'always',
        'page',
        'left',
        'right',
        'recto',
        'verso',
      }.contains(value);
    case 'break-inside':
      return const {'auto', 'avoid', 'avoid-page'}.contains(value);
    case 'display':
      return const {
        'none',
        'inline',
        'contents',
        'block',
        'list-item',
        'table',
        'table-row',
        'table-cell',
        'inline-block',
        'flex',
        'grid',
      }.contains(value);
    case 'visibility':
      return const {'visible', 'hidden', 'collapse'}.contains(value);
    case 'white-space':
      return const {
        'normal',
        'nowrap',
        'pre',
        'pre-wrap',
        'pre-line',
        'break-spaces',
      }.contains(value);
  }
  return false;
}

double? _fontSize(String source, double parent, double root) {
  const sizes = {
    'xx-small': .6,
    'x-small': .75,
    'small': .89,
    'medium': 1.0,
    'large': 1.2,
    'x-large': 1.5,
    'xx-large': 2.0,
    'xxx-large': 3.0,
  };
  if (sizes.containsKey(source)) return sizes[source];
  if (source == 'larger') return parent * 1.2;
  if (source == 'smaller') return parent / 1.2;
  final length = _length(source, parent, root, percent: true);
  return length == null ? null : length.em + length.px / 16;
}

ReaderLength? _length(
  String source,
  double scale,
  double root, {
  bool percent = false,
  bool relativeToWidth = false,
}) {
  source = source.trim();
  if (source == '0' || source == '+0' || source == '-0') {
    return const ReaderLength();
  }
  final match = RegExp(
    r'^([+-]?(?:\d*\.)?\d+)(em|rem|px|pt|pc|in|cm|mm|ex|%)$',
    caseSensitive: false,
  ).firstMatch(source);
  if (match == null) return null;
  final number = double.tryParse(match[1]!);
  if (number == null || !number.isFinite) return null;
  final unit = match[2]!.toLowerCase();
  double em = 0, px = 0;
  switch (unit) {
    case 'em':
      em = number * scale;
    case 'rem':
      em = number * root;
    case 'ex':
      em = number * scale * .5;
    case '%':
      if (relativeToWidth) {
        return ReaderLength(fraction: (number / 100).clamp(-.9, .9).toDouble());
      }
      if (!percent) return null;
      em = number * scale / 100;
    case 'px':
      px = number;
    case 'pt':
      px = number * 4 / 3;
    case 'pc':
      px = number * 16;
    case 'in':
      px = number * 96;
    case 'cm':
      px = number * 96 / 2.54;
    case 'mm':
      px = number * 96 / 25.4;
  }
  return ReaderLength(
    em: em.clamp(-16, 16).toDouble(),
    px: px.clamp(-256, 256).toDouble(),
  );
}

bool _mediaTextApplies(String value, {bool dark = false}) {
  if (value.trim().isEmpty) return true;
  final theme = RegExp(
    r'^\s*(?:(?:only\s+)?(?:all|screen)\s+and\s+)?\(prefers-color-scheme\s*:\s*(dark|light)\)\s*$',
    caseSensitive: false,
  ).firstMatch(value);
  if (theme != null) return (theme[1]!.toLowerCase() == 'dark') == dark;
  return value
      .split(',')
      .any(
        (part) => const {
          'all',
          'screen',
          'only screen',
        }.contains(part.trim().toLowerCase()),
      );
}

bool _mediaApplies(List<ast.MediaQuery> queries, {bool dark = false}) =>
    queries.isEmpty ||
    queries.any(
      (query) =>
          (query.expressions.isEmpty ||
              _mediaTextApplies(query.span.text, dark: dark)) &&
          (!query.hasUnary || query.unary != 'NOT') &&
          (!query.hasMediaType ||
              const {'all', 'screen'}.contains(query.mediaType.toLowerCase())),
    );

bool styleIsInline(String tag, String display) =>
    display != 'block' && !const {'td', 'th', 'tr', 'table'}.contains(tag);

int? parseEpubColor(String source) {
  final s = source.trim().toLowerCase();
  const names = {
    'transparent': 0x00000000,
    'black': 0xff000000,
    'white': 0xffffffff,
    'red': 0xffff0000,
    'blue': 0xff0000ff,
    'green': 0xff008000,
    'yellow': 0xffffff00,
    'gray': 0xff808080,
    'grey': 0xff808080,
    'silver': 0xffc0c0c0,
    'navy': 0xff000080,
    'teal': 0xff008080,
    'purple': 0xff800080,
    'orange': 0xffffa500,
    'maroon': 0xff800000,
    'aqua': 0xff00ffff,
    'lime': 0xff00ff00,
    'fuchsia': 0xffff00ff,
    'olive': 0xff808000,
  };
  if (names.containsKey(s)) return names[s];
  if (RegExp(r'^#[a-f0-9]{3,8}$').hasMatch(s)) {
    var hex = s.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) return 0xff000000 | int.parse(hex, radix: 16);
    if (hex.length == 8) {
      final n = int.parse(hex, radix: 16);
      return ((n & 0xff) << 24) | (n >> 8);
    }
  }
  final match = RegExp(r'^rgba?\(([^()]*)\)$').firstMatch(s);
  if (match != null) {
    final p =
        match[1]!
            .split(RegExp(r'\s*[,/]\s*|\s+'))
            .where((v) => v.isNotEmpty)
            .toList();
    if (p.length < 3 || p.length > 4) return null;
    int? component(String v, bool alpha) {
      final percent = v.endsWith('%');
      final n = double.tryParse(percent ? v.substring(0, v.length - 1) : v);
      if (n == null || !n.isFinite) return null;
      return (n *
              (percent
                  ? 2.55
                  : alpha
                  ? 255
                  : 1))
          .round()
          .clamp(0, 255);
    }

    final r = component(p[0], false),
        g = component(p[1], false),
        b = component(p[2], false);
    final a = p.length == 4 ? component(p[3], true) : 255;
    if (r != null && g != null && b != null && a != null) {
      return (a << 24) | (r << 16) | (g << 8) | b;
    }
  }
  return null;
}

class _Declaration {
  const _Declaration(this.property, this.value, this.important);
  final String property, value;
  final bool important;
}

class _Rule {
  const _Rule(
    this.selector,
    this.declarations,
    this.order, {
    this.firstLetter = false,
  });
  final _Selector selector;
  final List<_Declaration> declarations;
  final int order;
  final bool firstLetter;
}

class _Winner {
  const _Winner(
    this.declaration,
    this.specificity,
    this.order,
    this.index,
    this.inline,
  );
  final _Declaration declaration;
  final List<int> specificity;
  final int order, index;
  final bool inline;
  int compareTo(_Winner other) {
    if (declaration.important != other.declaration.important) {
      return declaration.important ? 1 : -1;
    }
    if (inline != other.inline) return inline ? 1 : -1;
    for (var i = 0; i < 3; i++) {
      final difference = specificity[i] - other.specificity[i];
      if (difference != 0) return difference;
    }
    if (order != other.order) return order - other.order;
    return index - other.index;
  }
}

class _AttributeTest {
  const _AttributeTest(this.name, this.operator, this.value, this.insensitive);
  final String name, operator, value;
  final bool insensitive;
  bool matches(dom.Element element) {
    String? actual;
    for (final entry in element.attributes.entries) {
      final key = entry.key.toString();
      if (key == name ||
          name.startsWith('*:') &&
              (key == name.substring(2) || key.endsWith(name.substring(1)))) {
        actual = entry.value;
        break;
      }
    }
    if (actual == null) return false;
    if (operator.isEmpty) return true;
    var expected = value;
    if (insensitive) {
      actual = actual.toLowerCase();
      expected = expected.toLowerCase();
    }
    return switch (operator) {
      '=' => actual == expected,
      '~=' => actual.split(RegExp(r'\s+')).contains(expected),
      '|=' => actual == expected || actual.startsWith('$expected-'),
      '^=' => expected.isNotEmpty && actual.startsWith(expected),
      r'$=' => expected.isNotEmpty && actual.endsWith(expected),
      '*=' => expected.isNotEmpty && actual.contains(expected),
      _ => false,
    };
  }
}

class _Compound {
  const _Compound(
    this.tag,
    this.id,
    this.classes,
    this.attributes,
    this.root,
    this.nth,
  );
  final String? tag, id;
  final List<String> classes;
  final List<_AttributeTest> attributes;
  final bool root;
  final int? nth;
  bool matches(dom.Element element, int Function(dom.Element) ordinal) =>
      (tag == null || tag == '*' || element.localName == tag) &&
      (id == null || element.id == id) &&
      classes.every(element.classes.contains) &&
      attributes.every((test) => test.matches(element)) &&
      (!root || element.localName == 'html') &&
      (nth == null ||
          (nth == -2
              ? ordinal(element).isEven && ordinal(element) > 0
              : nth == -1
              ? ordinal(element).isOdd
              : ordinal(element) == nth));
}

class _Selector {
  const _Selector(this.parts, this.childRelations, this.specificity);
  final List<_Compound> parts;

  /// Relation from part[i] to part[i+1]: true is child, false is descendant.
  final List<bool> childRelations;
  final List<int> specificity;
  String get indexKey {
    final part = parts.last;
    return part.id != null
        ? 'i:${part.id}'
        : part.classes.isNotEmpty
        ? 'c:${part.classes.first}'
        : part.tag != null && part.tag != '*'
        ? 't:${part.tag}'
        : '*';
  }

  bool matches(
    dom.Element element,
    bool Function() budget,
    int Function(dom.Element) ordinal,
  ) {
    bool match(int index, dom.Element current) {
      if (!budget() || !parts[index].matches(current, ordinal)) return false;
      if (index == 0) return true;
      var ancestor = current.parent;
      if (childRelations[index - 1]) {
        return ancestor is dom.Element && match(index - 1, ancestor);
      }
      while (ancestor is dom.Element) {
        if (match(index - 1, ancestor)) return true;
        ancestor = ancestor.parent;
      }
      return false;
    }

    return match(parts.length - 1, element);
  }

  static _Selector? parse(String source) {
    source =
        source
            .replaceAll('/*__litetale_attr_i__*/', ' i')
            .replaceAll('/*__litetale_attr_s__*/', ' s')
            .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
            .trim();
    if (source.isEmpty || source.length > 1024) return null;
    final pieces = <String>[];
    final relations = <bool>[];
    var start = 0, brackets = 0;
    String? quote;
    var escaped = false;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      if (c == '[') {
        brackets++;
        continue;
      }
      if (c == ']') {
        brackets--;
        continue;
      }
      if (brackets == 0 && (c == '>' || RegExp(r'\s').hasMatch(c))) {
        final piece = source.substring(start, i).trim();
        if (piece.isNotEmpty) {
          pieces.add(piece);
          relations.add(c == '>');
        } else if (c == '>' && relations.isNotEmpty) {
          relations[relations.length - 1] = true;
        }
        start = i + 1;
      }
    }
    if (quote != null || brackets != 0) return null;
    final last = source.substring(start).trim();
    if (last.isEmpty) return null;
    pieces.add(last);
    if (pieces.length > 32 || relations.length != pieces.length - 1) {
      return null;
    }
    final parts = <_Compound>[];
    var ids = 0, classes = 0, tags = 0;
    for (final piece in pieces) {
      var at = 0;
      String? tag, id;
      final classNames = <String>[];
      final attrs = <_AttributeTest>[];
      var root = false;
      int? nth;
      String? identifier() {
        final begin = at;
        while (at < piece.length) {
          final code = piece.codeUnitAt(at);
          if (code == 92) {
            at++;
            if (at >= piece.length) return null;
            var count = 0;
            while (at < piece.length &&
                count < 6 &&
                RegExp(r'[a-fA-F0-9]').hasMatch(piece[at])) {
              at++;
              count++;
            }
            if (count == 0) {
              at++;
            } else if (at < piece.length && RegExp(r'\s').hasMatch(piece[at])) {
              at++;
            }
            continue;
          }
          if (code >= 128 || RegExp(r'[\w-]').hasMatch(piece[at])) {
            at++;
          } else {
            break;
          }
        }
        return at == begin ? null : _cssIdentifier(piece.substring(begin, at));
      }

      if (piece.startsWith('*')) {
        tag = '*';
        at++;
      } else if (!'.#[:'.contains(piece[0])) {
        tag = identifier()?.toLowerCase();
        if (tag == null) return null;
        tags++;
      }
      if (at < piece.length && piece[at] == '|' && tag != null) {
        at++;
        tag =
            at < piece.length && piece[at] == '*'
                ? '*'
                : identifier()?.toLowerCase();
        if (tag == '*') at++;
        if (tag == null) return null;
      }
      while (at < piece.length) {
        final c = piece[at++];
        if (c == '.') {
          final name = identifier();
          if (name == null) return null;
          classNames.add(name);
          classes++;
        } else if (c == '#') {
          final name = identifier();
          if (name == null || id != null) return null;
          id = name;
          ids++;
        } else if (c == '[') {
          var end = at;
          String? q;
          var escaped = false;
          for (; end < piece.length; end++) {
            final x = piece[end];
            if (escaped) {
              escaped = false;
              continue;
            }
            if (x == '\\') {
              escaped = true;
              continue;
            }
            if (q != null) {
              if (x == q) q = null;
            } else if (x == '"' || x == "'") {
              q = x;
            } else if (x == ']') {
              break;
            }
          }
          if (end >= piece.length) return null;
          final test = _parseAttribute(piece.substring(at, end));
          if (test == null) return null;
          attrs.add(test);
          classes++;
          at = end + 1;
        } else if (c == ':' && piece.substring(at).startsWith('nth-child(')) {
          final m = RegExp(
            r'^nth-child\((even|odd|[1-9][0-9]{0,5})\)',
          ).firstMatch(piece.substring(at));
          if (m == null) return null;
          nth =
              m[1] == 'even'
                  ? -2
                  : m[1] == 'odd'
                  ? -1
                  : int.parse(m[1]!);
          classes++;
          at += m[0]!.length;
        } else if (c == ':' && piece.substring(at) == 'root') {
          root = true;
          classes++;
          at = piece.length;
        } else {
          return null;
        }
      }
      parts.add(_Compound(tag, id, classNames, attrs, root, nth));
    }
    return _Selector(parts, relations, [ids, classes, tags]);
  }
}

String _cssIdentifier(String source) => source.replaceAllMapped(
  RegExp(r'\\([a-fA-F0-9]{1,6}\s?|.)', dotAll: true),
  (match) {
    final escape = match[1]!;
    final hex = int.tryParse(escape.trim(), radix: 16);
    return hex == null
        ? escape
        : (hex == 0 || hex > 0x10ffff ? '\ufffd' : String.fromCharCode(hex));
  },
);

_AttributeTest? _parseAttribute(String source) {
  final match = RegExp(
    r'''^\s*((?:\\.|[\w:-])+(?:\|(?:\\.|[\w*:.-])+)?|\*\|(?:\\.|[\w:.-])+)(?:\s*([~|^$*]?=)\s*(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'|([^\s]+?))\s*(?:([iIsS]))?)?\s*$''',
  ).firstMatch(source);
  if (match == null) return null;
  return _AttributeTest(
    _cssIdentifier(match[1]!).replaceAll('|', ':').toLowerCase(),
    match[2] ?? '',
    _cssIdentifier(match[3] ?? match[4] ?? match[5] ?? ''),
    match[6]?.toLowerCase() == 'i',
  );
}

// csslib predates attribute comparison flags. Comments are understood by its
// parser and remain in selector spans, so the matcher can recover `i` and `s`.
String _rewriteAttributeFlags(String source) {
  final output = StringBuffer();
  var copied = 0;
  int? bracket;
  String? quote;
  var escaped = false;
  for (var at = 0; at < source.length; at++) {
    final char = source[at];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == '\\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '/' && at + 1 < source.length && source[at + 1] == '*') {
      final end = source.indexOf('*/', at + 2);
      if (end < 0) break;
      at = end + 1;
      continue;
    }
    if (char == '[') {
      bracket = at + 1;
    } else if (char == ']' && bracket != null) {
      final inner = source.substring(bracket, at);
      final flag = RegExp(r'\s+([iIsS])\s*$').firstMatch(inner);
      if (flag != null) {
        output.write(source.substring(copied, bracket + flag.start));
        output.write('/*__litetale_attr_${flag[1]!.toLowerCase()}__*/');
        copied = at;
      }
      bracket = null;
    }
  }
  output.write(source.substring(copied));
  return output.toString();
}
