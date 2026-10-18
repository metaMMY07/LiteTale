"""Self-authored EPUB 2/3 fixtures for actual Android document-picker checks."""
from pathlib import Path
import hashlib
import json
import struct
import zlib
import zipfile
from html import escape

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build' / 'epub-local' / 'fixtures'


def png(width, height, palette):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = []
    for y in range(height):
        row = bytearray(b'\0')
        for x in range(width):
            if x < 20 or x >= width - 20 or y < 20 or y >= height - 20:
                color = palette[0]
            elif (x // 32 + y // 40) % 2:
                color = palette[1]
            else:
                color = palette[2]
            row.extend(color)
        rows.append(bytes(row))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


def build(version):
    title = f'远行日记 EPUB{version}'
    entries = {'META-INF/container.xml': '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="书籍/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'''}
    manifest = [
        '<item id="c0" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>',
        '<item id="c1" href="Text/z%20序章.xhtml" media-type="application/xhtml+xml"/>',
        '<item id="c2" href="Text/a%20后记.xhtml" media-type="application/xhtml+xml"/>',
        '<item id="cover" href="Images/封面.png" media-type="image/png"' + (' properties="cover-image"' if version == 3 else '') + '/>',
        '<item id="image" href="Images/旅途%20插图.png" media-type="image/png"/>',
    ]
    toc = [('封面', 'Text/cover.xhtml'), ('序章·站台的风', 'Text/z%20序章.xhtml#begin'), ('后记·海边来信', 'Text/a%20后记.xhtml#end')]
    if version == 3:
        manifest.append('<item id="toc" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
        entries['书籍/nav.xhtml'] = '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>' + ''.join(f'<li><a href="{href}">{label}</a></li>' for label, href in toc) + '</ol></nav></body></html>'
    else:
        manifest.append('<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        entries['书籍/toc.ncx'] = '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>远行日记</text></docTitle><navMap>' + ''.join(f'<navPoint id="p{i}" playOrder="{i+1}"><navLabel><text>{label}</text></navLabel><content src="{href}"/></navPoint>' for i, (label, href) in enumerate(toc)) + '</navMap></ncx>'
    entries['书籍/package.opf'] = f'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:litetale:qa:{version}</dc:identifier><dc:title>{title}</dc:title><dc:creator>LiteTale 测试</dc:creator><dc:language>zh-CN</dc:language><dc:description>自行编写的离线阅读测试，包含中文路径、封面、插图和目录。所有文字仅供测试。</dc:description><meta name="cover" content="cover"/>{'<meta property="dcterms:modified">2026-10-18T00:00:00Z</meta>' if version == 3 else ''}</metadata><manifest>{''.join(manifest)}</manifest><spine toc="toc"><itemref idref="c0"/><itemref idref="c1"/><itemref idref="c2"/></spine></package>'''
    def html(body):
        return '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>远行日记</title></head><body>' + body + '</body></html>'
    entries['书籍/Text/cover.xhtml'] = html('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/封面.png"/></svg>')
    paragraphs = []
    for i in range(1, 111):
        paragraphs.append(f'<p>行{i:03d}。清晨，站台上的风吹开了日记。小遥背着书包，沿着海边的小路慢慢走向下一站。她把旅途中见到的光、云和笑容都记在这一页。这是一段专门编写的阅读测试文字。</p>')
        if i == 3:
            paragraphs.append('<img src="../Images/旅途%20插图.png" alt="旅途插图"/>')
    entries['书籍/Text/z 序章.xhtml'] = html('<h1 id="begin">序章·站台的风</h1>' + ''.join(paragraphs))
    entries['书籍/Text/a 后记.xhtml'] = html('<h1 id="end">后记·海边来信</h1><p>她终于来到海边，打开来自朋友的信。</p><p>故事在这里暂告一段落。EPUB 本地续读测试结束。</p>')
    entries['书籍/Images/封面.png'] = png(320, 480, [(60, 40, 100), (205, 190, 240), (160, 130, 210)])
    entries['书籍/Images/旅途 插图.png'] = png(640, 440, [(20, 70, 110), (130, 210, 230), (245, 225, 150)])
    output = OUT / f'旅途·中文与插图 EPUB{version}.epub'
    with zipfile.ZipFile(output, 'w') as archive:
        mimetype = zipfile.ZipInfo('mimetype', date_time=(2026, 10, 18, 0, 0, 0))
        archive.writestr(mimetype, 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        for name, content in entries.items():
            item = zipfile.ZipInfo(name, date_time=(2026, 10, 18, 0, 0, 0))
            archive.writestr(item, content.encode('utf-8') if isinstance(content, str) else content, compress_type=zipfile.ZIP_DEFLATED)
    return {'file': output.name, 'title': title, 'bytes': output.stat().st_size, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'chapters': len(toc)}


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    results = [build(3), build(2)]
    (OUT / '损坏文件.epub').write_bytes(b'This is not an EPUB archive.')
    (OUT / 'manifest.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(results, ensure_ascii=False, indent=2))
