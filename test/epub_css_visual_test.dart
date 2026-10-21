import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/epub/epub_parser.dart';
import 'package:wild/services/reader_paginator.dart';
import 'package:wild/services/reader_rich_typography.dart';
import 'support/epub_fixture.dart';

ReaderDocument parse(String body) =>
    parseEpubBook(
      buildEpubFixture(
        chapters: [
          EpubFixtureChapter(path: 'text.xhtml', title: '测试', body: body),
        ],
      ),
    ).chapters.single.document!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('explicit accents/boxes and dark rules survive the stored document', () {
    final doc = parse('''<style>
      body {color:#202735;background:#fffdf8;margin:5%}
      h1{color:#245385} .card{border:1px solid #d1b16d;border-radius:.4em;padding:.75em 1em;background:#fff3d8}
      blockquote{margin:1em 8%;padding:.8em 1em;border-left:.25em solid #5a83a5;background:#f0f4fa}
      .highlight{background:#fff0a8} strong{color:rgb(138,44,59)}
      @media(prefers-color-scheme:dark){h1{color:#98c9ff}.card{color:#2a2926}}
    </style><h1>标题</h1><p>普通<strong>强调</strong><span class="highlight">高亮</span></p>
    <div class="card"><p>提示卡片</p></div><blockquote><p>引用</p></blockquote>''');
    final restored = ReaderDocument.fromJson(doc.toJson());
    expect(restored.cacheIdentity, doc.cacheIdentity);
    expect(restored.blocks.first.runs.single.style.darkColor, 0xff98c9ff);
    final runs = restored.blocks[1].runs;
    expect(runs.first.style.color, isNull); // Reader's base text colour wins.
    expect(runs.firstWhere((r) => r.text == '强调').style.color, 0xff8a2c3b);
    expect(runs.firstWhere((r) => r.text == '高亮').style.background, 0xfffff0a8);
    final card = restored.blocks.firstWhere((b) => b.text == '提示卡片');
    expect(card.style.box.background, 0xfffff3d8);
    expect(card.style.box.paddingBottom.em, .75);
    expect(card.runs.single.style.darkColor, 0xff2a2926);
    final quote = restored.blocks.last;
    expect(quote.style.marginLeft.resolve(20, referenceWidth: 400), 52);
    expect(quote.style.box.left.width.em, .25);
  });

  test(
    'ordered values, alternating table rows and first-letter do not lose text',
    () {
      final doc = parse(
        '''<style>p::first-letter{font-size:2em;color:#a74a2a}
      th,td{border:1px solid #899cab;padding:.35em}
      tr:nth-child(even){background:#f1f6fa}</style>
      <p>🌱春天</p><ol start="3"><li>甲</li><li value="8">乙</li><li>丙</li></ol>
      <table><tr><th>名称</th><th>说明</th></tr><tr><td>甲</td><td>乙</td></tr></table>''',
      );
      expect(doc.blocks.first.runs.first.text, '🌱');
      expect(doc.blocks.first.runs.first.style.scale, 2);
      expect(
        doc.blocks.map((b) => b.text),
        containsAll(['3. 甲', '8. 乙', '9. 丙', '名称\t说明', '甲\t乙']),
      );
      final rows = doc.blocks.where((b) => b.cells.isNotEmpty).toList();
      expect(rows.first.cells.first.runs.first.style.bold, isTrue);
      expect(rows.last.style.box.background, 0xfff1f6fa);
    },
  );

  test(
    'box padding and table cell wrapping use the same heights in pagination',
    () {
      final doc = parse(
        '''<style>.card{background:#fff3d8;padding:1em;border:2px solid #333}
      td,th{border:1px solid #333;padding:.35em}</style>
      <p class="card">${'带边框的正文，内容很长，必须连续分行。' * 50}</p>
      <table><tr><td>甲</td><td>${'较长说明。' * 8}</td></tr></table>''',
      );
      for (final (width, height) in [(280.0, 340.0), (420.0, 280.0)]) {
        final pages = paginateReaderContent(
          content: doc.content,
          document: doc,
          canvasWidth: width,
          canvasHeight: height,
          fontSize: 18,
          paragraphSpacing: 12,
          lineHeight: 1.4,
        );
        expect(
          pages.expand((p) => p.fragments!).map((f) => f.text).join(),
          doc.blocks.map((b) => b.text).join(),
        );
        for (final page in pages) {
          var used = 0.0;
          for (final fragment in page.fragments!) {
            final layout = ReaderParagraphLayout(
              fragment: fragment,
              baseStyle: const TextStyle(fontSize: 18, height: 1.4),
              width: width,
              textScaler: TextScaler.noScaling,
            );
            used += layout.height + fragment.gapBefore;
            layout.dispose();
          }
          expect(used, lessThanOrEqualTo(height + .01));
        }
      }
    },
  );

  test(
    'one table row taller than a page falls back to text without omissions',
    () {
      final doc = parse(
        '<table><tr><td>${'第一列长文' * 80}</td><td>${'第二列长文' * 80}</td></tr></table>',
      );
      final pages = paginateReaderContent(
        content: doc.content,
        document: doc,
        canvasWidth: 250,
        canvasHeight: 280,
        fontSize: 18,
        paragraphSpacing: 12,
        lineHeight: 1.4,
      );
      expect(pages.length, greaterThan(1));
      expect(
        pages.expand((p) => p.fragments!).every((f) => f.tableAsText),
        isTrue,
      );
      expect(
        pages.expand((p) => p.fragments!).map((f) => f.text).join(),
        doc.blocks.single.text,
      );
    },
  );

  test('table rows do not inherit the reader paragraph spacing between rows', () {
    final doc = parse(
      '<table><tr><td>甲</td><td>乙</td></tr><tr><td>丙</td><td>丁</td></tr><tr><td>戊</td><td>己</td></tr></table>',
    );
    final pages = paginateReaderContent(
      content: doc.content,
      document: doc,
      canvasWidth: 300,
      canvasHeight: 400,
      fontSize: 18,
      paragraphSpacing: 48,
      lineHeight: 1.4,
    );
    expect(pages.single.fragments, hasLength(3));
    expect(
      pages.single.fragments!.skip(1).every((f) => f.gapBefore == 0),
      isTrue,
    );
  });

  test(
    'painting selects dark accents and accounts for percent sides and padding',
    () {
      final block = ReaderBlock(
        runs: const [
          ReaderRun(
            'test',
            style: ReaderInlineStyle(color: 0xff245385, darkColor: 0xff98c9ff),
          ),
        ],
        style: const ReaderBlockStyle(
          marginLeft: ReaderLength(fraction: .1),
          marginRight: ReaderLength(fraction: .1),
          box: ReaderBoxStyle(
            paddingLeft: ReaderLength(em: 1),
            paddingTop: ReaderLength(em: 1),
          ),
        ),
      );
      final layout = ReaderParagraphLayout(
        fragment: ReaderFragment(
          block: block,
          start: 0,
          end: 4,
          first: true,
          last: true,
        ),
        baseStyle: const TextStyle(fontSize: 20, color: Colors.white),
        width: 300,
        textScaler: TextScaler.noScaling,
      );
      expect(layout.left, 30);
      expect(layout.painter.width, 220);
      expect(layout.height, layout.painter.height + 20);
      final text = layout.painter.text! as TextSpan;
      expect(
        (text.children!.first as TextSpan).style!.color,
        const Color(0xff98c9ff),
      );
      layout.dispose();
    },
  );

  test(
    'invalid persisted colour and oversized table structures fail safely',
    () {
      expect(
        () => ReaderInlineStyle.fromJson({'color': -1}),
        throwsFormatException,
      );
      expect(
        () => ReaderInlineStyle.fromJson({'color': 'red'}),
        throwsFormatException,
      );
      expect(
        () => ReaderLength.fromJson({'fraction': 2}),
        throwsFormatException,
      );
      expect(
        () => ReaderBlock.fromJson({
          'runs': [],
          'style': {},
          'cells': List.filled(25, {'runs': [], 'style': {}}),
        }),
        throwsFormatException,
      );
    },
  );
}
