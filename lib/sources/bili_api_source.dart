import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

import 'book_source.dart';
import 'rule_book_source.dart' show readerTextFromHtml;

const _biliApiOrigin = 'https://lnovel.animes.garden';
const _topPageSize = 30;

// This is a known upstream content-quality limitation, not a network failure.
const biliTrialNotice = '试用书源：公开接口的实测章节出现重复段落，内容完整性尚未确认。';

/// Resource bounds for the public Bili novel API.
class BiliApiBudget {
  const BiliApiBudget({
    this.requestTimeout = const Duration(seconds: 10),
    this.detailTimeout = const Duration(seconds: 30),
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.maxRedirects = 3,
    this.maxVolumes = 80,
    this.maxChapters = 10000,
    this.maxConcurrentVolumes = 3,
    this.maxCatalogPage = 100,
  });

  final Duration requestTimeout;
  final Duration detailTimeout;
  final int maxResponseBytes;
  final int maxRedirects;
  final int maxVolumes;
  final int maxChapters;
  final int maxConcurrentVolumes;
  final int maxCatalogPage;
}

class BiliApiException implements Exception {
  const BiliApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Adapter for the public ranking, novel, volume, and chapter JSON endpoints.
/// The optional client is caller-owned. The default client is created and
/// closed for each public operation, including cancellation and failure.
class BiliApiSource implements BookSource {
  BiliApiSource({http.Client? client, this.budget = const BiliApiBudget()})
    : _injectedClient = client;

  final http.Client? _injectedClient;
  final BiliApiBudget budget;

  @override
  SourceId get id => SourceId.bili;

  @override
  Future<List<HomeBlock>> discover() async {
    final page = await listPage(1);
    return [HomeBlock(title: '${id.label} · 周点击榜', list: page.records)];
  }

  /// Fetches the requested real page of the public week-visit ranking.
  /// This is a ranking index, not a site-wide catalogue or search endpoint.
  Future<PageStatsNovelCover> listPage(int page) async {
    if (page < 1 || page > budget.maxCatalogPage) {
      throw BiliApiException('榜单页码超出范围');
    }
    return _withSession((session) async {
      final envelope = await _getJson(
        session,
        _apiUri('/api/bili/top/weekvisit', {'page': '$page'}),
      );
      final data = _requiredMap(envelope['data'], '榜单数据');
      final rawItems = _requiredList(data['items'], '榜单书目');
      final paginationValue = data['pagination'];
      var maxPage = page;
      if (paginationValue != null) {
        final pagination = _requiredMap(paginationValue, '榜单分页');
        final current = _optionalInt(pagination['current'], '当前页码');
        if (current != null && current != page) {
          throw const FormatException('榜单分页页码与请求不一致');
        }
        final total = _optionalInt(pagination['total'], '总页数');
        if (total != null) {
          if (total < 1) throw const FormatException('榜单总页数无效');
          maxPage = total.clamp(1, budget.maxCatalogPage);
        } else if (rawItems.length >= _topPageSize) {
          maxPage = (page + 1).clamp(1, budget.maxCatalogPage);
        }
      } else if (rawItems.length >= _topPageSize) {
        maxPage = (page + 1).clamp(1, budget.maxCatalogPage);
      }

      final records = rawItems
          .map((value) {
            final item = _requiredMap(value, '榜单书目');
            final nid = _positiveInt(item['nid'], '书籍编号');
            final title = _requiredString(item['title'], '书名').trim();
            if (title.isEmpty) throw const FormatException('榜单书名为空');
            final cover = _optionalString(item['cover'], '封面');
            final safeCover = cover == null ? '' : _safeImageUrl(cover) ?? '';
            final bookId = _bookId(nid);
            return NovelCover(
              aid: bookId,
              title: title,
              img: safeCover,
              // Use the stable local id here. Remote item fields never choose an
              // API destination; all API requests are built from numeric ids.
              detailUrl: bookId,
            );
          })
          .toList(growable: false);
      return PageStatsNovelCover(
        currentPage: page,
        maxPage: maxPage,
        records: records,
      );
    });
  }

  @override
  Future<PageStatsNovelCover> search(
    String keyword,
    String type,
    int page,
  ) async {
    if (type == 'author') throw UnsupportedError('此书源不支持作者搜索');
    if (type != 'articlename' && type != 'title' && type.isNotEmpty) {
      throw UnsupportedError('此书源仅支持书名查找');
    }
    final indexPage = await listPage(page);
    final query = keyword.trim().toLowerCase();
    final records =
        query.isEmpty
            ? const <NovelCover>[]
            : indexPage.records
                .where((book) => book.title.toLowerCase().contains(query))
                .toList(growable: false);
    return PageStatsNovelCover(
      currentPage: indexPage.currentPage,
      maxPage: indexPage.maxPage,
      records: records,
    );
  }

  @override
  Future<SourceBookDetail> detail(String bookId) => _withSession(
    (session) async {
      final nid = _parseBookId(bookId);
      final novelEnvelope = await _getJson(
        session,
        _apiUri('/api/bili/novel/$nid'),
      );
      final novel = _requiredMap(novelEnvelope['data'], '作品详情');
      if (_positiveInt(novel['nid'], '作品编号') != nid) {
        throw const FormatException('作品详情编号不匹配');
      }
      final title = _requiredString(novel['name'], '作品名').trim();
      if (title.isEmpty) throw const FormatException('作品名为空');
      final authors = _requiredList(novel['authors'], '作者列表')
          .map((value) {
            final author = _requiredMap(value, '作者');
            return _requiredString(author['name'], '作者名').trim();
          })
          .where((name) => name.isNotEmpty)
          .toList(growable: false);
      final labels = _stringList(novel['labels'], '作品标签');
      final rawVolumes = _requiredList(novel['volumes'], '分卷目录');
      if (rawVolumes.length > budget.maxVolumes) {
        throw BiliApiException('作品分卷超过 ${budget.maxVolumes} 卷上限');
      }
      final volumeRefs = rawVolumes
          .map((value) {
            final volume = _requiredMap(value, '分卷');
            final volumeNid = _positiveInt(volume['nid'], '分卷作品编号');
            if (volumeNid != nid) throw const FormatException('分卷不属于当前作品');
            return _VolumeRef(
              nid: volumeNid,
              vid: _positiveInt(volume['vid'], '分卷编号'),
              title: _requiredString(volume['title'], '分卷名').trim(),
            );
          })
          .toList(growable: false);

      final fetched = List<_VolumeData?>.filled(volumeRefs.length, null);
      var next = 0;
      var chapterCount = 0;
      Future<void> worker() async {
        while (true) {
          session.throwIfCancelled();
          final index = next++;
          if (index >= volumeRefs.length) return;
          try {
            final reference = volumeRefs[index];
            final envelope = await _getJson(
              session,
              _apiUri('/api/bili/novel/$nid/vol/${reference.vid}'),
            );
            final volume = _requiredMap(envelope['data'], '分卷目录');
            if (_positiveInt(volume['nid'], '分卷作品编号') != nid ||
                _positiveInt(volume['vid'], '分卷编号') != reference.vid) {
              throw const FormatException('分卷目录归属不匹配');
            }
            final volumeTitle = _requiredString(volume['name'], '分卷名').trim();
            final rawChapters = _requiredList(volume['chapters'], '章节目录');
            chapterCount += rawChapters.length;
            if (chapterCount > budget.maxChapters) {
              throw BiliApiException('作品章节超过 ${budget.maxChapters} 章上限');
            }
            final chapters = rawChapters
                .map((value) {
                  final chapter = _requiredMap(value, '章节');
                  if (_positiveInt(chapter['nid'], '章节作品编号') != nid ||
                      _positiveInt(chapter['vid'], '章节分卷编号') != reference.vid) {
                    throw const FormatException('章节不属于当前分卷');
                  }
                  final cid = _positiveInt(chapter['cid'], '章节编号');
                  final chapterTitle = _requiredString(chapter['title'], '章节名');
                  final stableChapterId = _chapterId(nid, cid);
                  return Chapter(
                    title: chapterTitle,
                    url: stableChapterId,
                    cid: stableChapterId,
                    aid: bookId,
                  );
                })
                .toList(growable: false);
            fetched[index] = _VolumeData(
              id: 'bili:$nid:vol:${reference.vid}',
              title: volumeTitle.isEmpty ? reference.title : volumeTitle,
              chapters: chapters,
            );
          } catch (error) {
            session.cancel(error);
            rethrow;
          }
        }
      }

      final workerCount =
          volumeRefs.length < budget.maxConcurrentVolumes
              ? volumeRefs.length
              : budget.maxConcurrentVolumes;
      await Future.wait(List.generate(workerCount, (_) => worker()));
      session.throwIfCancelled();
      final volumes = fetched
          .map((volume) {
            if (volume == null) throw const FormatException('分卷目录未完整返回');
            return Volume(
              id: volume.id,
              title: volume.title,
              chapters: volume.chapters,
            );
          })
          .toList(growable: false);
      if (chapterCount == 0) {
        throw const BiliApiException('作品目录尚未就绪，暂时没有可读章节');
      }

      final rawCover = _optionalString(novel['cover'], '作品封面');
      final updatedAt = _optionalString(novel['updatedAt'], '更新时间') ?? '';
      return SourceBookDetail(
        NovelInfo(
          title: title,
          author: authors.join('、'),
          status: _statusFromLabels(labels),
          finUpdate: updatedAt,
          imgUrl: rawCover == null ? '' : _safeImageUrl(rawCover) ?? '',
          introduce: _requiredString(novel['description'], '作品简介'),
          tags: labels,
          heat: '',
          trending: '',
          isAnimated: false,
        ),
        volumes,
      );
    },
    timeout: budget.detailTimeout,
    timeoutMessage: '作品目录请求超时',
  );

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) =>
      _withSession((session) async {
        final nid = _parseBookId(bookId);
        final match = RegExp(
          r'^bili:([1-9]\d*):([1-9]\d*)$',
        ).firstMatch(chapterId);
        if (match == null) throw const FormatException('章节编号无效');
        if (int.parse(match.group(1)!) != nid) {
          throw const FormatException('章节不属于当前作品');
        }
        final cid = int.parse(match.group(2)!);
        final envelope = await _getJson(
          session,
          _apiUri('/api/bili/novel/$nid/chapter/$cid'),
        );
        final data = _requiredMap(envelope['data'], '章节正文');
        if (_positiveInt(data['nid'], '章节作品编号') != nid ||
            _positiveInt(data['cid'], '章节编号') != cid) {
          throw const FormatException('章节正文编号不匹配');
        }
        _positiveInt(data['vid'], '章节分卷编号');
        final title = _requiredString(data['title'], '章节名').trim();
        if (title.isEmpty) throw const FormatException('章节名为空');
        final html = _requiredString(data['content'], '章节内容');
        final rawImages = _requiredList(data['images'], '章节图片');
        final images = rawImages
            .map((value) {
              final image = _requiredMap(value, '章节图片');
              final src = _requiredString(image['src'], '图片地址');
              final alt = _optionalString(image['alt'], '图片说明');
              return _ChapterImage(_safeImageUrl(src), alt);
            })
            .where((image) => image.url != null)
            .toList(growable: false);
        final safeHtml = _sanitizeChapterHtml(html, images);
        final content = readerTextFromHtml(safeHtml).trim();
        if (content.isEmpty) throw const FormatException('章节正文为空');
        return SourceChapter(content);
      });

  Future<T> _withSession<T>(
    Future<T> Function(_RequestSession session) run, {
    Duration? timeout,
    String timeoutMessage = '请求超时，请稍后重试',
  }) async {
    final ownsClient = _injectedClient == null;
    final session = _RequestSession(
      ownsClient ? http.Client() : _injectedClient,
      budget,
    );
    final operationLimit =
        timeout ??
        Duration(
          microseconds:
              budget.requestTimeout.inMicroseconds * (budget.maxRedirects + 1),
        );
    final timedOut = Completer<T>();
    final operationTimer = Timer(operationLimit, () {
      final error = BiliApiException(timeoutMessage);
      session.cancel(error);
      timedOut.completeError(error, StackTrace.current);
    });
    // Race the whole operation, not just socket send/body reads. Stream
    // cancellation itself is user-supplied asynchronous work and may stall.
    final operation = Future<T>.sync(() => run(session));
    try {
      return await Future.any<T>([operation, timedOut.future]);
    } catch (error) {
      session.cancel(error);
      rethrow;
    } finally {
      operationTimer.cancel();
      session.close(ownsClient);
    }
  }

  Future<Map<String, Object?>> _getJson(
    _RequestSession session,
    Uri initialUri,
  ) async {
    var uri = initialUri;
    for (var redirectCount = 0; ; redirectCount++) {
      session.throwIfCancelled();
      if (!_isApiUri(uri)) throw const FormatException('接口地址无效');
      final requestClock = Stopwatch()..start();
      final request =
          http.Request('GET', uri)
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['accept'] = 'application/json';
      http.StreamedResponse response;
      try {
        response = await session.wait(
          session.client.send(request),
          session.budget.requestTimeout,
          '请求超时，请稍后重试',
        );
      } on BiliApiException {
        rethrow;
      } catch (_) {
        throw const BiliApiException('网络请求失败，请稍后重试');
      }
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        await _cancelBody(response);
        if (location == null || location.trim().isEmpty) {
          throw const BiliApiException('接口重定向地址无效');
        }
        if (redirectCount >= session.budget.maxRedirects) {
          throw const BiliApiException('接口重定向次数超限');
        }
        final target = uri.resolve(location);
        if (!_isApiUri(target)) throw const BiliApiException('接口重定向目标不安全');
        uri = target;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _cancelBody(response);
        throw BiliApiException('接口请求失败（HTTP ${response.statusCode}）');
      }
      if (response.contentLength != null &&
          response.contentLength! > session.budget.maxResponseBytes) {
        await _cancelBody(response);
        throw BiliApiException(
          '接口响应超过 ${session.budget.maxResponseBytes} 字节上限',
        );
      }
      final remaining = session.budget.requestTimeout - requestClock.elapsed;
      if (remaining <= Duration.zero) {
        final error = const BiliApiException('请求超时，请稍后重试');
        session.cancel(error);
        throw error;
      }
      final bytes = await session.readBounded(response.stream, remaining);
      late final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      } on FormatException {
        throw const FormatException('接口 JSON 格式无效');
      }
      final envelope = _requiredMap(decoded, '接口响应');
      if (envelope['ok'] != true) throw const FormatException('接口返回失败');
      return envelope;
    }
  }
}

class _RequestSession {
  _RequestSession(this.client, this.budget);

  final http.Client client;
  final BiliApiBudget budget;
  final Completer<Object> _cancelled = Completer<Object>();
  final Set<void Function(Object)> _cancelHandlers = {};
  bool _closed = false;
  Object? _cancelReason;

  void cancel(Object reason) {
    if (_cancelled.isCompleted) return;
    _cancelReason = reason;
    _cancelled.complete(reason);
    for (final handler in _cancelHandlers.toList()) {
      handler(reason);
    }
    _cancelHandlers.clear();
  }

  void throwIfCancelled() {
    if (_cancelled.isCompleted) throw _cancelReason!;
  }

  Future<T> wait<T>(Future<T> future, Duration timeout, String message) {
    final timer = Timer(timeout, () {
      cancel(BiliApiException(message));
    });
    final canceled = _cancelled.future.then<T>((reason) => throw reason);
    return Future.any([future, canceled]).whenComplete(timer.cancel);
  }

  Future<Uint8List> readBounded(
    Stream<List<int>> stream,
    Duration remainingTimeout,
  ) async {
    final output = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    var length = 0;
    late StreamSubscription<List<int>> subscription;
    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
      unawaited(subscription.cancel());
    }

    subscription = stream.listen(
      (chunk) {
        if (_cancelled.isCompleted) {
          fail(_cancelReason!);
          return;
        }
        if (length + chunk.length > budget.maxResponseBytes) {
          final error = BiliApiException(
            '接口响应超过 ${budget.maxResponseBytes} 字节上限',
          );
          cancel(error);
          fail(error);
          return;
        }
        length += chunk.length;
        output.add(chunk);
      },
      onError:
          (Object error, StackTrace stack) =>
              fail(const BiliApiException('读取接口响应失败')),
      onDone: () {
        if (!completer.isCompleted) completer.complete(output.takeBytes());
      },
      cancelOnError: true,
    );
    void onCancel(Object reason) => fail(reason);
    _cancelHandlers.add(onCancel);
    try {
      return await wait(completer.future, remainingTimeout, '请求超时，请稍后重试');
    } finally {
      _cancelHandlers.remove(onCancel);
      await subscription.cancel();
    }
  }

  void close(bool closeClient) {
    if (_closed) return;
    _closed = true;
    if (!_cancelled.isCompleted) cancel(const BiliApiException('请求已结束'));
    if (closeClient) client.close();
  }
}

class _VolumeRef {
  const _VolumeRef({required this.nid, required this.vid, required this.title});
  final int nid;
  final int vid;
  final String title;
}

class _VolumeData {
  const _VolumeData({
    required this.id,
    required this.title,
    required this.chapters,
  });
  final String id;
  final String title;
  final List<Chapter> chapters;
}

class _ChapterImage {
  const _ChapterImage(this.url, this.alt);
  final String? url;
  final String? alt;
}

String _bookId(int nid) => 'bili:$nid';
String _chapterId(int nid, int cid) => 'bili:$nid:$cid';

int _parseBookId(String bookId) {
  final match = RegExp(r'^bili:([1-9]\d*)$').firstMatch(bookId);
  if (match == null) throw const FormatException('书籍编号无效');
  return int.parse(match.group(1)!);
}

Uri _apiUri(String path, [Map<String, String>? query]) =>
    Uri.parse(_biliApiOrigin).replace(path: path, queryParameters: query);

bool _isApiUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'lnovel.animes.garden' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty;

bool _isRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

Future<void> _cancelBody(http.StreamedResponse response) async {
  final subscription = response.stream.listen((_) {});
  await subscription.cancel();
}

Map<String, Object?> _requiredMap(Object? value, String field) {
  if (value is! Map) throw FormatException('$field格式无效');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) throw FormatException('$field格式无效');
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> _requiredList(Object? value, String field) {
  if (value is! List) throw FormatException('$field格式无效');
  return value.cast<Object?>();
}

String _requiredString(Object? value, String field) {
  if (value is! String) throw FormatException('$field格式无效');
  return value;
}

String? _optionalString(Object? value, String field) {
  if (value == null) return null;
  return _requiredString(value, field);
}

int? _optionalInt(Object? value, String field) {
  if (value == null) return null;
  if (value is! int || value < 0) throw FormatException('$field格式无效');
  return value;
}

int _positiveInt(Object? value, String field) {
  if (value is! int || value < 1) throw FormatException('$field格式无效');
  return value;
}

List<String> _stringList(Object? value, String field) => _requiredList(
  value,
  field,
).map((item) => _requiredString(item, field)).toList(growable: false);

String _statusFromLabels(List<String> labels) {
  final normalized =
      labels
          .map(
            (label) =>
                label.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase(),
          )
          .toSet();
  const finished = {
    '完结',
    '已完结',
    '完結',
    '已完結',
    '完結済',
    '完結済み',
    'complete',
    'completed',
    'finished',
  };
  const ongoing = {
    '连载',
    '连载中',
    '連載',
    '連載中',
    'ongoing',
    'serializing',
    'serialised',
    'serialized',
  };
  if (normalized.any(finished.contains)) return '已完结';
  if (normalized.any(ongoing.contains)) return '连载中';
  return '未知';
}

String? _safeImageUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  try {
    final parsed = Uri.parse(value);
    final resolved =
        parsed.hasScheme ? parsed : Uri.parse(_biliApiOrigin).resolve(value);
    if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
        resolved.host.isEmpty ||
        resolved.userInfo.isNotEmpty) {
      return null;
    }
    return resolved.toString();
  } on FormatException {
    return null;
  }
}

String _sanitizeChapterHtml(String source, List<_ChapterImage> images) {
  final fragment = html_parser.parseFragment(source);
  final foundImages = <String>{};
  const blocked = {
    'script',
    'style',
    'iframe',
    'frame',
    'form',
    'object',
    'embed',
    'svg',
    'math',
    'template',
    'link',
    'meta',
  };

  void sanitize(dom.Node parent) {
    for (final child in List<dom.Node>.from(parent.nodes)) {
      if (child is dom.Comment) {
        child.remove();
        continue;
      }
      if (child is! dom.Element) {
        sanitize(child);
        continue;
      }
      final tag = child.localName;
      if (tag == null || blocked.contains(tag)) {
        child.remove();
        continue;
      }
      if (tag == 'img') {
        final safe = _safeImageUrl(child.attributes['src'] ?? '');
        if (safe == null) {
          child.remove();
          continue;
        }
        final alt = child.attributes['alt'];
        child.attributes
          ..clear()
          ..['src'] = safe;
        if (alt != null && alt.length <= 300) child.attributes['alt'] = alt;
        foundImages.add(safe);
        continue;
      }
      child.attributes.clear();
      sanitize(child);
    }
  }

  sanitize(fragment);
  for (final image in images) {
    final url = image.url;
    if (url == null || !foundImages.add(url)) continue;
    final node = dom.Element.tag('img')..attributes['src'] = url;
    final alt = image.alt;
    if (alt != null && alt.length <= 300) node.attributes['alt'] = alt;
    fragment.append(node);
  }
  return fragment.outerHtml;
}
