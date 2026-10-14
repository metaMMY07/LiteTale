/// Small, UI-independent models returned by the imported-source rule engine.
library;

class RuleSourceCapabilities {
  const RuleSourceCapabilities({
    required this.discover,
    required this.search,
    required this.detail,
    required this.catalog,
    required this.content,
    required this.cover,
    required this.images,
  });

  final bool discover;
  final bool search;
  final bool detail;
  final bool catalog;
  final bool content;
  final bool cover;
  final bool images;

  List<String> get names => [
    if (discover) 'discover',
    if (search) 'search',
    if (detail) 'detail',
    if (catalog) 'catalog',
    if (content) 'content',
    if (cover) 'cover',
    if (images) 'images',
  ];
}

class RuleSourceBook {
  const RuleSourceBook({
    required this.id,
    required this.title,
    required this.author,
    required this.detailUrl,
    this.coverUrl = '',
    this.description = '',
    this.latestChapter = '',
  });

  final String id;
  final String title;
  final String author;
  final String detailUrl;
  final String coverUrl;
  final String description;
  final String latestChapter;
}

class RulePage<T> {
  const RulePage({
    required this.items,
    required this.pagesFetched,
    required this.reachedEnd,
    this.nextPageUrl,
  });

  final List<T> items;
  final int pagesFetched;
  final bool reachedEnd;
  final String? nextPageUrl;
}

class RuleSourceDetail {
  const RuleSourceDetail({
    required this.title,
    required this.author,
    required this.detailUrl,
    this.coverUrl = '',
    this.description = '',
    this.latestChapter = '',
    this.status = '',
    this.catalogUrl = '',
  });

  final String title;
  final String author;
  final String detailUrl;
  final String coverUrl;
  final String description;
  final String latestChapter;
  final String status;
  final String catalogUrl;
}

class RuleChapterRef {
  const RuleChapterRef({
    required this.id,
    required this.title,
    required this.url,
  });

  /// Kept separately from [url]; a source may use a non-numeric URL as id.
  final String id;
  final String title;
  final String url;
}

class RuleCatalog {
  const RuleCatalog({required this.chapters, required this.pagesFetched});

  final List<RuleChapterRef> chapters;
  final int pagesFetched;
}

class RuleSourceImage {
  const RuleSourceImage({required this.url, this.alt = ''});

  final String url;
  final String alt;
}

class RuleSourceChapter {
  const RuleSourceChapter({
    required this.url,
    required this.contentHtml,
    required this.images,
    required this.pagesFetched,
  });

  final String url;
  final String contentHtml;
  final List<RuleSourceImage> images;
  final int pagesFetched;
}

class RuleSourceException implements Exception {
  const RuleSourceException(this.sourceId, this.message);

  final String sourceId;
  final String message;

  @override
  String toString() => '书源 $sourceId：$message';
}

class RuleSourceSchemaException extends RuleSourceException {
  const RuleSourceSchemaException(super.sourceId, super.message);
}

class RuleSourceUnsupportedException extends RuleSourceException {
  const RuleSourceUnsupportedException(super.sourceId, super.message);
}

class RuleSourceNetworkException extends RuleSourceException {
  const RuleSourceNetworkException(super.sourceId, super.message);
}

class RuleSourceLimitException extends RuleSourceException {
  const RuleSourceLimitException(super.sourceId, super.message);
}

class RuleSourcePaginationException extends RuleSourceException {
  const RuleSourcePaginationException(super.sourceId, super.message);
}

class RuleSourceExtractionException extends RuleSourceException {
  const RuleSourceExtractionException(super.sourceId, super.message);
}
