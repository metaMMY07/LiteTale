import 'dart:typed_data';

const maxEpubInputBytes = 128 * 1024 * 1024;

class EpubImportException implements Exception {
  const EpubImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool isEpubDigest(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

String epubDigestFromId(String id) {
  if (!id.startsWith('epub:') || !isEpubDigest(id.substring(5))) {
    throw const EpubImportException('本地书籍编号无效');
  }
  return id.substring(5);
}

String epubChapterId(String digest, int index) => 'epub:$digest:c$index';
String epubAssetUrl(String digest, String assetName) =>
    'epub-asset:$digest/$assetName';

/// Plain data only, so import validation/conversion can run in an isolate.
class EpubChapterData {
  const EpubChapterData({
    required this.title,
    required this.href,
    required this.content,
  });
  final String title;
  final String href;
  final String content;
}

class ParsedEpubBook {
  const ParsedEpubBook({
    required this.digest,
    required this.title,
    required this.author,
    required this.description,
    required this.language,
    required this.subjects,
    required this.chapters,
    required this.assets,
    this.coverAssetName,
    this.warnings = const [],
  });
  final String digest, title, author, description, language;
  final List<String> subjects;
  final List<EpubChapterData> chapters;

  /// Only referenced raster images. Keys are SHA-256 + an allowed extension.
  final Map<String, Uint8List> assets;
  final String? coverAssetName;
  final List<String> warnings;
}

class LocalEpubChapter {
  const LocalEpubChapter({required this.title, required this.href});
  final String title, href;
}

class LocalEpubBook {
  const LocalEpubBook({
    required this.digest,
    required this.title,
    required this.author,
    required this.description,
    required this.language,
    required this.subjects,
    required this.fileName,
    required this.importedAtMs,
    required this.chapters,
    required this.assetNames,
    this.coverAssetName,
    this.warnings = const [],
  });
  final String digest, title, author, description, language, fileName;
  final int importedAtMs;
  final List<String> subjects;
  final List<LocalEpubChapter> chapters;
  final List<String> assetNames;
  final String? coverAssetName;
  final List<String> warnings;
  String get id => 'epub:$digest';
  String get coverUrl =>
      coverAssetName == null ? '' : epubAssetUrl(digest, coverAssetName!);
  String chapterId(int index) => epubChapterId(digest, index);
}

class EpubImportResult {
  const EpubImportResult(this.book, {required this.alreadyImported});
  final LocalEpubBook book;
  final bool alreadyImported;
}
