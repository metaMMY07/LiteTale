import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'shelf_api_error.dart';
import 'shelf_device_id.dart';

/// A compact book summary returned by LightNovelShelf's public latest feed.
class LightNovelShelfBook {
  const LightNovelShelfBook({
    required this.id,
    required this.title,
    required this.coverUrl,
    required this.uploaderName,
    required this.category,
    this.seriesTitle,
    this.lastUpdatedAt,
  });

  final int id;
  final String title;
  final String coverUrl;
  final String uploaderName;
  final String category;
  final String? seriesTitle;
  final DateTime? lastUpdatedAt;

  String get webUrl => 'https://www.lightnovel.app/book/info/$id';

  String get subtitle {
    final parts = [category, uploaderName].where((part) => part.isNotEmpty);
    return parts.join(' · ');
  }
}

/// Reads the anonymous six-book feed exposed by LightNovelShelf.
///
/// The endpoint and invocation contract are compatible with Novella's API
/// client. No LightNovelShelf credentials are requested or stored here.
class LightNovelShelfService {
  LightNovelShelfService({
    Uri? testHub,
    Future<String> Function()? deviceId,
    this.attemptTimeout = const Duration(seconds: 20),
    this.retryDelay = const Duration(milliseconds: 350),
  }) : _hub = testHub ?? Uri.parse(_hubUrl),
       _deviceId = deviceId ?? ShelfDeviceId.instance.value {
    if (testHub != null &&
        !(testHub.scheme == 'ws' && testHub.host == '127.0.0.1')) {
      throw ArgumentError('Only a loopback test hub may override the provider');
    }
  }

  static final LightNovelShelfService instance = LightNovelShelfService();
  static const catalogUrl = 'https://www.lightnovel.app/book/list/latest/1';
  static const _hubUrl = 'wss://api.lightnovel.life/hub/api';
  static const _recordSeparator = '\u001e';
  static const _cacheDuration = Duration(minutes: 10);
  static const _readMethods = {
    'GetLatestBookList',
    'GetBookList',
    'GetBookListByAuthor',
    'GetBookListByTitle',
    'GetBookCategories',
    'GetRank',
    'GetBookInfo',
    'GetNovelContent',
  };
  final Uri _hub;
  final Future<String> Function() _deviceId;
  final Duration attemptTimeout;
  final Duration retryDelay;
  final _pendingReads = <String, Future<Object?>>{};
  List<LightNovelShelfBook>? _cachedBooks;
  DateTime? _cachedAt;
  Future<List<LightNovelShelfBook>>? _pendingRequest;

  Future<List<LightNovelShelfBook>> fetchLatestBooks({
    bool forceRefresh = false,
  }) {
    if (!forceRefresh &&
        _cachedBooks != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheDuration) {
      return Future.value(List.unmodifiable(_cachedBooks!));
    }
    if (_pendingRequest case final pending?) return pending;
    final request = _fetchLatestBooks()
        .then((books) {
          _cachedBooks = List.unmodifiable(books);
          _cachedAt = DateTime.now();
          return List<LightNovelShelfBook>.unmodifiable(books);
        })
        .whenComplete(() => _pendingRequest = null);
    _pendingRequest = request;
    return request;
  }

  Future<List<LightNovelShelfBook>> _fetchLatestBooks() async =>
      decodeLightNovelShelfLatestBooks(
        await invoke('GetLatestBookList', {
          'Page': 1,
          'Size': 6,
          'Order': 'latest',
          'IgnoreJapanese': false,
          'IgnoreAI': false,
        }),
      );

  /// Coalesce identical reads within the same account. Never retry writes or
  /// login submissions; transient read failures get only one reconnect.
  Future<Object?> invoke(
    String method,
    Map<String, Object?> arguments, {
    String? token,
  }) {
    if (!_readMethods.contains(method)) {
      return _attempt(method, arguments, token);
    }
    final key = jsonEncode([method, arguments, token]);
    if (_pendingReads[key] case final pending?) return pending;
    late final Future<Object?> request;
    request = _readWithRetry(method, arguments, token).whenComplete(() {
      if (identical(_pendingReads[key], request)) _pendingReads.remove(key);
    });
    _pendingReads[key] = request;
    return request;
  }

  Future<Object?> _readWithRetry(
    String method,
    Map<String, Object?> args,
    String? token,
  ) async {
    try {
      return await _attempt(method, args, token);
    } on ShelfApiException catch (error) {
      if (!error.retryable) rethrow;
      await Future<void>.delayed(retryDelay);
      return _attempt(method, args, token);
    }
  }

  Future<Object?> _attempt(
    String method,
    Map<String, Object?> args,
    String? token,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    WebSocket? socket;
    StreamIterator<Map<String, dynamic>>? records;
    var expired = false;
    try {
      final operation = () async {
        final deviceId = await _deviceId();
        if (expired) throw shelfTimeoutError;
        final connection = WebSocket.connect(
          _hub.toString(),
          headers: {
            HttpHeaders.userAgentHeader: 'LiteTale/0.1.17',
            'x-id': deviceId,
            if (token != null && token.isNotEmpty)
              HttpHeaders.authorizationHeader: 'Bearer $token',
          },
          customClient: client,
        );
        // A timed-out connect may still complete. Close its late socket rather
        // than leaking it or letting it complete a different request.
        unawaited(
          connection.then<void>((lateSocket) {
            if (expired) unawaited(_closeSocket(lateSocket));
          }, onError: (Object _, StackTrace __) {}),
        );
        socket = await connection;
        if (expired) throw shelfTimeoutError;
        records = StreamIterator(_records(socket!));
        socket!.add(
          '${jsonEncode({'protocol': 'json', 'version': 1})}$_recordSeparator',
        );
        await _waitForHandshake(records!).timeout(const Duration(seconds: 6));
        const invocationId = 'read';
        socket!.add(
          '${jsonEncode({
            'type': 1,
            'invocationId': invocationId,
            'target': method,
            'arguments': [
              args,
              {'UseGzip': false},
            ],
          })}$_recordSeparator',
        );
        return _waitForCompletion(records!, invocationId);
      }();
      return await operation.timeout(attemptTimeout);
    } on ShelfApiException {
      rethrow;
    } on WebSocketException catch (error) {
      if (error.httpStatusCode case final status?) {
        throw ShelfApiException.http(status);
      }
      throw shelfNetworkError;
    } on TimeoutException {
      throw shelfTimeoutError;
    } on IOException {
      throw shelfNetworkError;
    } on FormatException {
      throw shelfInvalidResponse;
    } finally {
      expired = true;
      client.close(force: true);
      // Both close and subscription cancellation are independently bounded.
      await Future.wait([
        if (socket != null) _closeSocket(socket!),
        if (records != null) _cancelRecords(records!),
      ]);
    }
  }

  Future<void> _closeSocket(WebSocket socket) async {
    try {
      await socket.close().timeout(const Duration(milliseconds: 300));
    } catch (_) {
      /* Cleanup never replaces the request result. */
    }
  }

  Future<void> _cancelRecords(
    StreamIterator<Map<String, dynamic>> records,
  ) async {
    try {
      await records.cancel().timeout(const Duration(milliseconds: 300));
    } catch (_) {
      /* A stuck cancellation cannot keep the UI loading. */
    }
  }

  /// SignalR records can span WebSocket messages or share a single message.
  /// Keep trailing bytes until RS arrives; bound memory on a malformed stream.
  Stream<Map<String, dynamic>> _records(WebSocket socket) async* {
    var buffer = '';
    await for (final payload in socket) {
      buffer += switch (payload) {
        String value => value,
        List<int> value => utf8.decode(value),
        _ => throw const FormatException('Invalid SignalR frame'),
      };
      if (buffer.length > 8 * 1024 * 1024) throw shelfInvalidResponse;
      var end = buffer.indexOf(_recordSeparator);
      while (end >= 0) {
        final raw = buffer.substring(0, end);
        buffer = buffer.substring(end + 1);
        if (raw.trim().isNotEmpty) {
          final value = jsonDecode(raw);
          if (value is! Map<String, dynamic>) throw shelfInvalidResponse;
          yield value;
        }
        end = buffer.indexOf(_recordSeparator);
      }
    }
  }

  Future<void> _waitForHandshake(
    StreamIterator<Map<String, dynamic>> messages,
  ) async {
    while (await messages.moveNext()) {
      final message = messages.current;
      if (message.isEmpty) return;
      if (message['type'] == 7) throw shelfNetworkError;
      if (message['error'] != null) {
        throw const ShelfApiException('轻书架未能建立阅读连接，请稍后重试。');
      }
    }
    throw shelfNetworkError;
  }

  Future<Object?> _waitForCompletion(
    StreamIterator<Map<String, dynamic>> messages,
    String invocationId,
  ) async {
    while (await messages.moveNext()) {
      final message = messages.current;
      if (message['type'] == 7) throw shelfNetworkError;
      if (message['type'] != 3 || message['invocationId'] != invocationId) {
        continue;
      }
      if (message['error'] != null) {
        throw const ShelfApiException('轻书架未能完成阅读请求，请稍后重试。');
      }
      return message['result'];
    }
    throw shelfNetworkError;
  }
}

/// Parses the successful payload so it can be covered by deterministic tests.
List<LightNovelShelfBook> decodeLightNovelShelfLatestBooks(Object? result) {
  if (result is! Map) {
    throw const FormatException('LightNovelShelf returned an invalid result');
  }

  final success = result['success'] ?? result['Success'];
  if (success != true) {
    throw ShelfApiException.envelope(result);
  }

  final response = result['response'] ?? result['Response'];
  if (response is! Map) {
    throw const FormatException('LightNovelShelf response is missing');
  }
  final data = response['data'] ?? response['Data'];
  if (data is! List) {
    throw const FormatException('LightNovelShelf book list is missing');
  }

  return data
      .map((raw) {
        if (raw is! Map) {
          throw const FormatException('LightNovelShelf book item is invalid');
        }
        final id = _asInt(raw['Id'] ?? raw['id']);
        final title = _cleanText(raw['Title'] ?? raw['title']);
        final cover = _cleanText(raw['Cover'] ?? raw['cover']);
        if (id == null || title.isEmpty || cover.isEmpty) {
          throw const FormatException(
            'LightNovelShelf book item is incomplete',
          );
        }

        final seriesTitle = _cleanText(
          raw['SeriesTitle'] ?? raw['seriesTitle'],
        );
        final updatedText = _cleanText(
          raw['LastUpdatedAt'] ?? raw['lastUpdatedAt'],
        );
        return LightNovelShelfBook(
          id: id,
          title: title,
          seriesTitle: seriesTitle.isEmpty ? null : seriesTitle,
          coverUrl: cover,
          uploaderName: _cleanText(raw['UserName'] ?? raw['userName']),
          category: _categoryName(raw['Category'] ?? raw['category']),
          lastUpdatedAt:
              updatedText.isEmpty ? null : DateTime.tryParse(updatedText),
        );
      })
      .toList(growable: false);
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String _cleanText(Object? value) {
  return (value?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _categoryName(Object? value) {
  if (value is Map) return _cleanText(value['Name'] ?? value['name']);
  return _cleanText(value);
}
