import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../../models/reader_document.dart';
import 'epub_css.dart';
import 'epub_artwork_document.dart';
import 'epub_models.dart';
import 'epub_publication_document.dart';

const _maxEntries = 10000;
const _maxExpandedBytes = 384 * 1024 * 1024;
const _maxChapterBytes = 8 * 1024 * 1024;
const _maxXmlBytes = 2 * 1024 * 1024;
const _maxImageBytes = 20 * 1024 * 1024;
const _maxAssetBytes = 128 * 1024 * 1024;
const _maxTextCharacters = 32 * 1024 * 1024;
const _imageMarker = '<!--image-->';

/// Converts a reflowable EPUB to the existing native reader's text/image format.
///
/// This is deliberately synchronous so the library can run the entire operation
/// in one isolate. Nothing in an EPUB is executed or fetched from the network.
ParsedEpubBook parseEpubBook(Uint8List bytes, {String fallbackTitle = '本地书籍'}) {
  if (bytes.length > maxEpubInputBytes) {
    throw const EpubImportException('EPUB 文件过大，最多支持 128 MB');
  }
  try {
    return _EpubParser(bytes, fallbackTitle).parse();
  } on EpubImportException {
    rethrow;
  } on Object {
    throw const EpubImportException('EPUB 文件损坏或格式不受支持，请检查文件后重试');
  }
}

/// Reuses the bounded ZIP reader and path resolver. Never extracts to a public
/// directory or executes a publication's scripts.
EpubPublicationDocument readEpubPublication(
  Uint8List bytes,
  String href, {
  bool fixedLayout = false,
  String endHref = '',
}) {
  final parser = _EpubParser(bytes, '');
  final ref = _resolve('', href);
  if (ref == null) throw const EpubImportException('本地章节地址无效');
  final encrypted = <String>{};
  if (parser.zip.entries.containsKey('META-INF/encryption.xml')) {
    for (final element
        in parser
            ._xml('META-INF/encryption.xml')
            .descendants
            .whereType<XmlElement>()) {
      if (element.name.local == 'CipherReference') {
        final path = _resolve('', element.getAttribute('URI') ?? '')?.path;
        if (path != null) encrypted.add(path);
      }
    }
  }
  final builder = EpubPublicationBuilder(
    resolve: (base, url) => _resolve(base, url)?.path,
    read: (path) {
      if (encrypted.contains(path) || !parser.zip.entries.containsKey(path)) {
        return null;
      }
      final data = parser.zip.read(path, maxBytes: 20 * 1024 * 1024);
      final raster = _rasterExtension(data);
      if (raster != null && !_reasonableImageDimensions(data, raster)) {
        return null;
      }
      return data;
    },
  );
  final end = _resolve('', endHref);
  return builder.build(
    parser._html(ref.path, _maxChapterBytes),
    ref.path,
    fixedLayout: fixedLayout,
    startFragment: ref.fragment,
    endFragment: end?.path == ref.path ? end!.fragment : '',
  );
}

class _ZipEntry {
  const _ZipEntry({
    required this.path,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.size,
    required this.dataOffset,
  });
  final String path;
  final int method, crc, compressedSize, size, dataOffset;
}

/// Reads and bounds the central directory before touching compressed content.
/// The chunked inflater also enforces the actual output size, not just the ZIP's
/// advertised size. This avoids allocating a forged deflate stream in one call.
class _EpubZip {
  _EpubZip(this.bytes) : data = ByteData.sublistView(bytes) {
    _readDirectory();
  }
  final Uint8List bytes;
  final ByteData data;
  final entries = <String, _ZipEntry>{};

  int _u16(int offset) => data.getUint16(offset, Endian.little);
  int _u32(int offset) => data.getUint32(offset, Endian.little);

  void _bounds(int start, int length, [int? end]) {
    if (start < 0 || length < 0 || start + length > (end ?? bytes.length)) {
      throw const EpubImportException('EPUB 的 ZIP 目录或文件数据不完整');
    }
  }

  String _name(int start, int length, int flags) {
    _bounds(start, length);
    final nameBytes = Uint8List.sublistView(bytes, start, start + length);
    String name;
    try {
      name = utf8.decode(nameBytes);
    } on FormatException {
      if (flags & 0x800 != 0) rethrow;
      name = latin1.decode(nameBytes);
    }
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const EpubImportException('EPUB 含有不安全的文件路径');
    }
    final segments = name.split('/');
    if (segments.last.isEmpty) segments.removeLast();
    if (segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const EpubImportException('EPUB 含有不安全的文件路径');
    }
    return name;
  }

  void _readDirectory() {
    if (bytes.length < 22) {
      throw const EpubImportException('这不是有效的 EPUB 文件');
    }
    var eocd = -1;
    final earliest = math.max(0, bytes.length - 22 - 65535);
    for (var at = bytes.length - 22; at >= earliest; at--) {
      if (_u32(at) == 0x06054b50 && at + 22 + _u16(at + 20) == bytes.length) {
        eocd = at;
        break;
      }
    }
    if (eocd < 0) {
      throw const EpubImportException('这不是有效的 EPUB 文件，或文件尚未下载完整');
    }
    final count = _u16(eocd + 10);
    final directorySize = _u32(eocd + 12);
    final directoryOffset = _u32(eocd + 16);
    if (count == 0xffff ||
        directorySize == 0xffffffff ||
        directoryOffset == 0xffffffff) {
      throw const EpubImportException('暂不支持 ZIP64 格式的 EPUB，请重新导出为普通 EPUB');
    }
    if (_u16(eocd + 4) != 0 || _u16(eocd + 6) != 0 || _u16(eocd + 8) != count) {
      throw const EpubImportException('暂不支持分卷压缩的 EPUB');
    }
    if (count == 0 || count > _maxEntries) {
      throw const EpubImportException('EPUB 的文件数量超出支持范围');
    }
    _bounds(directoryOffset, directorySize, eocd);
    final directoryEnd = directoryOffset + directorySize;
    final seen = <String>{};
    var at = directoryOffset;
    var expanded = 0;
    for (var i = 0; i < count; i++) {
      _bounds(at, 46, directoryEnd);
      if (_u32(at) != 0x02014b50) {
        throw const EpubImportException('EPUB 的 ZIP 目录损坏');
      }
      final flags = _u16(at + 8);
      final method = _u16(at + 10);
      final compressed = _u32(at + 20);
      final size = _u32(at + 24);
      final nameLength = _u16(at + 28);
      final extraLength = _u16(at + 30);
      final commentLength = _u16(at + 32);
      final localOffset = _u32(at + 42);
      _bounds(at, 46 + nameLength + extraLength + commentLength, directoryEnd);
      final name = _name(at + 46, nameLength, flags);
      if (!seen.add(name.toLowerCase())) {
        throw const EpubImportException('EPUB 含有重名或互相冲突的文件路径');
      }
      if (flags & 0x41 != 0 || method == 99) {
        throw const EpubImportException('暂不支持带密码或 DRM 加密的 EPUB');
      }
      if (method != 0 && method != 8) {
        throw const EpubImportException('EPUB 使用了不受支持的压缩方式');
      }
      if (_u16(at + 34) != 0 ||
          localOffset == 0xffffffff ||
          compressed == 0xffffffff ||
          size == 0xffffffff) {
        throw const EpubImportException('暂不支持 ZIP64 或分卷压缩的 EPUB');
      }
      final mode = _u32(at + 38) >> 16;
      final fileType = mode & 0xf000;
      if (fileType != 0 && fileType != 0x8000 && fileType != 0x4000) {
        throw const EpubImportException('EPUB 含有符号链接或特殊文件，无法安全导入');
      }
      expanded += size;
      if (expanded > _maxExpandedBytes) {
        throw const EpubImportException('EPUB 解压后的内容过大，最多支持 384 MB');
      }
      _bounds(localOffset, 30, directoryOffset);
      if (_u32(localOffset) != 0x04034b50 ||
          _u16(localOffset + 6) & 0x41 != 0 ||
          _u16(localOffset + 8) != method) {
        throw const EpubImportException('EPUB 的压缩文件头无效或已加密');
      }
      final localNameLength = _u16(localOffset + 26);
      final localExtraLength = _u16(localOffset + 28);
      _bounds(
        localOffset,
        30 + localNameLength + localExtraLength,
        directoryOffset,
      );
      if (_name(localOffset + 30, localNameLength, flags) != name) {
        throw const EpubImportException('EPUB 的文件路径与目录不一致');
      }
      final dataOffset = localOffset + 30 + localNameLength + localExtraLength;
      _bounds(dataOffset, compressed, directoryOffset);
      if (method == 0 && size != compressed) {
        throw const EpubImportException('EPUB 的文件大小记录不一致');
      }
      if (!name.endsWith('/')) {
        entries[name] = _ZipEntry(
          path: name,
          method: method,
          crc: _u32(at + 16),
          compressedSize: compressed,
          size: size,
          dataOffset: dataOffset,
        );
      }
      at += 46 + nameLength + extraLength + commentLength;
    }
    if (at != directoryEnd) {
      throw const EpubImportException('EPUB 的 ZIP 目录不完整');
    }
  }

  Uint8List read(String path, {required int maxBytes}) {
    final entry = entries[path];
    if (entry == null) {
      throw EpubImportException('EPUB 缺少文件：$path');
    }
    if (entry.size > maxBytes) {
      throw EpubImportException('EPUB 内的文件过大：$path');
    }
    final compressed = Uint8List.sublistView(
      bytes,
      entry.dataOffset,
      entry.dataOffset + entry.compressedSize,
    );
    Uint8List result;
    if (entry.method == 0) {
      result = compressed;
    } else {
      final sink = _LimitedByteSink(math.min(maxBytes, entry.size));
      final inflater = ZLibDecoder(raw: true).startChunkedConversion(sink);
      for (var at = 0; at < compressed.length; at += 64 * 1024) {
        inflater.add(
          Uint8List.sublistView(
            compressed,
            at,
            math.min(at + 64 * 1024, compressed.length),
          ),
        );
      }
      inflater.close();
      result = sink.takeBytes();
    }
    if (result.length != entry.size || getCrc32(result) != entry.crc) {
      throw EpubImportException('EPUB 文件校验失败，请重新获取文件：$path');
    }
    return result;
  }
}

class _LimitedByteSink implements Sink<List<int>> {
  _LimitedByteSink(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> bytes) {
    if (_bytes.length + bytes.length > limit) {
      throw const EpubImportException('EPUB 的实际解压大小超出记录，无法导入');
    }
    _bytes.add(bytes);
  }

  @override
  void close() {}
  Uint8List takeBytes() => _bytes.takeBytes();
}

class _ManifestItem {
  const _ManifestItem(
    this.id,
    this.path,
    this.mediaType,
    this.properties,
    this.fallback,
  );
  final String id, path, mediaType, fallback;
  final Set<String> properties;
}

class _Reference {
  const _Reference(this.path, this.fragment);
  final String path, fragment;
}

class _TocEntry {
  const _TocEntry(this.title, this.reference);
  final String title;
  final _Reference reference;
}

class _SpineItem {
  const _SpineItem(this.item, this.nonlinear, this.fixedLayout);
  final _ManifestItem item;
  final bool nonlinear;
  final bool fixedLayout;
}

class _EpubParser {
  _EpubParser(this.bytes, this.fallbackTitle) : zip = _EpubZip(bytes);
  final Uint8List bytes;
  final String fallbackTitle;
  // Import needs the book identity; projecting a chapter does not. The owned
  // archive is verified by the library and each ZIP entry still checks CRC and
  // bounds. Do not hash the entire book again for an unused constructor field.
  late final String digest = sha256.convert(bytes).toString();
  final _EpubZip zip;
  final warnings = <String>[];
  final manifest = <String, _ManifestItem>{};
  final assets = <String, Uint8List>{};
  final _assetForPath = <String, String?>{};
  final _encryptedFonts = <String>{};
  final _cssFiles = <String, String?>{};
  final _cssSheets = EpubCssSheetCache();
  var _cssFileWeight = 0;
  var _assetSize = 0;
  var _textSize = 0;

  void _warn(String value) {
    if (warnings.length < 24 && !warnings.contains(value)) warnings.add(value);
  }

  ParsedEpubBook parse() {
    if (zip.entries.containsKey('mimetype')) {
      final type = utf8.decode(zip.read('mimetype', maxBytes: 128)).trim();
      if (type != 'application/epub+zip') {
        throw const EpubImportException('文件的 EPUB 类型标记不正确');
      }
    } else {
      _warn('文件缺少 EPUB 类型标记，已按出版物目录读取。');
    }
    final container = _xml('META-INF/container.xml');
    final roots = _elements(container, 'rootfile').toList();
    if (roots.isEmpty) {
      throw const EpubImportException('EPUB 缺少出版物目录');
    }
    final root = roots.firstWhere(
      (element) =>
          element.getAttribute('media-type') == 'application/oebps-package+xml',
      orElse: () => roots.first,
    );
    final opfRef = _resolve('', root.getAttribute('full-path') ?? '');
    if (opfRef == null || opfRef.path.isEmpty) {
      throw const EpubImportException('EPUB 的出版物目录路径无效');
    }
    final packagePath = opfRef.path;
    final package = _xml(packagePath);
    if (package.rootElement.name.local != 'package') {
      throw const EpubImportException('EPUB 的出版物目录无效');
    }
    final metadata = _first(package, 'metadata');
    final metadataElements = metadata?.childElements.toList() ?? <XmlElement>[];
    String metadataText(String name) => _plain(
      metadataElements
              .where((element) => element.name.local == name)
              .map((element) => element.innerText)
              .firstOrNull ??
          '',
    );
    final layout = metadataElements.where(
      (element) =>
          element.name.local == 'meta' &&
          (element.getAttribute('property') == 'rendition:layout' ||
              element.getAttribute('name') == 'fixed-layout'),
    );
    final fixedLayout = layout.any(
      (element) =>
          element.innerText.trim().toLowerCase() == 'pre-paginated' ||
          element.getAttribute('content')?.toLowerCase() == 'true',
    );
    final manifestElement = _first(package, 'manifest');
    if (manifestElement == null) {
      throw const EpubImportException('EPUB 缺少资源清单');
    }
    for (final element in manifestElement.childElements) {
      if (element.name.local != 'item') continue;
      final id = element.getAttribute('id')?.trim() ?? '';
      final reference = _resolve(
        packagePath,
        element.getAttribute('href') ?? '',
      );
      if (id.isEmpty || manifest.containsKey(id)) {
        throw const EpubImportException('EPUB 的资源编号无效或重复');
      }
      if (reference == null) {
        _warn('已忽略书中引用的外部网络资源。');
        continue;
      }
      manifest[id] = _ManifestItem(
        id,
        reference.path,
        element.getAttribute('media-type')?.toLowerCase().trim() ?? '',
        _tokens(element.getAttribute('properties')),
        element.getAttribute('fallback') ?? '',
      );
    }
    _checkEncryption();
    final spineElement = _first(package, 'spine');
    if (spineElement == null) {
      throw const EpubImportException('EPUB 缺少正文阅读顺序');
    }
    final toc = _readToc(spineElement.getAttribute('toc'));
    final guideReferences = _elements(package, 'reference').toList();
    final navPaths =
        manifest.values
            .where((item) => item.properties.contains('nav'))
            .map((item) => item.path)
            .toSet();
    for (final reference in guideReferences) {
      if (_tokens(reference.getAttribute('type')).contains('toc')) {
        final target = _resolve(
          packagePath,
          reference.getAttribute('href') ?? '',
        );
        if (target != null) navPaths.add(target.path);
      }
    }
    final spine = <_SpineItem>[];
    final seenPaths = <String>{};
    for (final element in spineElement.childElements) {
      if (element.name.local != 'itemref') continue;
      final properties = _tokens(element.getAttribute('properties'));
      var item = manifest[element.getAttribute('idref')];
      final visited = <String>{};
      while (item != null && !_isReadable(item)) {
        if (!visited.add(item.id) || item.fallback.isEmpty) {
          throw const EpubImportException('EPUB 含有当前文字阅读器不支持的正文格式');
        }
        item = manifest[item.fallback];
      }
      if (item == null || !zip.entries.containsKey(item.path)) {
        throw const EpubImportException('EPUB 的正文资源缺失，无法完整导入');
      }
      if (navPaths.contains(item.path) || !seenPaths.add(item.path)) continue;
      spine.add(
        _SpineItem(
          item,
          element.getAttribute('linear') == 'no',
          properties.contains('rendition:layout-pre-paginated') ||
              fixedLayout &&
                  !properties.contains('rendition:layout-reflowable'),
        ),
      );
    }
    if (spine.isEmpty) {
      throw const EpubImportException('EPUB 没有可阅读的正文');
    }
    final cover = _cover(packagePath, metadataElements, guideReferences, spine);
    final chapters = <EpubChapterData>[];
    final artworkBuilder = EpubArtworkBuilder(
      resolve: (base, href) => _resolve(base, href)?.path,
      readCss: _readCss,
      readResource: (path) {
        if (!zip.entries.containsKey(path) || _encryptedFonts.contains(path)) {
          return null;
        }
        try {
          final bytes = zip.read(path, maxBytes: 8 * 1024 * 1024);
          final raster = _rasterExtension(bytes);
          if (raster != null && !_reasonableImageDimensions(bytes, raster)) {
            return null;
          }
          return bytes;
        } on Object {
          return null;
        }
      },
    );
    // Non-linear notes and appendices remain readable, without interrupting the
    // main spine sequence. Navigation documents have already been excluded.
    final ordered = [
      ...spine.where((item) => !item.nonlinear),
      ...spine.where((item) => item.nonlinear),
    ];
    for (final spineItem in ordered) {
      final item = spineItem.item;
      final document = _html(item.path, _maxChapterBytes);
      final rendered = _render(document, item.path);
      if (rendered.content.trim().isEmpty) continue;
      var defaultTitle = rendered.title;
      if (defaultTitle.isEmpty) {
        defaultTitle =
            spineItem.nonlinear ? '附录' : '第 ${chapters.length + 1} 章';
      }
      final boundaries = <int, _TocEntry>{};
      for (final entry in toc.where(
        (entry) => entry.reference.path == item.path,
      )) {
        final fragment = entry.reference.fragment;
        final position = fragment.isEmpty ? 0 : rendered.anchors[fragment];
        if (position == null) {
          _warn('部分目录锚点缺失，已保留对应正文。');
          continue;
        }
        boundaries[position] = entry;
      }
      boundaries.putIfAbsent(
        0,
        () => _TocEntry(defaultTitle, _Reference(item.path, '')),
      );
      final positions = boundaries.keys.toList()..sort();
      // Do not collapse several independently addressable sections into art.
      final artwork =
          positions.length == 1
              ? artworkBuilder.build(document, item.path)
              : null;
      for (var i = 0; i < positions.length; i++) {
        final start = positions[i];
        final end =
            i + 1 < positions.length
                ? positions[i + 1]
                : rendered.content.length;
        final rawSection = rendered.content.substring(start, end);
        final content = rawSection.trim();
        if (content.isEmpty) continue;
        final leading = rawSection.length - rawSection.trimLeft().length;
        final trailing = rawSection.length - rawSection.trimRight().length;
        final section = rendered.document.slice(
          start + leading,
          end - trailing,
        );
        _textSize += content.length;
        if (_textSize > _maxTextCharacters || chapters.length >= 20000) {
          throw const EpubImportException('EPUB 的正文或章节数量过大，无法导入');
        }
        final entry = boundaries[start]!;
        chapters.add(
          EpubChapterData(
            title: entry.title.isEmpty ? defaultTitle : entry.title,
            href:
                item.path +
                (entry.reference.fragment.isEmpty
                    ? ''
                    : '#${Uri.encodeComponent(entry.reference.fragment)}'),
            content: section.content,
            document: section,
            artwork: artwork,
            fixedLayout: spineItem.fixedLayout,
          ),
        );
      }
    }
    if (chapters.isEmpty) {
      throw const EpubImportException('EPUB 没有可阅读的文字或插图');
    }
    final authors =
        metadataElements
            .where((element) => element.name.local == 'creator')
            .map((element) => _plain(element.innerText))
            .where((value) => value.isNotEmpty)
            .toSet();
    final title = metadataText('title');
    return ParsedEpubBook(
      digest: digest,
      title:
          title.isNotEmpty
              ? title
              : (fallbackTitle.trim().isEmpty ? '本地书籍' : fallbackTitle.trim()),
      author: authors.isEmpty ? '未知作者' : authors.join(' / '),
      description: metadataText('description'),
      language:
          metadataText('language').isEmpty ? 'und' : metadataText('language'),
      subjects:
          metadataElements
              .where((element) => element.name.local == 'subject')
              .map((element) => _plain(element.innerText))
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList(),
      chapters: chapters,
      assets: assets,
      coverAssetName: cover,
      warnings: warnings,
    );
  }

  bool _isReadable(_ManifestItem item) => const {
    'application/xhtml+xml',
    'text/html',
    'image/svg+xml',
  }.contains(item.mediaType);

  String _text(String path, int limit) =>
      _decode(zip.read(path, maxBytes: limit));

  XmlDocument _xml(String path) {
    final source = _text(path, _maxXmlBytes);
    if (RegExp(r'<!ENTITY\s', caseSensitive: false).hasMatch(source)) {
      throw const EpubImportException('EPUB 含有不受支持的 XML 实体定义');
    }
    return XmlDocument.parse(source);
  }

  dom.Document _html(String path, int limit) {
    final source = _text(path, limit);
    // Excessively dense markup is not useful to the text reader and can make a
    // small compressed chapter allocate a disproportionately large DOM tree.
    if (RegExp('<').allMatches(source).take(120001).length > 120000) {
      throw const EpubImportException('EPUB 单章的排版结构过于复杂，无法导入');
    }
    return html.parse(source);
  }

  void _checkEncryption() {
    if (!zip.entries.containsKey('META-INF/encryption.xml')) return;
    final encryption = _xml('META-INF/encryption.xml');
    for (final element in _elements(encryption, 'EncryptedData')) {
      final algorithm =
          _first(element, 'EncryptionMethod')?.getAttribute('Algorithm') ?? '';
      final uri = _first(element, 'CipherReference')?.getAttribute('URI') ?? '';
      final reference = _resolve('', uri);
      final item =
          manifest.values
              .where((item) => item.path == reference?.path)
              .firstOrNull;
      final isFont =
          item != null &&
          (item.mediaType.startsWith('font/') ||
              item.mediaType.contains('font') ||
              RegExp(
                r'\.(ttf|otf|woff2?)$',
                caseSensitive: false,
              ).hasMatch(item.path));
      if (reference == null ||
          !isFont ||
          !const {
            'http://www.idpf.org/2008/embedding',
            'http://ns.adobe.com/pdf/enc#RC',
          }.contains(algorithm)) {
        throw const EpubImportException('这本 EPUB 的正文或资源受 DRM 加密保护，暂不支持导入');
      }
      _encryptedFonts.add(reference.path);
      _warn('书内混淆字体已忽略，正文使用你选择的阅读字体。');
    }
  }

  List<_TocEntry> _readToc(String? ncxId) {
    final result = <_TocEntry>[];
    final seen = <String>{};
    void add(String title, String href, String base) {
      final reference = _resolve(base, href);
      if (reference == null || reference.path.isEmpty) return;
      final key = '${reference.path}#${reference.fragment}';
      if (seen.add(key)) result.add(_TocEntry(_plain(title), reference));
    }

    for (final item in manifest.values.where(
      (item) => item.properties.contains('nav'),
    )) {
      try {
        final document = _html(item.path, _maxXmlBytes);
        final navigation = document.querySelectorAll('nav');
        final toc =
            navigation
                .where(
                  (nav) =>
                      _tokens(_attribute(nav, 'type')).contains('toc') ||
                      _tokens(nav.attributes['role']).contains('doc-toc'),
                )
                .firstOrNull ??
            navigation.firstOrNull;
        if (toc != null) {
          for (final link in toc.querySelectorAll('a[href]')) {
            add(link.text, link.attributes['href']!, item.path);
          }
        }
      } on Object {
        _warn('EPUB 3 目录无法读取，已尝试备用目录。');
      }
      if (result.isNotEmpty) return result;
    }
    final ncx =
        manifest[ncxId] ??
        manifest.values
            .where((item) => item.mediaType == 'application/x-dtbncx+xml')
            .firstOrNull;
    if (ncx != null) {
      try {
        final document = _xml(ncx.path);
        for (final point in _elements(document, 'navPoint')) {
          final label = _first(point, 'navLabel');
          final content =
              point.childElements
                  .where((element) => element.name.local == 'content')
                  .firstOrNull;
          if (content != null) {
            add(
              label?.innerText ?? '',
              content.getAttribute('src') ?? '',
              ncx.path,
            );
          }
        }
      } on Object {
        _warn('备用目录无法读取，已按正文阅读顺序生成章节。');
      }
    }
    return result;
  }

  String? _cover(
    String packagePath,
    List<XmlElement> metadata,
    List<XmlElement> guide,
    List<_SpineItem> spine,
  ) {
    final candidates = <String>[];
    candidates.addAll(
      manifest.values
          .where((item) => item.properties.contains('cover-image'))
          .map((item) => item.path),
    );
    for (final element in metadata) {
      if (element.name.local == 'meta' &&
          element.getAttribute('name')?.toLowerCase() == 'cover') {
        final item = manifest[element.getAttribute('content')];
        if (item != null) candidates.add(item.path);
      }
    }
    for (final reference in guide) {
      if (_tokens(reference.getAttribute('type')).contains('cover')) {
        final target = _resolve(
          packagePath,
          reference.getAttribute('href') ?? '',
        );
        if (target != null) candidates.add(target.path);
      }
    }
    candidates.addAll(
      manifest.values
          .where(
            (item) => RegExp(
              r'(^|[/_.-])cover([/_.-]|$)',
              caseSensitive: false,
            ).hasMatch('${item.id}/${item.path}'),
          )
          .map((item) => item.path),
    );
    if (spine.isNotEmpty) {
      final first = spine.first.item;
      if (RegExp(
        r'cover|封面',
        caseSensitive: false,
      ).hasMatch('${first.id}/${first.path}')) {
        candidates.add(first.path);
      }
    }
    for (final path in candidates.toSet()) {
      final image = _asset(path, warn: false);
      if (image != null) return image;
      if (RegExp(
            r'\.(xhtml|html?|svg)$',
            caseSensitive: false,
          ).hasMatch(path) &&
          zip.entries.containsKey(path)) {
        try {
          final document = _html(path, _maxChapterBytes);
          for (final element in document.querySelectorAll('img, image')) {
            final value =
                element.localName == 'img'
                    ? element.attributes['src']
                    : _attribute(element, 'href');
            final resolved = _resolve(path, value ?? '');
            if (resolved == null) continue;
            final cover = _asset(resolved.path, warn: false);
            if (cover != null) return cover;
          }
        } on Object {
          // Cover failure must not prevent importing the readable text.
        }
      }
    }
    return null;
  }

  String? _asset(String path, {bool warn = true}) {
    if (_assetForPath.containsKey(path)) return _assetForPath[path];
    if (!zip.entries.containsKey(path) || _encryptedFonts.contains(path)) {
      if (warn) _warn('部分插图文件缺失，已保留其余正文与插图。');
      if (warn) _assetForPath[path] = null;
      return null;
    }
    final bytes = zip.read(path, maxBytes: _maxImageBytes);
    final name = _saveRaster(bytes, warn: warn);
    if (name != null || warn) _assetForPath[path] = name;
    return name;
  }

  String? _saveRaster(Uint8List bytes, {bool warn = true}) {
    final extension = _rasterExtension(bytes);
    if (extension == null) {
      if (warn) _warn('部分插图不是支持的位图格式，已保留替代文字。');
      return null;
    }
    if (!_reasonableImageDimensions(bytes, extension)) {
      if (warn) _warn('部分插图尺寸过大或损坏，已保留替代文字。');
      return null;
    }
    final name = '${sha256.convert(bytes)}.$extension';
    if (!assets.containsKey(name)) {
      if (_assetSize + bytes.length > _maxAssetBytes) {
        throw const EpubImportException('EPUB 引用的插图过大，最多支持 128 MB');
      }
      _assetSize += bytes.length;
      assets[name] = Uint8List.fromList(bytes);
    }
    return name;
  }

  String? _image(String base, String value, [Set<String>? visited]) {
    if (value.startsWith('data:')) {
      if (value.length > _maxImageBytes * 4 ~/ 3 + 512) {
        throw const EpubImportException('EPUB 内嵌的插图过大');
      }
      try {
        final uri = UriData.parse(value);
        if (!uri.mimeType.startsWith('image/')) return null;
        final bytes = uri.contentAsBytes();
        if (bytes.length > _maxImageBytes) {
          throw const EpubImportException('EPUB 内嵌的插图过大');
        }
        return _saveRaster(bytes);
      } on EpubImportException {
        rethrow;
      } on Object {
        _warn('部分内嵌插图损坏，已保留替代文字。');
        return null;
      }
    }
    final reference = _resolve(base, value);
    if (reference == null) {
      _warn('已忽略书中引用的外部网络插图。');
      return null;
    }
    final path = reference.path;
    if (path.toLowerCase().endsWith('.svg') && zip.entries.containsKey(path)) {
      final chain = visited ?? <String>{};
      if (chain.length >= 4 || !chain.add(path)) return null;
      final svg = _html(path, _maxXmlBytes);
      for (final element in svg.querySelectorAll('image')) {
        final image = _image(path, _attribute(element, 'href') ?? '', chain);
        if (image != null) return image;
      }
      _warn('部分矢量插图无法转换，已保留替代文字。');
      return null;
    }
    return _asset(path);
  }

  _RenderedDocument _render(dom.Document document, String path) {
    final writer = _TextWriter();
    final anchors = <String, int>{};
    final css = EpubCssCascade.fromDocument(
      document,
      path,
      readLocalCss: _readCss,
      resolveLocalPath: (base, href) => _resolve(base, href)?.path,
      onWarning: _warn,
      sheetCache: _cssSheets,
    );
    final darkCss = EpubCssCascade.fromDocument(
      document,
      path,
      readLocalCss: _readCss,
      resolveLocalPath: (base, href) => _resolve(base, href)?.path,
      onWarning: _warn,
      sheetCache: _cssSheets,
      dark: true,
    );
    ReaderInlineStyle inline(dom.Element e) =>
        css.styleFor(e).inline.withPalette(darkCss.styleFor(e).inline);
    ReaderBlockStyle blockStyle(dom.Element e) => _copyBlockStyle(
      css.styleFor(e).block,
      box: css.styleFor(e).block.box.withPalette(darkCss.styleFor(e).block.box),
    );
    final firstLetters = <dom.Element>{};
    final listNumbers = <dom.Element, int>{};
    void walk(dom.Node node, {bool pre = false, int depth = 0}) {
      if (node is dom.Text) {
        final parent = node.parent;
        if (parent is dom.Element && node.data.trim().isNotEmpty) {
          dom.Element? ancestor = parent;
          while (ancestor != null) {
            final initial = css.firstLetterStyleFor(ancestor);
            if (initial != null && firstLetters.add(ancestor)) {
              final at = node.data.indexOf(RegExp(r'\S'));
              final first = String.fromCharCode(
                node.data.substring(at).runes.first,
              );
              writer.text(node.data.substring(0, at), style: inline(parent));
              writer.text(
                first,
                style: initial.withPalette(
                  darkCss.firstLetterStyleFor(ancestor) ?? initial,
                ),
              );
              writer.text(
                node.data.substring(at + first.length),
                style: inline(parent),
              );
              return;
            }
            if (css.styleFor(ancestor).isBlock) break;
            ancestor =
                ancestor.parent is dom.Element
                    ? ancestor.parent as dom.Element
                    : null;
          }
        }
        writer.text(
          node.data,
          pre: pre,
          style:
              parent is dom.Element
                  ? inline(parent)
                  : const ReaderInlineStyle(),
        );
        return;
      }
      if (node is! dom.Element) return;
      if (depth > 256) {
        throw const EpubImportException('EPUB 单章的排版嵌套过深，无法导入');
      }
      final tag = node.localName ?? '';
      if (const {
            'head',
            'script',
            'style',
            'iframe',
            'audio',
            'video',
            'canvas',
            'form',
            'input',
            'button',
            'rt',
            'rp',
          }.contains(tag) ||
          node.attributes.containsKey('hidden') ||
          node.attributes['aria-hidden'] == 'true') {
        return;
      }
      final style = css.styleFor(node);
      if (style.hidden) return;
      final isImage = tag == 'img' || tag == 'image' || tag == 'object';
      final isBlock = style.isBlock && !isImage;
      if (isBlock) writer.beginBlock(blockStyle(node));
      final anchor =
          node.attributes['id'] ??
          (tag == 'a' ? node.attributes['name'] : null);
      if (anchor != null && anchor.isNotEmpty) {
        anchors.putIfAbsent(anchor, () => writer.length);
      }
      if (tag == 'br') {
        writer.lineBreak(inline(node));
        if (isBlock) writer.endBlock();
        return;
      }
      if (tag == 'img' || tag == 'image' || tag == 'object') {
        final value =
            tag == 'img'
                ? node.attributes['src']
                : tag == 'object'
                ? node.attributes['data']
                : _attribute(node, 'href');
        final image = _image(path, value ?? '');
        if (image != null) {
          writer.image(epubAssetUrl(digest, image), blockStyle(node));
        } else {
          final alt = node.attributes['alt'] ?? node.attributes['aria-label'];
          if (style.isBlock) writer.beginBlock(blockStyle(node));
          if (alt != null) writer.text('〔$alt〕', style: inline(node));
          if (style.isBlock) writer.endBlock();
        }
        if (isBlock) writer.endBlock();
        return;
      }
      if (tag == 'tr') {
        final cells =
            node.children
                .where((e) => e.localName == 'td' || e.localName == 'th')
                .toList();
        if (cells.isNotEmpty &&
            cells.length <= 24 &&
            !cells.any(
              (c) =>
                  c.attributes.containsKey('rowspan') ||
                  c.attributes.containsKey('colspan'),
            )) {
          final parsed = <ReaderTableCell>[];
          for (final cell in cells) {
            final cellWriter = _TextWriter();
            void cellText(dom.Node n) {
              if (n is dom.Text) {
                cellWriter.text(
                  n.data,
                  style:
                      n.parent is dom.Element
                          ? inline(n.parent as dom.Element)
                          : inline(cell),
                );
              } else if (n is dom.Element &&
                  !const {
                    'script',
                    'style',
                    'iframe',
                    'table',
                  }.contains(n.localName) &&
                  !css.styleFor(n).hidden) {
                if (n.localName == 'br') cellWriter.lineBreak(inline(n));
                for (final c in n.nodes) {
                  cellText(c);
                }
              }
            }

            for (final child in cell.nodes) {
              cellText(child);
            }
            final runs = <ReaderRun>[];
            for (final b in cellWriter.document.blocks) {
              if (runs.isNotEmpty) {
                runs.add(ReaderRun(' ', style: inline(cell)));
              }
              runs.addAll(b.runs);
            }
            parsed.add(ReaderTableCell(runs: runs, style: blockStyle(cell)));
          }
          writer.tableRow(parsed);
          if (isBlock) writer.endBlock();
          return;
        }
        if (cells.isNotEmpty) {
          _warn('复杂合并单元格表格已按正文顺序显示。');
        }
      }
      if (tag == 'li') {
        final parent = node.parent;
        var marker = '• ';
        if (parent is dom.Element && parent.localName == 'ol') {
          if (!listNumbers.containsKey(node)) {
            var number = (int.tryParse(parent.attributes['start'] ?? '') ?? 1)
                .clamp(-10000, 10000);
            for (final item in parent.children.where(
              (e) => e.localName == 'li',
            )) {
              number = (int.tryParse(item.attributes['value'] ?? '') ?? number)
                  .clamp(-10000, 10000);
              listNumbers[item] = number++;
            }
          }
          marker = '${listNumbers[node]}. ';
        }
        writer.text(marker, style: inline(node));
      }
      if (tag == 'td' || tag == 'th') writer.text(' ', style: style.inline);
      for (final child in node.nodes) {
        walk(child, pre: style.preformatted, depth: depth + 1);
      }
      if (tag == 'ruby') {
        final annotations = node
            .querySelectorAll('rt')
            .map((element) => _plain(element.text))
            .where((value) => value.isNotEmpty)
            .join(' ');
        if (annotations.isNotEmpty) {
          writer.text('（$annotations）', style: inline(node));
        }
      }
      if (isBlock) writer.endBlock();
    }

    for (final node in document.nodes) {
      walk(node);
    }
    var title = '';
    for (final heading in document.querySelectorAll('h1, h2, h3')) {
      title = _plain(heading.text);
      if (title.isNotEmpty) break;
    }
    title =
        title.isEmpty
            ? _plain(document.querySelector('title')?.text ?? '')
            : title;
    final renderedDocument = writer.document;
    final length = renderedDocument.content.length;
    return _RenderedDocument(renderedDocument, {
      for (final entry in anchors.entries)
        entry.key: entry.value.clamp(0, length),
    }, title);
  }

  String? _readCss(String path) {
    if (_cssFiles.containsKey(path)) {
      final value = _cssFiles.remove(path);
      _cssFiles[path] = value;
      return value;
    }
    final source =
        zip.entries.containsKey(path) ? _text(path, 512 * 1024) : null;
    final weight = (source?.length ?? 0) * 2;
    while (_cssFiles.isNotEmpty &&
        (_cssFiles.length >= 32 || _cssFileWeight + weight > 2 * 1024 * 1024)) {
      final removed = _cssFiles.remove(_cssFiles.keys.first);
      _cssFileWeight -= (removed?.length ?? 0) * 2;
    }
    _cssFiles[path] = source;
    _cssFileWeight += weight;
    return source;
  }
}

class _RenderedDocument {
  const _RenderedDocument(this.document, this.anchors, this.title);
  final ReaderDocument document;
  String get content => document.content;
  final String title;
  final Map<String, int> anchors;
}

class _TextWriter {
  final _buffer = StringBuffer();
  final _blocks = <ReaderBlock>[];
  final _runs = <_PendingRun>[];
  final _contexts = <_BlockContext>[];
  ReaderBlockStyle? _runBlockStyle;
  bool _lineStart = true;
  bool _pendingSpace = false;
  int get length => _buffer.length;

  void _append(String value, {ReaderInlineStyle? style}) {
    if (_buffer.length + value.length > _maxChapterBytes * 2) {
      throw const EpubImportException('EPUB 单章转换后的正文过大');
    }
    _buffer.write(value);
    if (style != null && value.isNotEmpty) {
      _runBlockStyle ??= _effectiveBlockStyle();
      if (_runs.isNotEmpty && _sameStyle(_runs.last.style, style)) {
        _runs.last.text.write(value);
      } else {
        _runs.add(_PendingRun(style, value));
      }
    }
    if (value.isNotEmpty) _lineStart = value.endsWith('\n');
  }

  void text(
    String value, {
    bool pre = false,
    ReaderInlineStyle style = const ReaderInlineStyle(),
  }) {
    // Text must never be interpreted as the reader's trusted image separator.
    value = value.replaceAll(_imageMarker, '＜!--image--＞');
    if (pre) {
      _pendingSpace = false;
      _append(
        value.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
        style: style,
      );
      return;
    }
    final normal = value.replaceAll(RegExp(r'[\t\n\f\r \u00a0]+'), ' ');
    final body = normal.trim();
    if (body.isEmpty) {
      if (!_lineStart && normal.isNotEmpty) _pendingSpace = true;
      return;
    }
    if (!_lineStart && (_pendingSpace || normal.startsWith(' '))) {
      _append(' ', style: style);
    }
    _append(body, style: style);
    _pendingSpace = normal.endsWith(' ');
  }

  void newline() {
    _pendingSpace = false;
    if (!_lineStart && _buffer.isNotEmpty) _append('\n');
    _flushRuns();
  }

  void lineBreak(ReaderInlineStyle style) {
    _pendingSpace = false;
    _append('\n', style: style);
  }

  void beginBlock(ReaderBlockStyle style) {
    newline();
    _contexts.add(_BlockContext(style));
  }

  void endBlock() {
    newline();
    final context = _contexts.removeLast();
    final index = context.lastBlock;
    if (index == null) return;
    final block = _blocks[index];
    _blocks[index] = ReaderBlock(
      runs: block.runs,
      imageUrl: block.imageUrl,
      cells: block.cells,
      style: _copyBlockStyle(
        block.style,
        marginBottom: _addLength(
          block.style.marginBottom,
          context.style.marginBottom,
        ),
        hasMargins:
            block.style.hasMargins || !_zeroLength(context.style.marginBottom),
        breakAfter: block.style.breakAfter || context.style.breakAfter,
        box: _joinBoxBottom(block.style.box, context.style.box),
      ),
    );
  }

  void image(String url, ReaderBlockStyle style) {
    beginBlock(style);
    final index = _blocks.length;
    _blocks.add(ReaderBlock(imageUrl: url, style: _effectiveBlockStyle()));
    _markContexts(index);
    _append('$_imageMarker$url$_imageMarker\n');
    _pendingSpace = false;
    endBlock();
  }

  void tableRow(List<ReaderTableCell> cells) {
    newline();
    if (_blocks.length >= 100000) {
      throw const EpubImportException('EPUB 单章的段落数量过多');
    }
    final block = ReaderBlock(
      cells: cells,
      style: _copyBlockStyle(_effectiveBlockStyle(), hasMargins: true),
    );
    final index = _blocks.length;
    _blocks.add(block);
    _markContexts(index);
    _append('${block.text}\n');
  }

  ReaderBlockStyle _effectiveBlockStyle() {
    final nearest = _contexts.lastOrNull?.style ?? const ReaderBlockStyle();
    var top = const ReaderLength();
    var left = const ReaderLength();
    var right = const ReaderLength();
    var before = false;
    var keep = false;
    for (final context in _contexts) {
      left = _addLength(left, context.style.marginLeft);
      right = _addLength(right, context.style.marginRight);
      if (!context.started) {
        top = _addLength(top, context.style.marginTop);
        before = before || context.style.breakBefore;
      }
      keep = keep || context.style.keepTogether;
    }
    return _copyBlockStyle(
      nearest,
      marginTop: top,
      marginBottom: const ReaderLength(),
      marginLeft: left,
      marginRight: right,
      hasMargins: nearest.hasMargins || !_zeroLength(top),
      breakBefore: before,
      breakAfter: false,
      keepTogether: keep,
      box: _effectiveBox(_contexts),
    );
  }

  void _markContexts(int index) {
    for (final context in _contexts) {
      context.started = true;
      context.lastBlock = index;
    }
  }

  void _flushRuns() {
    if (_runs.isEmpty) return;
    final runs =
        _runs
            .map((run) => ReaderRun(run.text.toString(), style: run.style))
            .toList();
    var block = ReaderBlock(
      runs: runs,
      style: _runBlockStyle ?? _effectiveBlockStyle(),
    );
    // A preformatted terminal newline is represented by the separator between
    // blocks. Removing just that one newline keeps all other authored spacing.
    if (block.text.endsWith('\n')) {
      block = block.slice(0, block.text.length - 1);
    }
    if (block.text.isNotEmpty) {
      if (_blocks.length >= 100000) {
        throw const EpubImportException('EPUB 单章的段落数量过多');
      }
      final index = _blocks.length;
      _blocks.add(block);
      _markContexts(index);
    }
    _runs.clear();
    _runBlockStyle = null;
  }

  ReaderDocument get document {
    _flushRuns();
    return ReaderDocument(_blocks);
  }
}

class _PendingRun {
  _PendingRun(this.style, String value) {
    text.write(value);
  }
  final ReaderInlineStyle style;
  final text = StringBuffer();
}

class _BlockContext {
  _BlockContext(this.style);
  final ReaderBlockStyle style;
  bool started = false;
  int? lastBlock;
}

bool _sameStyle(ReaderInlineStyle a, ReaderInlineStyle b) =>
    a.bold == b.bold &&
    a.italic == b.italic &&
    a.underline == b.underline &&
    a.strike == b.strike &&
    a.scale == b.scale &&
    a.letterSpacing.em == b.letterSpacing.em &&
    a.letterSpacing.px == b.letterSpacing.px &&
    a.letterSpacing.fraction == b.letterSpacing.fraction &&
    a.color == b.color &&
    a.darkColor == b.darkColor &&
    a.background == b.background &&
    a.darkBackground == b.darkBackground;

bool _zeroLength(ReaderLength value) =>
    value.em == 0 && value.px == 0 && value.fraction == 0;
ReaderBoxStyle _effectiveBox(List<_BlockContext> contexts) {
  var pl = const ReaderLength(),
      pr = const ReaderLength(),
      pt = const ReaderLength(),
      radius = const ReaderLength();
  var left = const ReaderBorderStyle(),
      right = const ReaderBorderStyle(),
      top = const ReaderBorderStyle();
  int? bg, darkBg;
  for (final c in contexts) {
    final b = c.style.box;
    pl = _addLength(pl, b.paddingLeft);
    pr = _addLength(pr, b.paddingRight);
    if (!c.started) {
      pt = _addLength(pt, b.paddingTop);
      if (!_zeroLength(b.top.width)) top = b.top;
    }
    if (!_zeroLength(b.left.width)) left = b.left;
    if (!_zeroLength(b.right.width)) right = b.right;
    if (!_zeroLength(b.radius)) radius = b.radius;
    bg = b.background ?? bg;
    darkBg = b.darkBackground ?? darkBg;
  }
  return ReaderBoxStyle(
    paddingTop: pt,
    paddingLeft: pl,
    paddingRight: pr,
    left: left,
    right: right,
    top: top,
    radius: radius,
    background: bg,
    darkBackground: darkBg,
  );
}

ReaderBoxStyle _joinBoxBottom(ReaderBoxStyle b, ReaderBoxStyle parent) =>
    ReaderBoxStyle(
      paddingTop: b.paddingTop,
      paddingLeft: b.paddingLeft,
      paddingRight: b.paddingRight,
      paddingBottom: _addLength(b.paddingBottom, parent.paddingBottom),
      left: b.left,
      right: b.right,
      top: b.top,
      bottom: _zeroLength(parent.bottom.width) ? b.bottom : parent.bottom,
      radius: b.radius,
      background: b.background,
      darkBackground: b.darkBackground,
    );
ReaderLength _addLength(ReaderLength a, ReaderLength b) => ReaderLength(
  em: (a.em + b.em).clamp(-16, 16).toDouble(),
  px: (a.px + b.px).clamp(-256, 256).toDouble(),
  fraction: (a.fraction + b.fraction).clamp(-.9, .9).toDouble(),
);
ReaderBlockStyle _copyBlockStyle(
  ReaderBlockStyle source, {
  ReaderLength? marginTop,
  ReaderLength? marginBottom,
  ReaderLength? marginLeft,
  ReaderLength? marginRight,
  bool? hasMargins,
  bool? breakBefore,
  bool? breakAfter,
  bool? keepTogether,
  ReaderBoxStyle? box,
}) => ReaderBlockStyle(
  align: source.align,
  indent: source.indent,
  marginTop: marginTop ?? source.marginTop,
  marginBottom: marginBottom ?? source.marginBottom,
  marginLeft: marginLeft ?? source.marginLeft,
  marginRight: marginRight ?? source.marginRight,
  hasMargins: hasMargins ?? source.hasMargins,
  lineHeight: source.lineHeight,
  breakBefore: breakBefore ?? source.breakBefore,
  breakAfter: breakAfter ?? source.breakAfter,
  keepTogether: keepTogether ?? source.keepTogether,
  box: box ?? source.box,
);

Set<String> _tokens(String? value) =>
    (value ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toSet();

String? _attribute(dom.Element element, String localName) {
  for (final entry in element.attributes.entries) {
    final name = entry.key.toString();
    if (name == localName || name.endsWith(':$localName')) return entry.value;
  }
  return null;
}

Iterable<XmlElement> _elements(XmlNode node, String name) =>
    node.descendants.whereType<XmlElement>().where((e) => e.name.local == name);

XmlElement? _first(XmlNode node, String name) =>
    _elements(node, name).firstOrNull;

String _plain(String source) =>
    (html.parseFragment(source).text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

String _decode(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) throw const FormatException('Invalid UTF-16');
    final endian = bytes[0] == 0xff ? Endian.little : Endian.big;
    final data = ByteData.sublistView(bytes);
    return String.fromCharCodes([
      for (var at = 2; at < bytes.length; at += 2) data.getUint16(at, endian),
    ]);
  }
  final start =
      bytes.length >= 3 &&
              bytes[0] == 0xef &&
              bytes[1] == 0xbb &&
              bytes[2] == 0xbf
          ? 3
          : 0;
  return utf8.decode(Uint8List.sublistView(bytes, start));
}

_Reference? _resolve(String base, String href) {
  href = href.trim();
  if (href.isEmpty ||
      href.contains('\\') ||
      href.startsWith('//') ||
      RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(href)) {
    return null;
  }
  final hash = href.indexOf('#');
  var path = hash < 0 ? href : href.substring(0, hash);
  var fragment = hash < 0 ? '' : href.substring(hash + 1);
  final query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  try {
    path = _decodeHrefPart(path);
    fragment = _decodeHrefPart(fragment);
  } on Object {
    return null;
  }
  if (path.contains('\\') ||
      path.contains(':') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
    return null;
  }
  final absolute = path.startsWith('/');
  final parts = <String>[];
  if (!absolute && base.contains('/')) {
    parts.addAll(base.substring(0, base.lastIndexOf('/')).split('/'));
  }
  if (path.isEmpty) {
    return base.isEmpty ? null : _Reference(base, fragment);
  }
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  if (parts.isEmpty) return null;
  return _Reference(parts.join('/'), fragment);
}

// Dart's URI decoder expects an all-ASCII encoded input. Real EPUBs often mix
// literal Unicode and percent-encoded spaces, so decode only encoded byte runs.
String _decodeHrefPart(String value) => value.replaceAllMapped(
  RegExp(r'(?:%[0-9a-fA-F]{2})+'),
  (match) => Uri.decodeComponent(match[0]!),
);

String? _rasterExtension(Uint8List bytes) {
  bool at(int offset, List<int> value) =>
      bytes.length >= offset + value.length &&
      List.generate(
        value.length,
        (i) => bytes[offset + i] == value[i],
      ).every((match) => match);
  if (at(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'png';
  if (at(0, [0xff, 0xd8, 0xff])) return 'jpg';
  if (at(0, ascii.encode('GIF87a')) || at(0, ascii.encode('GIF89a'))) {
    return 'gif';
  }
  if (at(0, ascii.encode('RIFF')) && at(8, ascii.encode('WEBP'))) return 'webp';
  if (at(0, [0x42, 0x4d])) return 'bmp';
  if (at(4, ascii.encode('ftyp')) &&
      (at(8, ascii.encode('avif')) || at(8, ascii.encode('avis')))) {
    return 'avif';
  }
  return null;
}

bool _reasonableImageDimensions(Uint8List bytes, String extension) {
  final data = ByteData.sublistView(bytes);
  bool size(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width <= 16384 &&
      height <= 16384 &&
      width * height <= 40 * 1000 * 1000;
  if (extension == 'png') {
    return bytes.length >= 24 && size(data.getUint32(16), data.getUint32(20));
  }
  if (extension == 'gif') {
    return bytes.length >= 10 &&
        size(
          data.getUint16(6, Endian.little),
          data.getUint16(8, Endian.little),
        );
  }
  if (extension == 'bmp') {
    return bytes.length >= 26 &&
        size(
          data.getInt32(18, Endian.little).abs(),
          data.getInt32(22, Endian.little).abs(),
        );
  }
  if (extension == 'jpg') {
    var at = 2;
    while (at + 4 <= bytes.length) {
      if (bytes[at] != 0xff) return false;
      while (at < bytes.length && bytes[at] == 0xff) {
        at++;
      }
      if (at >= bytes.length) return false;
      final marker = bytes[at++];
      if (marker == 0xd9 || marker == 0xda) return false;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
      if (at + 2 > bytes.length) return false;
      final length = data.getUint16(at);
      if (length < 2 || at + length > bytes.length) return false;
      if (const {
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
      }.contains(marker)) {
        return length >= 7 &&
            size(data.getUint16(at + 5), data.getUint16(at + 3));
      }
      at += length;
    }
    return false;
  }
  if (extension == 'webp') {
    if (bytes.length < 20) return false;
    final chunk = ascii.decode(bytes.sublist(12, 16), allowInvalid: true);
    if (chunk == 'VP8X') {
      if (bytes.length < 30) return false;
      int u24(int at) =>
          bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
      return size(u24(24) + 1, u24(27) + 1);
    }
    if (chunk == 'VP8L') {
      if (bytes.length < 25 || bytes[20] != 0x2f) return false;
      final bits = data.getUint32(21, Endian.little);
      return size((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
    }
    if (chunk == 'VP8 ') {
      return bytes.length >= 30 &&
          bytes[23] == 0x9d &&
          bytes[24] == 0x01 &&
          bytes[25] == 0x2a &&
          size(
            data.getUint16(26, Endian.little) & 0x3fff,
            data.getUint16(28, Endian.little) & 0x3fff,
          );
    }
    return false;
  }
  if (extension == 'avif') {
    // Image spatial extents are held in an `ispe` full box under ipco. Check all
    // extents, including auxiliary images, before handing bytes to a codec.
    var found = false;
    for (var at = 4; at + 16 <= bytes.length; at++) {
      if (data.getUint32(at) != 0x69737065) continue;
      final boxSize = data.getUint32(at - 4);
      if (boxSize < 20 || at - 4 + boxSize > bytes.length) continue;
      found = true;
      if (!size(data.getUint32(at + 8), data.getUint32(at + 12))) return false;
    }
    return found;
  }
  return false;
}
