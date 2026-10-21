import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/services/epub/epub_css.dart';

void main() {
  ({dom.Document document, EpubCssCascade cascade, List<String> warnings}) make(
    String body, {
    String css = '',
    Map<String, String> files = const {},
    String head = '',
    EpubCssLimits limits = const EpubCssLimits(),
  }) {
    final document = html.parse(
      '<html><head>$head<style>$css</style></head><body>$body</body></html>',
    );
    final warnings = <String>[];
    final cascade = EpubCssCascade.fromDocument(
      document,
      'OPS/Text/one.xhtml',
      readLocalCss: (path) => files[path],
      resolveLocalPath: (base, href) {
        if (href.contains(':') || href.startsWith('//')) return null;
        final uri = Uri.parse('https://epub.invalid/$base').resolve(href);
        return uri.path.substring(1);
      },
      onWarning: warnings.add,
      limits: limits,
    );
    return (document: document, cascade: cascade, warnings: warnings);
  }

  test(
    'tag/class/id/descendant/child selectors and source order cascade correctly',
    () {
      final fixture = make(
        '<section><div><p id="p" class="a b">正文</p></div></section>',
        css: '''
      p {text-align:left} .a {text-align:center} #p {text-align:right}
      section > p {font-style:italic} section p {font-weight:bold}
      .a.b {text-indent:1em} .a.b {text-indent:2em}
    ''',
      );
      final style = fixture.cascade.styleFor(
        fixture.document.querySelector('p')!,
      );
      expect(style.block.align, 'right');
      expect(style.inline.bold, isTrue);
      expect(style.inline.italic, isFalse);
      expect(style.block.indent.em, 2);
    },
  );

  test(
    'important overrides inline normal; inline important wins equal origin',
    () {
      final fixture = make(
        '<p id="a" style="text-align:left">甲</p>'
        '<p id="b" style="text-align:left!important">乙</p>',
        css: 'p {text-align:right!important}',
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('#a')!)
            .block
            .align,
        'right',
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('#b')!)
            .block
            .align,
        'left',
      );
    },
  );

  test(
    'selector groups and attributes do not leak styles onto non-matches',
    () {
      final fixture = make(
        '<p id="a" class="lead" data-kind="novel-chapter" title="A B">甲</p>'
        '<p id="b" lang="zh-CN">乙</p><p id="c">丙</p>',
        css: '''
      p[data-kind^="novel"][title="A B"], p[lang|="zh"] {text-align:center}
      [class~="lead"] {font-style:italic}
      p[data-kind\$="CHAPTER" i] {font-weight:bold}
    ''',
      );
      final a = fixture.cascade.styleFor(fixture.document.querySelector('#a')!);
      final b = fixture.cascade.styleFor(fixture.document.querySelector('#b')!);
      final c = fixture.cascade.styleFor(fixture.document.querySelector('#c')!);
      expect(a.block.align, 'center');
      expect(a.inline.italic, isTrue);
      expect(a.inline.bold, isTrue);
      expect(b.block.align, 'center');
      expect(c.block.align, 'start');
    },
  );

  test(
    'font metrics inherit and relative sizes are normalized to user base size',
    () {
      final fixture = make(
        '<div><p><em id="run">正文</em></p></div>',
        css: '''
      html {font-size:125%} div {font-size:1.2em; font-weight:bold;line-height:1.6}
      p {font-size:80%;text-indent:2em;letter-spacing:.1em}
      em {font-size:1rem;font-style:normal}
    ''',
      );
      final paragraph = fixture.cascade.styleFor(
        fixture.document.querySelector('p')!,
      );
      final run = fixture.cascade.styleFor(
        fixture.document.querySelector('#run')!,
      );
      expect(paragraph.inline.scale, closeTo(1.2, .0001));
      expect(paragraph.block.indent.em, closeTo(2.4, .0001));
      expect(paragraph.inline.letterSpacing.em, closeTo(.12, .0001));
      expect(run.inline.scale, closeTo(1.25, .0001));
      expect(run.inline.bold, isTrue);
      expect(run.inline.italic, isFalse);
      expect(run.block.lineHeight, 1.6);
    },
  );

  test(
    'font normal and initial/unset reset semantic styles rather than remain sticky',
    () {
      final fixture = make(
        '<p><strong id="normal">甲</strong><em id="reset">乙</em></p>',
        css: '''
      p {font-weight:bold;font-style:italic;text-align:right;letter-spacing:2px}
      strong {font-weight:normal;font-style:initial}
      em {font-weight:initial;font-style:normal;letter-spacing:normal;text-align:unset}
    ''',
      );
      final normal = fixture.cascade.styleFor(
        fixture.document.querySelector('#normal')!,
      );
      final reset = fixture.cascade.styleFor(
        fixture.document.querySelector('#reset')!,
      );
      expect(normal.inline.bold, isFalse);
      expect(normal.inline.italic, isFalse);
      expect(reset.inline.bold, isFalse);
      expect(reset.inline.italic, isFalse);
      expect(reset.inline.letterSpacing.px, 0);
      expect(reset.block.align, 'right');
    },
  );

  test(
    'margin shorthand, longhands and explicit zero remain distinguishable',
    () {
      final fixture = make(
        '<p id="a">甲</p><p id="b">乙</p><p id="c">丙</p>',
        css: '''
      #a {font-size:150%;margin:1em 2px 3em 4px;margin-top:0}
      #b {margin:0} #c {margin-left:1em}
    ''',
      );
      final a =
          fixture.cascade.styleFor(fixture.document.querySelector('#a')!).block;
      final b =
          fixture.cascade.styleFor(fixture.document.querySelector('#b')!).block;
      final c =
          fixture.cascade.styleFor(fixture.document.querySelector('#c')!).block;
      expect(a.marginTop.em, 0);
      expect(a.marginRight.px, 2);
      expect(a.marginBottom.em, 4.5);
      expect(a.marginLeft.px, 4);
      expect(a.hasMargins, isTrue);
      expect(b.hasMargins, isTrue);
      expect(b.marginBottom.em, 0);
      expect(c.hasMargins, isFalse);
      expect(c.marginLeft.em, 1);
    },
  );

  test(
    'unitless and length line heights have distinct inheritance semantics',
    () {
      final fixture = make(
        '<div id="a"><p>甲</p></div><div id="b"><p>乙</p></div>',
        css: '''
      div {font-size:1em} #a {line-height:2} #b {line-height:2em} p {font-size:2em}
    ''',
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('#a p')!)
            .block
            .lineHeight,
        2,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('#b p')!)
            .block
            .lineHeight,
        1,
      );
    },
  );

  test(
    'native heading/strong/em defaults support books with no author style',
    () {
      final fixture = make(
        '<h1>标题</h1><p><strong>粗体</strong><em>斜体</em><u>下划线</u><del>删除线</del></p>',
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('h1')!)
            .inline
            .scale,
        2,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('h1')!)
            .inline
            .bold,
        isTrue,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('strong')!)
            .inline
            .bold,
        isTrue,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('em')!)
            .inline
            .italic,
        isTrue,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('u')!)
            .inline
            .underline,
        isTrue,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('del')!)
            .inline
            .strike,
        isTrue,
      );
    },
  );

  test('book fonts and colors cannot override user font or paper settings', () {
    final fixture = make(
      '<p>正文</p>',
      css: '''
      @font-face {font-family:unsafe;src:url(https://remote.invalid/font.ttf)}
      p {font-family:unsafe;color:red;background:black;position:fixed;writing-mode:vertical-rl;
        animation:spin 1s; text-align:center}
    ''',
    );
    final style = fixture.cascade.styleFor(
      fixture.document.querySelector('p')!,
    );
    expect(style.block.align, 'center');
    expect(style.inline.scale, 1);
    expect(style.inline.toJson().keys, isNot(contains('font-family')));
  });

  test(
    'local link/import paths, imports source order and loops are bounded',
    () {
      final fixture = make(
        '<p>正文</p>',
        head: '<link rel="stylesheet" href="../Styles/main.css"/>',
        files: {
          'OPS/Styles/main.css':
              '@import "nested/base.css"; p {text-align:right}',
          'OPS/Styles/nested/base.css':
              '@import "../main.css"; p {text-align:center;font-weight:bold}',
        },
        css: 'p {font-style:italic}',
      );
      final style = fixture.cascade.styleFor(
        fixture.document.querySelector('p')!,
      );
      expect(style.block.align, 'right');
      expect(style.inline.bold, isTrue);
      expect(style.inline.italic, isTrue);
      expect(fixture.warnings.join(), contains('循环'));
    },
  );

  test(
    'remote import/link is never read and print/unknown media is not applied',
    () {
      final fixture = make(
        '<p>正文</p>',
        head:
            '<link rel="stylesheet" href="https://remote.invalid/style.css"/>',
        css: '''
      @import url("https://remote.invalid/import.css");
      @media print {p {font-weight:bold}} @media screen {p {font-style:italic}}
      @media (min-width:900px) {p {text-align:right}}
    ''',
      );
      final style = fixture.cascade.styleFor(
        fixture.document.querySelector('p')!,
      );
      expect(style.inline.bold, isFalse);
      expect(style.inline.italic, isTrue);
      expect(style.block.align, 'start');
      expect(fixture.warnings.join(), contains('外部网络'));
    },
  );

  test('font shorthand and page breaks are carried into native style', () {
    final fixture = make(
      '<p>正文</p>',
      css:
          'p {font:italic bold 120%/1.8 serif; '
          'page-break-before:always;break-after:page;page-break-inside:avoid}',
    );
    final style = fixture.cascade.styleFor(
      fixture.document.querySelector('p')!,
    );
    expect(style.inline.italic, isTrue);
    expect(style.inline.bold, isTrue);
    expect(style.inline.scale, closeTo(1.2, .0001));
    expect(style.block.lineHeight, 1.8);
    expect(style.block.breakBefore, isTrue);
    expect(style.block.breakAfter, isTrue);
    expect(style.block.keepTogether, isTrue);
  });

  test(
    'display, white space and author normal overrides are computed ahead of reading',
    () {
      final fixture = make(
        '<p id="a">甲</p><pre id="b">乙</pre><span id="c">丙</span>',
        css: '''
      #a {display:none} #b {white-space:normal} #c {display:block;white-space:pre-wrap}
    ''',
      );
      expect(
        fixture.cascade.styleFor(fixture.document.querySelector('#a')!).hidden,
        isTrue,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('#b')!)
            .preformatted,
        isFalse,
      );
      expect(
        fixture.cascade.styleFor(fixture.document.querySelector('#c')!).isBlock,
        isTrue,
      );
      expect(
        fixture.cascade
            .styleFor(fixture.document.querySelector('#c')!)
            .preformatted,
        isTrue,
      );
    },
  );

  test(
    'rule, byte and matching budgets fall back to readable inherited styles',
    () {
      final fixture = make(
        '<p class="x">甲</p><p class="x">乙</p>',
        css: '.x {font-weight:bold}.x {text-align:center}',
        limits: const EpubCssLimits(maxRules: 1, maxMatches: 3),
      );
      final first = fixture.cascade.styleFor(
        fixture.document.querySelector('p')!,
      );
      expect(first.block.align, 'start');
      expect(fixture.warnings, isNotEmpty);
      final huge = make(
        '<p>正文</p>',
        css: 'p {font-weight:bold}',
        limits: const EpubCssLimits(maxSheetBytes: 4),
      );
      expect(
        huge.cascade.styleFor(huge.document.querySelector('p')!).inline.bold,
        isFalse,
      );
      expect(huge.warnings, isNotEmpty);
    },
  );

  test(
    'invalid later values and invalid shorthand do not mask valid declarations',
    () {
      final fixture = make(
        '<p>正文</p>',
        css:
            'p {text-align:right;font-size:120%;margin:1em 2em;'
            'text-align:banana;font-size:-2em;margin:3em invalid}',
      );
      final style = fixture.cascade.styleFor(
        fixture.document.querySelector('p')!,
      );
      expect(style.block.align, 'right');
      expect(style.inline.scale, 1.2);
      expect(style.block.marginTop.em, 1.2);
      expect(style.block.marginLeft.em, 2.4);
    },
  );

  test('all initial resets inherited author styles and semantic defaults', () {
    final fixture = make(
      '<p><strong id="x">正文</strong></p>',
      css:
          'p {font-weight:bold;font-style:italic;text-align:right;letter-spacing:2px}'
          '#x {all:initial}',
    );
    final style = fixture.cascade.styleFor(
      fixture.document.querySelector('#x')!,
    );
    expect(style.inline.bold, isFalse);
    expect(style.inline.italic, isFalse);
    expect(style.block.align, 'start');
    expect(style.inline.letterSpacing.px, 0);
  });
}
