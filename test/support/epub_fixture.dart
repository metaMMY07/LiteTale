import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// All text in these fixtures is self-authored. No downloaded books are used.
class EpubFixtureChapter {
  const EpubFixtureChapter({
    required this.path,
    required this.title,
    required this.body,
    this.linear = true,
  });
  final String path, title, body;
  final bool linear;
}

class EpubFixtureToc {
  const EpubFixtureToc(this.title, this.href);
  final String title, href;
}

Uint8List buildEpubFixture({
  bool epub3 = true,
  String title = '本地测试小说',
  String author = '测试作者',
  String description = '这是一段自行编写的 EPUB 导入测试。',
  List<EpubFixtureChapter> chapters = const [
    EpubFixtureChapter(
      path: 'Text/chapter.xhtml',
      title: '第一章',
      body: '<h1>第一章</h1><p>这是自行编写的测试正文。</p>',
    ),
  ],
  List<EpubFixtureToc>? toc,
  Map<String, Uint8List> resources = const {},
  String? coverPath,
  bool fixedLayout = false,
  String? encryptionXml,
  Map<String, String> additionalEntries = const {},
}) {
  final entries = <String, Uint8List>{
    'mimetype': Uint8List.fromList(utf8.encode('application/epub+zip')),
    'META-INF/container.xml': Uint8List.fromList(
      utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
    ),
  };
  final navigation =
      toc ??
      chapters
          .where((chapter) => chapter.linear)
          .map((chapter) => EpubFixtureToc(chapter.title, chapter.path))
          .toList();
  final manifest = <String>[];
  final spine = <String>[];
  for (var i = 0; i < chapters.length; i++) {
    final chapter = chapters[i];
    manifest.add(
      '<item id="c$i" href="${_escape(_href(chapter.path))}" media-type="application/xhtml+xml"/>',
    );
    spine.add('<itemref idref="c$i"${chapter.linear ? '' : ' linear="no"'}/>');
    entries['OPS/${chapter.path}'] = Uint8List.fromList(
      utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>${_escape(chapter.title)}</title></head>
<body>${chapter.body}</body></html>'''),
    );
  }
  var resourceIndex = 0;
  for (final entry in resources.entries) {
    final isCover = entry.key == coverPath;
    manifest.add(
      '<item id="${isCover ? 'cover' : 'r${resourceIndex++}'}" '
      'href="${_escape(_href(entry.key))}" media-type="${_mediaType(entry.key)}"'
      '${epub3 && isCover ? ' properties="cover-image"' : ''}/>',
    );
    entries['OPS/${entry.key}'] = entry.value;
  }
  if (epub3) {
    manifest.add(
      '<item id="nav" href="nav.xhtml" '
      'media-type="application/xhtml+xml" properties="nav"/>',
    );
    entries['OPS/nav.xhtml'] = Uint8List.fromList(
      utf8.encode('''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
${navigation.map((entry) => '<li><a href="${_escape(_href(entry.href))}">${_escape(entry.title)}</a></li>').join()}
</ol></nav></body></html>'''),
    );
  } else {
    manifest.add(
      '<item id="ncx" href="toc.ncx" '
      'media-type="application/x-dtbncx+xml"/>',
    );
    entries['OPS/toc.ncx'] = Uint8List.fromList(
      utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<navMap>
${navigation.indexed.map((entry) => '<navPoint id="p${entry.$1}"><navLabel><text>${_escape(entry.$2.title)}</text></navLabel><content src="${_escape(_href(entry.$2.href))}"/></navPoint>').join()}
</navMap></ncx>'''),
    );
  }
  entries['OPS/package.opf'] = Uint8List.fromList(
    utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="${epub3 ? '3.0' : '2.0'}" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">fixture-local-novel</dc:identifier>
<dc:title>${_escape(title)}</dc:title><dc:creator>${_escape(author)}</dc:creator>
<dc:language>zh-CN</dc:language><dc:description>${_escape(description)}</dc:description>
<dc:subject>轻小说</dc:subject><dc:subject>测试</dc:subject>
${coverPath != null && !epub3 ? '<meta name="cover" content="cover"/>' : ''}
${fixedLayout ? '<meta property="rendition:layout">pre-paginated</meta>' : ''}
</metadata><manifest>${manifest.join()}</manifest>
<spine${epub3 ? '' : ' toc="ncx"'}>${spine.join()}</spine></package>'''),
  );
  if (encryptionXml != null) {
    entries['META-INF/encryption.xml'] = Uint8List.fromList(
      utf8.encode(encryptionXml),
    );
  }
  for (final entry in additionalEntries.entries) {
    entries[entry.key] = Uint8List.fromList(utf8.encode(entry.value));
  }
  return encodeEpubFixtureEntries(entries);
}

Uint8List encodeEpubFixtureEntries(Map<String, Uint8List> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// A real one-pixel PNG suitable for Flutter image decoding in reader tests.
Uint8List epubFixturePng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _href(String path) => path
    .split('/')
    .map((part) => part.split('#').map(Uri.encodeComponent).join('#'))
    .join('/');

String _mediaType(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'ttf' => 'font/ttf',
    'otf' => 'font/otf',
    'css' => 'text/css',
    _ => 'application/octet-stream',
  };
}
