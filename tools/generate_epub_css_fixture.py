"""Self-authored EPUB for CSS, long paragraphs, images and key-event QA."""
from pathlib import Path
import hashlib
import json
import zipfile
from generate_epub_qa_fixtures import png

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build' / 'epub-css-volume'
OUT.mkdir(parents=True, exist_ok=True)

entries = {
    'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    'OPS/book.opf': '''<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:litetale:css-qa</dc:identifier><dc:title>原书样式验收</dc:title><dc:creator>LiteTale 测试</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">2026-10-19T00:00:00Z</meta><meta name="cover" content="cover"/></metadata><manifest><item id="c1" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="Text/second.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="main" href="Styles/main.css" media-type="text/css"/><item id="base" href="Styles/排版/base.css" media-type="text/css"/><item id="cover" href="Images/cover.png" media-type="image/png" properties="cover-image"/><item id="image" href="Images/illustration.png" media-type="image/png"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>''',
    'OPS/nav.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="Text/chapter.xhtml">第一章·样式展示</a></li><li><a href="Text/second.xhtml">第二章·分页与续读</a></li></ol></nav></body></html>',
    'OPS/Styles/排版/base.css': 'body{font-size:16px} p{text-indent:2em;line-height:1.75;margin:0 0 .8em} h1{font-size:1.6em;font-weight:bold;text-align:center;margin:0 0 1em} em{font-style:italic} strong{font-weight:700}',
    'OPS/Styles/main.css': '''@import "排版/base.css";
      .center{text-align:center;text-indent:0}
      .quote{margin-left:1.2em;margin-right:1.2em;font-style:italic}
      .right{text-align:right;text-indent:0}
      #priority{text-align:right!important;text-indent:0}
      .underline{text-decoration:underline}
      .page-break{page-break-before:always}
      .hidden{display:none}
      .small{font-size:.8em}
    ''',
    'OPS/Images/cover.png': png(320,480,[(55,40,95),(205,190,240),(160,130,210)]),
    'OPS/Images/illustration.png': png(640,440,[(20,70,110),(130,210,230),(245,225,150)]),
}

def html(body):
    return '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>原书样式验收</title><link rel="stylesheet" href="../Styles/main.css"/><style>.center strong{font-size:1.1em}</style></head><body>'+body+'</body></html>'

body = '''<h1>第一章·样式展示</h1>
<p class="center"><strong>这是居中的副标题</strong></p>
<p>段落首行缩进两个字，正文保留阅读器里选择的字体。这里有<strong>加粗文字</strong>、<em>斜体文字 Italic sample</em>和<span class="underline">下划线文字</span>。</p>
<p class="quote">“这是一段带左右边距的引用，继续沿着海边走向下一站。”</p>
<p id="priority" style="text-align:center">这行靠右，验证 important 优先级。</p>
<p class="hidden">HIDDEN_CSS_MUST_NOT_APPEAR</p>
<img src="../Images/illustration.png" alt="蓝黄棋盘插图"/>
<p class="center small">插图题注：海边的旅途</p>
'''
for i in range(1, 45):
    body += f'<p>续读行{i:03d}。清晨，小遥带着日记离开站台，沿着海边的小路走向远方。<strong>粗体片段{i:03d}</strong>与<em>斜体片段</em>应该在分页后继续保持样式。她把遇见的故事写在下一页。</p>'
body += '<p class="page-break right">分页后单独开始的落款：小遥</p>'
entries['OPS/Text/chapter.xhtml'] = html(body)
entries['OPS/Text/second.xhtml'] = html('<h1>第二章·分页与续读</h1><p>第二章是离线切章与音量键的测试。原书样式继续生效。</p><p class="right">故事暂告一段落。</p>')
target = OUT / '原书样式与音量键.epub'
with zipfile.ZipFile(target,'w') as archive:
    archive.writestr(zipfile.ZipInfo('mimetype',date_time=(2026,10,19,0,0,0)), 'application/epub+zip',compress_type=zipfile.ZIP_STORED)
    for name,data in entries.items():
        archive.writestr(zipfile.ZipInfo(name,date_time=(2026,10,19,0,0,0)),data.encode('utf-8') if isinstance(data,str) else data,compress_type=zipfile.ZIP_DEFLATED)
record={'file':str(target),'bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'title':'原书样式验收'}
(OUT/'fixture.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(record,ensure_ascii=False))
