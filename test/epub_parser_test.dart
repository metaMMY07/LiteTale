import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/epub_parser.dart';

import 'support/epub_fixture.dart';

void main() {
  Matcher importError([String? messageContains]) =>
      isA<EpubImportException>().having(
        (error) => error.message,
        'message',
        messageContains == null ? isNotEmpty : contains(messageContains),
      );

  test('EPUB 3 reads metadata, spine, nav and original file digest', () {
    final bytes = buildEpubFixture();
    final book = parseEpubBook(bytes);
    expect(book.digest, sha256.convert(bytes).toString());
    expect(book.title, '本地测试小说');
    expect(book.author, '测试作者');
    expect(book.language, 'zh-CN');
    expect(book.subjects, ['轻小说', '测试']);
    expect(book.description, '这是一段自行编写的 EPUB 导入测试。');
    expect(book.chapters.single.title, '第一章');
    expect(book.chapters.single.href, 'OPS/Text/chapter.xhtml');
    expect(book.chapters.single.content, '第一章\n这是自行编写的测试正文。');
    expect(book.warnings, isEmpty);
  });

  test('EPUB 2 labels come from namespace-qualified NCX', () {
    final book = parseEpubBook(
      buildEpubFixture(
        epub3: false,
        toc: const [EpubFixtureToc('目录里的第一章', 'Text/chapter.xhtml')],
      ),
    );
    expect(book.chapters.single.title, '目录里的第一章');
  });

  test('spine wins over both ZIP/manifest order and reversed nav order', () {
    final files = _unzip(
      buildEpubFixture(
        chapters: const [
          EpubFixtureChapter(
            path: 'Text/a.xhtml',
            title: '甲',
            body: '<p>甲的正文</p>',
          ),
          EpubFixtureChapter(
            path: 'Text/b.xhtml',
            title: '乙',
            body: '<p>乙的正文</p>',
          ),
        ],
      ),
    );
    _replace(
      files,
      'OPS/package.opf',
      '<itemref idref="c0"/><itemref idref="c1"/>',
      '<itemref idref="c1"/><itemref idref="c0"/>',
    );
    final book = parseEpubBook(encodeEpubFixtureEntries(files));
    expect(book.chapters.map((chapter) => chapter.title), ['乙', '甲']);
    expect(book.chapters.map((chapter) => chapter.content), ['乙的正文', '甲的正文']);
  });

  test(
    'multiple fragment TOC entries split one file without lost prefix/duplicates',
    () {
      final book = parseEpubBook(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: '文字/一 卷.xhtml',
              title: '卷一',
              body:
                  '<p>目录锚点以前的序言。</p><section id="甲"><h1>第一节</h1>'
                  '<p>第一节正文。</p></section><section id="乙"><h2>第二节</h2>'
                  '<p>第二节正文。</p></section>',
            ),
          ],
          toc: const [
            EpubFixtureToc('第一节目录名', '文字/一 卷.xhtml#甲'),
            EpubFixtureToc('第二节目录名', '文字/一 卷.xhtml#乙'),
          ],
        ),
      );
      expect(book.chapters.length, 3);
      expect(book.chapters[0].content, '目录锚点以前的序言。');
      expect(book.chapters[1].title, '第一节目录名');
      expect(book.chapters[2].title, '第二节目录名');
      final text = book.chapters.map((chapter) => chapter.content).join('\n');
      expect('第一节正文'.allMatches(text).length, 1);
      expect('第二节正文'.allMatches(text).length, 1);
      expect(book.chapters[2].href, 'OPS/文字/一 卷.xhtml#%E4%B9%99');
    },
  );

  test('duplicate same anchor entries do not duplicate a chapter', () {
    final book = parseEpubBook(
      buildEpubFixture(
        chapters: const [
          EpubFixtureChapter(
            path: 'one.xhtml',
            title: '一',
            body: '<h1 id="one">一</h1><p>正文</p>',
          ),
        ],
        toc: const [
          EpubFixtureToc('第一章', 'one.xhtml#one'),
          EpubFixtureToc('重复第一章', 'one.xhtml#one'),
        ],
      ),
    );
    expect(book.chapters.length, 1);
    expect(book.chapters.single.title, '第一章');
  });

  test(
    'missing anchors preserve every paragraph and missing TOC falls back to headings',
    () {
      final files = _unzip(
        buildEpubFixture(
          toc: const [EpubFixtureToc('坏锚点', 'Text/chapter.xhtml#missing')],
        ),
      );
      final book = parseEpubBook(encodeEpubFixtureEntries(files));
      expect(book.chapters.single.content, contains('这是自行编写的测试正文。'));
      expect(book.chapters.single.title, '第一章');
      expect(book.warnings.join(), contains('锚点'));
      files.remove('OPS/nav.xhtml');
      final fallback = parseEpubBook(encodeEpubFixtureEntries(files));
      expect(fallback.chapters.single.title, '第一章');
      expect(fallback.chapters.single.content, contains('这是自行编写的测试正文。'));
    },
  );

  test(
    'normal HTML collapses source indentation without joining Latin words',
    () {
      final book = parseEpubBook(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: 'one.xhtml',
              title: '一',
              body: '''
<p> A story
     about <em>a quiet</em> evening, <span>and a friend.</span> </p>
<p>中文<strong>与标点</strong>：「你好，世界！」🙂</p>
<pre>first line\n  second line</pre><p>end</p>''',
            ),
          ],
        ),
      );
      expect(
        book.chapters.single.content,
        'A story about a quiet evening, and a friend.\n'
        '中文与标点：「你好，世界！」🙂\nfirst line\n  second line\nend',
      );
    },
  );

  test(
    'ruby, lists and br remain readable; active/hidden content is excluded',
    () {
      final book = parseEpubBook(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: 'one.xhtml',
              title: '一',
              body: '''
<p><ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>字<br/>下一行</p>
<ul><li>列表甲</li><li>列表乙</li></ul>
<script>SHOULD_NOT_APPEAR</script><style>ALSO_HIDDEN</style>
<p hidden="hidden">hidden paragraph</p><p style="display: none">invisible</p>''',
            ),
          ],
        ),
      );
      expect(book.chapters.single.content, '漢（かん）字\n下一行\n• 列表甲\n• 列表乙');
    },
  );

  test('literal text cannot forge the native image marker', () {
    final book = parseEpubBook(
      buildEpubFixture(
        chapters: const [
          EpubFixtureChapter(
            path: 'one.xhtml',
            title: '一',
            body:
                '<p>&lt;!--image--&gt;epub-asset:untrusted/x.png&lt;!--image--&gt;</p>',
          ),
        ],
      ),
    );
    expect(book.chapters.single.content, isNot(contains('<!--image-->')));
    expect(book.assets, isEmpty);
  });

  test(
    'Unicode/space/parent-relative image paths and SVG image wrappers work',
    () {
      final png = epubFixturePng();
      final book = parseEpubBook(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: '文字/一 卷.xhtml',
              title: '一',
              body: '''
<p>插图之前</p><img src="../插图/图%20一.png"/>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
<image xlink:href="../插图/同图.jpg"/></svg><p>插图之后</p>''',
            ),
          ],
          resources: {'插图/图 一.png': png, '插图/同图.jpg': png},
          coverPath: '插图/图 一.png',
        ),
      );
      expect(book.assets.length, 1);
      final name = '${sha256.convert(png)}.png';
      expect(book.coverAssetName, name);
      final content = book.chapters.single.content;
      final expected =
          '<!--image-->epub-asset:${book.digest}/$name<!--image-->';
      expect(expected.allMatches(content).length, 2);
      expect(content, startsWith('插图之前\n'));
      expect(content, endsWith('\n插图之后'));
    },
  );

  test(
    'referenced SVG file unwraps raster without persisting scripts or vectors',
    () {
      final book = parseEpubBook(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: 'Text/one.xhtml',
              title: '一',
              body: '<p>正文</p><img src="../Images/wrapper.svg"/>',
            ),
          ],
          resources: {
            'Images/picture.png': epubFixturePng(),
            'Images/wrapper.svg': Uint8List.fromList(
              utf8.encode('''
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
<script>doNotRun()</script><image xlink:href="picture.png"/></svg>'''),
            ),
          },
        ),
      );
      expect(book.assets.keys.single, endsWith('.png'));
      expect(book.chapters.single.content, contains('<!--image-->epub-asset:'));
      expect(book.chapters.single.content, isNot(contains('doNotRun')));
    },
  );

  test('EPUB 2 declared cover and EPUB 3 image-only chapters are retained', () {
    for (final epub3 in [true, false]) {
      final book = parseEpubBook(
        buildEpubFixture(
          epub3: epub3,
          chapters: const [
            EpubFixtureChapter(
              path: 'cover.xhtml',
              title: '封面',
              body: '<img src="Images/front.png"/>',
            ),
            EpubFixtureChapter(
              path: 'Text/one.xhtml',
              title: '一',
              body: '<p>正文</p>',
            ),
          ],
          resources: {'Images/front.png': epubFixturePng()},
          coverPath: 'Images/front.png',
        ),
      );
      expect(book.coverAssetName, isNotNull);
      expect(book.chapters.length, 2);
      expect(book.chapters.first.content, startsWith('<!--image-->'));
    }
  });

  test('inline base64 raster assets are bounded and supported', () {
    final png = epubFixturePng();
    final book = parseEpubBook(
      buildEpubFixture(
        chapters: [
          EpubFixtureChapter(
            path: 'one.xhtml',
            title: '一',
            body:
                '<p>内嵌图</p><img src="data:image/png;base64,${base64Encode(png)}"/>',
          ),
        ],
      ),
    );
    expect(book.assets.length, 1);
    expect(book.chapters.single.content, contains('<!--image-->'));
  });

  test(
    'missing/remote/vector images have readable fallback and no external assets',
    () {
      final book = parseEpubBook(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: 'one.xhtml',
              title: '一',
              body: '''
<p>正常正文</p><img src="missing.png" alt="缺图"/>
<img src="https://untrusted.invalid/remote.png" alt="远程图"/>
<img src="Images/vector.svg" alt="矢量图"/>''',
            ),
          ],
          resources: {
            'Images/vector.svg': Uint8List.fromList(
              utf8.encode('<svg><rect width="20" height="20"/></svg>'),
            ),
          },
        ),
      );
      expect(book.assets, isEmpty);
      expect(book.chapters.single.content, contains('〔缺图〕'));
      expect(book.chapters.single.content, contains('〔远程图〕'));
      expect(book.chapters.single.content, contains('〔矢量图〕'));
      expect(book.warnings, hasLength(3));
    },
  );

  test('image dimensions are checked before native decode', () {
    final tooWide = Uint8List.fromList(epubFixturePng());
    ByteData.sublistView(tooWide).setUint32(16, 200000);
    final book = parseEpubBook(
      buildEpubFixture(
        chapters: const [
          EpubFixtureChapter(
            path: 'one.xhtml',
            title: '一',
            body: '<p>正文</p><img src="huge.png" alt="大图"/>',
          ),
        ],
        resources: {'huge.png': tooWide},
      ),
    );
    expect(book.assets, isEmpty);
    expect(book.chapters.single.content, contains('〔大图〕'));
    expect(book.warnings.join(), contains('尺寸'));
  });

  test(
    'nav spine documents are excluded and nonlinear notes remain after main text',
    () {
      final files = _unzip(
        buildEpubFixture(
          chapters: const [
            EpubFixtureChapter(
              path: 'notes.xhtml',
              title: '脚注',
              body: '<p>注释内容</p>',
              linear: false,
            ),
            EpubFixtureChapter(
              path: 'main.xhtml',
              title: '正文',
              body: '<p>正文内容</p>',
            ),
          ],
        ),
      );
      _replace(
        files,
        'OPS/package.opf',
        '<spine>',
        '<spine><itemref idref="nav"/>',
      );
      final book = parseEpubBook(encodeEpubFixtureEntries(files));
      expect(book.chapters.map((chapter) => chapter.content), ['正文内容', '注释内容']);
    },
  );

  test('empty spine pages do not create phantom chapters', () {
    final book = parseEpubBook(
      buildEpubFixture(
        chapters: const [
          EpubFixtureChapter(
            path: 'empty.xhtml',
            title: '空页',
            body: '<p> </p>',
          ),
          EpubFixtureChapter(
            path: 'main.xhtml',
            title: '正文',
            body: '<p>有效正文</p>',
          ),
        ],
      ),
    );
    expect(book.chapters.length, 1);
    expect(book.chapters.single.content, '有效正文');
  });

  test(
    'UTF-16 document BOM and prefixed OPF/container namespaces are accepted',
    () {
      final files = _unzip(buildEpubFixture());
      final text = utf8.decode(files['OPS/Text/chapter.xhtml']!);
      final utf16 = ByteData(2 + text.codeUnits.length * 2)
        ..setUint16(0, 0xfeff, Endian.little);
      for (var i = 0; i < text.codeUnits.length; i++) {
        utf16.setUint16(2 + i * 2, text.codeUnits[i], Endian.little);
      }
      files['OPS/Text/chapter.xhtml'] = utf16.buffer.asUint8List();
      _replace(
        files,
        'META-INF/container.xml',
        '<container xmlns=',
        '<c:container xmlns:c=',
      );
      _replace(
        files,
        'META-INF/container.xml',
        '</container>',
        '</c:container>',
      );
      final book = parseEpubBook(encodeEpubFixtureEntries(files));
      expect(book.chapters.single.content, contains('这是自行编写的测试正文。'));
    },
  );

  test(
    'missing title uses the file label and HTML in metadata becomes plain text',
    () {
      final book = parseEpubBook(
        buildEpubFixture(
          title: '',
          author: '',
          description: '<p>第一句。</p><p>第二句。</p>',
        ),
        fallbackTitle: '导入文件名',
      );
      expect(book.title, '导入文件名');
      expect(book.author, '未知作者');
      expect(book.description, '第一句。第二句。');
    },
  );

  test('fixed-layout books produce a specific unsupported-format message', () {
    expect(
      () => parseEpubBook(buildEpubFixture(fixedLayout: true)),
      throwsA(importError('固定版式')),
    );
  });

  test(
    'DRM-protected reading resources are rejected; font obfuscation is ignored',
    () {
      const drm =
          '''<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
<EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
<CipherData><CipherReference URI="OPS/Text/chapter.xhtml"/></CipherData>
</EncryptedData></encryption>''';
      expect(
        () => parseEpubBook(buildEpubFixture(encryptionXml: drm)),
        throwsA(importError('DRM')),
      );
      const obfuscation =
          '''<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
<EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
<CipherData><CipherReference URI="OPS/Fonts/book.ttf"/></CipherData>
</EncryptedData></encryption>''';
      final book = parseEpubBook(
        buildEpubFixture(
          encryptionXml: obfuscation,
          resources: {
            'Fonts/book.ttf': Uint8List.fromList([1, 2, 3]),
          },
        ),
      );
      expect(book.chapters.single.content, contains('测试正文'));
      expect(book.warnings.join(), contains('混淆字体'));
      expect(book.assets, isEmpty);
    },
  );

  test(
    'missing or unsupported spine cannot silently import a truncated book',
    () {
      final missing = _unzip(buildEpubFixture())
        ..remove('OPS/Text/chapter.xhtml');
      expect(
        () => parseEpubBook(encodeEpubFixtureEntries(missing)),
        throwsA(importError('正文资源缺失')),
      );
      final unsupported = _unzip(buildEpubFixture());
      _replace(
        unsupported,
        'OPS/package.opf',
        'media-type="application/xhtml+xml"',
        'media-type="application/pdf"',
      );
      expect(
        () => parseEpubBook(encodeEpubFixtureEntries(unsupported)),
        throwsA(importError('正文格式')),
      );
    },
  );

  test('readable fallback for an unsupported spine resource is used', () {
    final files = _unzip(buildEpubFixture());
    _replace(
      files,
      'OPS/package.opf',
      '<manifest>',
      '<manifest><item id="foreign" '
          'href="unsupported.pdf" media-type="application/pdf" fallback="c0"/>',
    );
    _replace(
      files,
      'OPS/package.opf',
      '<itemref idref="c0"/>',
      '<itemref idref="foreign"/>',
    );
    final book = parseEpubBook(encodeEpubFixtureEntries(files));
    expect(book.chapters.single.content, contains('测试正文'));
  });

  test('invalid archives, missing packages and XML entities fail clearly', () {
    expect(
      () => parseEpubBook(Uint8List.fromList(utf8.encode('not a zip'))),
      throwsA(importError()),
    );
    final missing = _unzip(buildEpubFixture())..remove('OPS/package.opf');
    expect(
      () => parseEpubBook(encodeEpubFixtureEntries(missing)),
      throwsA(importError('缺少文件')),
    );
    final entity = _unzip(buildEpubFixture());
    _replace(
      entity,
      'OPS/package.opf',
      '<package ',
      '<!DOCTYPE package [<!ENTITY x "untrusted">]><package ',
    );
    expect(
      () => parseEpubBook(encodeEpubFixtureEntries(entity)),
      throwsA(importError('XML 实体')),
    );
  });

  for (final path in [
    '../escape.xhtml',
    '/absolute.xhtml',
    'C:/drive.xhtml',
    'a/./same.xhtml',
    'a//same.xhtml',
  ]) {
    test('unsafe ZIP path is rejected before decompression: $path', () {
      final files = _unzip(buildEpubFixture())..[path] = Uint8List(0);
      expect(
        () => parseEpubBook(encodeEpubFixtureEntries(files)),
        throwsA(importError('路径')),
      );
    });
  }

  test(
    'backslash ZIP paths are rejected even when encoder normally normalizes them',
    () {
      final files = _unzip(buildEpubFixture())..['a/bad.xhtml'] = Uint8List(0);
      final bytes = encodeEpubFixtureEntries(files);
      final data = ByteData.sublistView(bytes);
      for (final central in _centralEntries(bytes)) {
        final length = data.getUint16(central + 28, Endian.little);
        final name = utf8.decode(
          bytes.sublist(central + 46, central + 46 + length),
        );
        if (name == 'a/bad.xhtml') {
          final local = data.getUint32(central + 42, Endian.little);
          bytes[central + 47] = 0x5c;
          bytes[local + 31] = 0x5c;
        }
      }
      expect(() => parseEpubBook(bytes), throwsA(importError('路径')));
    },
  );

  test('case-colliding ZIP resources are rejected', () {
    final files =
        _unzip(buildEpubFixture())
          ..['OPS/case.txt'] = Uint8List(0)
          ..['OPS/CASE.TXT'] = Uint8List(0);
    expect(
      () => parseEpubBook(encodeEpubFixtureEntries(files)),
      throwsA(importError('冲突')),
    );
  });

  test('ZIP encryption flags are rejected before decompression', () {
    final bytes = Uint8List.fromList(buildEpubFixture());
    final central = _centralEntries(bytes).first;
    final data = ByteData.sublistView(bytes);
    data.setUint16(
      central + 8,
      data.getUint16(central + 8, Endian.little) | 1,
      Endian.little,
    );
    expect(() => parseEpubBook(bytes), throwsA(importError('加密')));
  });

  test(
    'symlink and local/central name mismatches are rejected before extraction',
    () {
      final bytes = Uint8List.fromList(buildEpubFixture());
      final central = _centralEntries(bytes).first;
      final data = ByteData.sublistView(bytes);
      data.setUint32(central + 38, 0xa000 << 16, Endian.little);
      expect(() => parseEpubBook(bytes), throwsA(importError('符号链接')));
      final mismatch = Uint8List.fromList(buildEpubFixture());
      mismatch[30] = 0x78;
      expect(() => parseEpubBook(mismatch), throwsA(importError('不一致')));
    },
  );

  test(
    'advertised ZIP expansion limit is enforced before any content read',
    () {
      final bytes = Uint8List.fromList(buildEpubFixture());
      final central = _centralEntries(bytes).first;
      ByteData.sublistView(
        bytes,
      ).setUint32(central + 24, 385 * 1024 * 1024, Endian.little);
      expect(() => parseEpubBook(bytes), throwsA(importError('384 MB')));
    },
  );

  test('actual deflate expansion cannot exceed a forged advertised size', () {
    final files = _unzip(buildEpubFixture());
    files['OPS/Text/chapter.xhtml'] = Uint8List.fromList(
      utf8.encode('<html><body><p>${'a' * 20000}</p></body></html>'),
    );
    final bytes = encodeEpubFixtureEntries(files);
    final data = ByteData.sublistView(bytes);
    for (final central in _centralEntries(bytes)) {
      final nameLength = data.getUint16(central + 28, Endian.little);
      final name = utf8.decode(
        bytes.sublist(central + 46, central + 46 + nameLength),
      );
      if (name == 'OPS/Text/chapter.xhtml') {
        expect(data.getUint16(central + 10, Endian.little), 8);
        data.setUint32(central + 24, 16, Endian.little);
      }
    }
    expect(() => parseEpubBook(bytes), throwsA(importError('实际解压')));
  });

  test(
    'CRC mismatch and an oversized chapter fail instead of returning partial text',
    () {
      final crc = Uint8List.fromList(buildEpubFixture());
      final entry = _centralEntries(crc).first;
      final data = ByteData.sublistView(crc);
      data.setUint32(entry + 16, 0x12345678, Endian.little);
      expect(() => parseEpubBook(crc), throwsA(importError('校验失败')));
      final files = _unzip(buildEpubFixture());
      files['OPS/Text/chapter.xhtml'] = Uint8List(8 * 1024 * 1024 + 1);
      expect(
        () => parseEpubBook(encodeEpubFixtureEntries(files)),
        throwsA(importError('文件过大')),
      );
    },
  );

  test(
    'too many ZIP entries is rejected without constructing every resource',
    () {
      final bytes = Uint8List.fromList(buildEpubFixture());
      final data = ByteData.sublistView(bytes);
      final eocd = bytes.length - 22;
      data.setUint16(eocd + 8, 10001, Endian.little);
      data.setUint16(eocd + 10, 10001, Endian.little);
      expect(() => parseEpubBook(bytes), throwsA(importError('文件数量')));
    },
  );

  test('dense or deeply nested markup is bounded before native rendering', () {
    final dense = buildEpubFixture(
      chapters: [
        EpubFixtureChapter(
          path: 'dense.xhtml',
          title: '密集排版',
          body: '<p>${'<span>x</span>' * 61000}</p>',
        ),
      ],
    );
    expect(() => parseEpubBook(dense), throwsA(importError('结构过于复杂')));
    final nested = buildEpubFixture(
      chapters: [
        EpubFixtureChapter(
          path: 'nested.xhtml',
          title: '嵌套排版',
          body: '${'<div>' * 260}<p>正文</p>${'</div>' * 260}',
        ),
      ],
    );
    expect(() => parseEpubBook(nested), throwsA(importError('嵌套过深')));
  });
}

Map<String, Uint8List> _unzip(Uint8List bytes) => {
  for (final file in ZipDecoder().decodeBytes(bytes))
    file.name: Uint8List.fromList(file.content as List<int>),
};

void _replace(
  Map<String, Uint8List> files,
  String path,
  String from,
  String to,
) {
  files[path] = Uint8List.fromList(
    utf8.encode(utf8.decode(files[path]!).replaceAll(from, to)),
  );
}

Iterable<int> _centralEntries(Uint8List bytes) sync* {
  final data = ByteData.sublistView(bytes);
  final eocd = bytes.length - 22;
  var at = data.getUint32(eocd + 16, Endian.little);
  final count = data.getUint16(eocd + 10, Endian.little);
  for (var i = 0; i < count; i++) {
    yield at;
    at +=
        46 +
        data.getUint16(at + 28, Endian.little) +
        data.getUint16(at + 30, Endian.little) +
        data.getUint16(at + 32, Endian.little);
  }
}
