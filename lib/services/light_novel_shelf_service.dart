import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  LightNovelShelfService._();

  static final LightNovelShelfService instance = LightNovelShelfService._();

  static const catalogUrl = 'https://www.lightnovel.app/book/list/latest/1';
  static const _hubUrl = 'wss://api.lightnovel.life/hub/api';
  static const _recordSeparator = '\u001e';
  static const _cacheDuration = Duration(minutes: 10);

  List<LightNovelShelfBook>? _cachedBooks;
  DateTime? _cachedAt;
  Future<List<LightNovelShelfBook>>? _pendingRequest;

  Future<List<LightNovelShelfBook>> fetchLatestBooks({
    bool forceRefresh = false,
  }) {
    final cachedAt = _cachedAt;
    if (!forceRefresh &&
        _cachedBooks != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheDuration) {
      return Future.value(List.unmodifiable(_cachedBooks!));
    }

    final pending = _pendingRequest;
    if (pending != null) return pending;

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

  Future<List<LightNovelShelfBook>> _fetchLatestBooks() async {
    final client =
        HttpClient()..connectionTimeout = const Duration(seconds: 12);
    WebSocket? socket;
    StreamIterator<dynamic>? messages;
    try {
      socket = await WebSocket.connect(
        _hubUrl,
        headers: {
          HttpHeaders.userAgentHeader: 'novels/0.0.15',
          'x-id': _createUuid(),
        },
        customClient: client,
      ).timeout(const Duration(seconds: 12));
      messages = StreamIterator<dynamic>(socket);

      socket.add(
        '${jsonEncode({'protocol': 'json', 'version': 1})}'
        '$_recordSeparator',
      );
      await _waitForHandshake(messages).timeout(const Duration(seconds: 8));

      const invocationId = 'latest-books';
      socket.add(
        '${jsonEncode({
          'type': 1,
          'invocationId': invocationId,
          'target': 'GetLatestBookList',
          'arguments': [
            {'Page': 1, 'Size': 6, 'Order': 'latest', 'IgnoreJapanese': false, 'IgnoreAI': false},
            {'UseGzip': false},
          ],
        })}$_recordSeparator',
      );

      final result = await _waitForCompletion(
        messages,
        invocationId,
      ).timeout(const Duration(seconds: 12));
      return decodeLightNovelShelfLatestBooks(result);
    } finally {
      try {
        await messages?.cancel();
        await socket?.close().timeout(const Duration(seconds: 1));
      } catch (_) {
        // Cleanup must not replace the request result or extend its timeout.
      } finally {
        client.close(force: true);
      }
    }
  }

  Future<void> _waitForHandshake(StreamIterator<dynamic> messages) async {
    while (await messages.moveNext()) {
      for (final message in _decodeRecords(messages.current)) {
        if (message.isEmpty) return;
        final error = message['error'];
        if (error != null) {
          throw StateError('LightNovelShelf handshake failed: $error');
        }
      }
    }
    throw const SocketException('LightNovelShelf closed during handshake');
  }

  Future<Object?> _waitForCompletion(
    StreamIterator<dynamic> messages,
    String invocationId,
  ) async {
    while (await messages.moveNext()) {
      for (final message in _decodeRecords(messages.current)) {
        if (message['type'] != 3 || message['invocationId'] != invocationId) {
          continue;
        }
        final error = message['error'];
        if (error != null) {
          throw StateError('LightNovelShelf request failed: $error');
        }
        return message['result'];
      }
    }
    throw const SocketException('LightNovelShelf closed before responding');
  }

  Iterable<Map<String, dynamic>> _decodeRecords(dynamic payload) sync* {
    final text = switch (payload) {
      String value => value,
      List<int> value => utf8.decode(value),
      _ => '',
    };
    for (final record in text.split(_recordSeparator)) {
      if (record.trim().isEmpty) continue;
      final value = jsonDecode(record);
      if (value is Map<String, dynamic>) yield value;
    }
  }

  String _createUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'));
    final value = hex.join();
    return '${value.substring(0, 8)}-'
        '${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-'
        '${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}

/// Parses the successful payload so it can be covered by deterministic tests.
List<LightNovelShelfBook> decodeLightNovelShelfLatestBooks(Object? result) {
  if (result is! Map) {
    throw const FormatException('LightNovelShelf returned an invalid result');
  }

  final success = result['success'] ?? result['Success'];
  if (success != true) {
    final message = result['msg'] ?? result['Msg'] ?? 'unknown error';
    throw StateError('LightNovelShelf rejected the request: $message');
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
