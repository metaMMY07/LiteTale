import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/src/rust/api/database.dart';
import 'package:wild/sources/book_source.dart';

const readingStatisticsPropertyKey = 'litetale.reading_statistics_v1';
const readingStatisticsSchemaVersion = 1;
const readingStatisticsMaximumEvents = 100000;
const readingStatisticsMaximumJsonBytes = 16 * 1024 * 1024;

enum ReadingStatisticsEventKind { session, duration }

@immutable
class ReadingStatisticsEvent {
  const ReadingStatisticsEvent({
    required this.id,
    required this.sessionId,
    required this.bookId,
    required this.source,
    required this.title,
    required this.kind,
    required this.occurredAt,
    required this.seconds,
  });

  final String id;
  final String sessionId;
  final String bookId;
  final String source;
  final String title;
  final ReadingStatisticsEventKind kind;
  final DateTime occurredAt;
  final int seconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'bookId': bookId,
    'source': source,
    'title': title,
    'kind': kind.name,
    'occurredAt': occurredAt.toIso8601String(),
    'seconds': seconds,
  };

  factory ReadingStatisticsEvent.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('统计事件格式无效');
    final row = Map<String, Object?>.from(value);
    final id = _requiredString(row['id'], 'id', 512);
    final sessionId = _requiredString(row['sessionId'], 'sessionId', 512);
    final bookId = _requiredString(row['bookId'], 'bookId', 2048);
    final actualSource = sourceOf(bookId).name;
    final source = _requiredString(row['source'], 'source', 64);
    if (source != actualSource) throw const FormatException('统计来源与书籍编号不匹配');
    final title = _requiredString(
      row['title'],
      'title',
      1024,
      allowEmpty: true,
    );
    final kindValue = row['kind'];
    final kind = _firstOrNull(
      ReadingStatisticsEventKind.values.where((item) => item.name == kindValue),
    );
    if (kind == null) throw const FormatException('统计事件类型无效');
    final timestampValue = row['occurredAt'];
    if (timestampValue is! String ||
        timestampValue.length > 64 ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?$',
        ).hasMatch(timestampValue)) {
      throw const FormatException('统计事件时间无效');
    }
    final DateTime occurredAt;
    try {
      occurredAt = DateTime.parse(timestampValue);
    } on FormatException {
      throw const FormatException('统计事件时间无效');
    }
    final seconds = row['seconds'];
    if (seconds is! int || seconds < 0 || seconds > 86400) {
      throw const FormatException('统计事件时长无效');
    }
    if ((kind == ReadingStatisticsEventKind.session && seconds != 0) ||
        (kind == ReadingStatisticsEventKind.duration && seconds == 0)) {
      throw const FormatException('统计事件时长与类型不匹配');
    }
    if (kind == ReadingStatisticsEventKind.session &&
        id != '$sessionId:session') {
      throw const FormatException('阅读会话编号无效');
    }
    if (kind == ReadingStatisticsEventKind.duration &&
        !id.startsWith('$sessionId:')) {
      throw const FormatException('阅读时长编号无效');
    }
    if (kind == ReadingStatisticsEventKind.duration) {
      final datePart =
          '${occurredAt.year.toString().padLeft(4, '0')}${occurredAt.month.toString().padLeft(2, '0')}${occurredAt.day.toString().padLeft(2, '0')}';
      final expectedId =
          '$sessionId:$datePart:${occurredAt.hour.toString().padLeft(2, '0')}';
      if (id != expectedId ||
          occurredAt.minute != 0 ||
          occurredAt.second != 0 ||
          occurredAt.millisecond != 0 ||
          occurredAt.microsecond != 0) {
        throw const FormatException('统计时长桶编号无效');
      }
    }
    return ReadingStatisticsEvent(
      id: id,
      sessionId: sessionId,
      bookId: bookId,
      source: actualSource,
      title: title,
      kind: kind,
      occurredAt: occurredAt,
      seconds: seconds,
    );
  }
}

@immutable
class ReadingStatisticsState {
  ReadingStatisticsState({
    this.initialized = false,
    Iterable<ReadingStatisticsEvent> events = const [],
    this.warning,
  }) : events = List.unmodifiable(events);

  final bool initialized;
  final List<ReadingStatisticsEvent> events;
  final String? warning;

  bool get isEmpty =>
      events.every((event) => event.kind != ReadingStatisticsEventKind.session);
}

@immutable
class ReadingStatisticsSnapshot {
  ReadingStatisticsSnapshot._(List<ReadingStatisticsEvent> sourceEvents)
    : events = List.unmodifiable(sourceEvents),
      sessionCount =
          sourceEvents
              .where(
                (event) => event.kind == ReadingStatisticsEventKind.session,
              )
              .length,
      totalSeconds = sourceEvents
          .where((event) => event.kind == ReadingStatisticsEventKind.duration)
          .fold<int>(0, (sum, event) => sum + event.seconds),
      secondsByDay = _groupByDay(sourceEvents),
      secondsByHour = _groupByHour(sourceEvents),
      secondsByBook = _groupByBook(sourceEvents),
      sessionsByBook = _sessionCountsByBook(sourceEvents),
      secondsByDayAndBook = _groupByDayAndBook(sourceEvents),
      titlesByBook = _titlesByBook(sourceEvents);

  final List<ReadingStatisticsEvent> events;
  final int sessionCount;
  final int totalSeconds;
  final Map<DateTime, int> secondsByDay;
  final Map<int, int> secondsByHour;
  final Map<String, int> secondsByBook;
  final Map<String, int> sessionsByBook;
  final Map<DateTime, Map<String, int>> secondsByDayAndBook;
  final Map<String, String> titlesByBook;

  int get activeDays => secondsByDay.values.where((value) => value > 0).length;
  bool get isEmpty => sessionCount == 0;

  int secondsForDay(DateTime date) => secondsByDay[_dateOnly(date)] ?? 0;

  static Map<DateTime, int> _groupByDay(List<ReadingStatisticsEvent> events) {
    final result = <DateTime, int>{};
    for (final event in events) {
      if (event.kind == ReadingStatisticsEventKind.duration) {
        final day = _dateOnly(event.occurredAt);
        result.update(
          day,
          (value) => value + event.seconds,
          ifAbsent: () => event.seconds,
        );
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<int, int> _groupByHour(List<ReadingStatisticsEvent> events) {
    final result = <int, int>{};
    for (final event in events) {
      if (event.kind == ReadingStatisticsEventKind.duration) {
        final hour = event.occurredAt.hour;
        result.update(
          hour,
          (value) => value + event.seconds,
          ifAbsent: () => event.seconds,
        );
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<String, int> _groupByBook(List<ReadingStatisticsEvent> events) {
    final result = <String, int>{};
    for (final event in events) {
      if (event.kind == ReadingStatisticsEventKind.duration) {
        result.update(
          event.bookId,
          (value) => value + event.seconds,
          ifAbsent: () => event.seconds,
        );
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<String, int> _sessionCountsByBook(
    List<ReadingStatisticsEvent> events,
  ) {
    final result = <String, int>{};
    for (final event in events) {
      if (event.kind == ReadingStatisticsEventKind.session) {
        result.update(event.bookId, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<DateTime, Map<String, int>> _groupByDayAndBook(
    List<ReadingStatisticsEvent> events,
  ) {
    final result = <DateTime, Map<String, int>>{};
    for (final event in events) {
      if (event.kind != ReadingStatisticsEventKind.duration) continue;
      final day = _dateOnly(event.occurredAt);
      final values = result.putIfAbsent(day, () => <String, int>{});
      values.update(
        event.bookId,
        (value) => value + event.seconds,
        ifAbsent: () => event.seconds,
      );
    }
    return Map<DateTime, Map<String, int>>.unmodifiable({
      for (final entry in result.entries)
        entry.key: Map<String, int>.unmodifiable(entry.value),
    });
  }

  static Map<String, String> _titlesByBook(
    List<ReadingStatisticsEvent> events,
  ) {
    final result = <String, String>{};
    for (final event in events) {
      if (event.title.isNotEmpty) result[event.bookId] = event.title;
    }
    return Map.unmodifiable(result);
  }
}

class _SessionProgress {
  _SessionProgress(this.checkpoint);
  DateTime checkpoint;
  int remainderMicros = 0;
}

class ReadingStatisticsCubit extends Cubit<ReadingStatisticsState> {
  ReadingStatisticsCubit({
    Future<String> Function()? read,
    Future<void> Function(String value)? write,
    DateTime Function()? clock,
  }) : _read = read ?? (() => loadProperty(key: readingStatisticsPropertyKey)),
       _write =
           write ??
           ((value) =>
               saveProperty(key: readingStatisticsPropertyKey, value: value)),
       _clock = clock ?? DateTime.now,
       super(ReadingStatisticsState());

  final Future<String> Function() _read;
  final Future<void> Function(String value) _write;
  final DateTime Function() _clock;
  final Map<String, _SessionProgress> _activeSessions = {};
  Future<void> _saveQueue = Future<void>.value();
  Future<void>? _initializeFuture;
  int _idSequence = 0;

  static const maximumEvents = readingStatisticsMaximumEvents;
  static const maximumJsonBytes = readingStatisticsMaximumJsonBytes;

  DateTime get currentTime => _clock();

  Future<void> initialize() {
    if (state.initialized) return Future<void>.value();
    return _initializeFuture ??= _load();
  }

  Future<void> reload() async {
    if (_activeSessions.isNotEmpty) throw StateError('阅读中不能重新载入统计');
    await _saveQueue;
    _initializeFuture = null;
    await _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _read();
      if (raw.isNotEmpty) {
        if (utf8.encode(raw).length > maximumJsonBytes) {
          throw const FormatException('统计数据超过允许大小');
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map ||
            decoded['version'] != readingStatisticsSchemaVersion) {
          throw const FormatException('统计数据版本不支持');
        }
        final rawEvents = decoded['events'];
        if (rawEvents is! List || rawEvents.length > maximumEvents) {
          throw const FormatException('统计事件数量无效');
        }
        final events = <String, ReadingStatisticsEvent>{};
        for (final rawEvent in rawEvents) {
          final event = ReadingStatisticsEvent.fromJson(rawEvent);
          final existing = events[event.id];
          events[event.id] = _mergeEvent(existing, event);
        }
        emit(
          ReadingStatisticsState(
            initialized: true,
            events: _sortEvents(events.values),
          ),
        );
      } else {
        emit(ReadingStatisticsState(initialized: true));
      }
    } catch (_) {
      if (!isClosed) {
        emit(
          ReadingStatisticsState(
            initialized: true,
            warning: '阅读统计数据读取失败，暂时显示空白统计。',
          ),
        );
      }
    }
  }

  Future<String> startSession(
    String bookId,
    String title, {
    DateTime? at,
  }) async {
    await initialize();
    if (bookId.isEmpty || bookId.length > 2048) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    final now = at ?? _clock();
    final sessionId =
        '${now.microsecondsSinceEpoch}-${identityHashCode(this).toRadixString(36)}-${++_idSequence}';
    final event = ReadingStatisticsEvent(
      id: '$sessionId:session',
      sessionId: sessionId,
      bookId: bookId,
      source: sourceOf(bookId).name,
      title: _limitTitle(title),
      kind: ReadingStatisticsEventKind.session,
      occurredAt: now,
      seconds: 0,
    );
    _activeSessions[sessionId] = _SessionProgress(now);
    _upsert(event);
    await _queuePersist();
    return sessionId;
  }

  /// Records elapsed foreground time, split into local date/hour buckets.
  /// Call at a low frequency (the scope uses a 30 second interval), not while
  /// painting or responding to page-turn frames.
  void recordElapsed(String sessionId, DateTime until) {
    final progress = _activeSessions[sessionId];
    if (progress == null || !until.isAfter(progress.checkpoint)) return;
    var cursor = progress.checkpoint;
    final increments = <DateTime, int>{};
    while (cursor.isBefore(until)) {
      var boundary = DateTime(
        cursor.year,
        cursor.month,
        cursor.day,
        cursor.hour + 1,
      );
      if (!boundary.isAfter(cursor)) {
        boundary = cursor.add(const Duration(hours: 1));
      }
      final end = boundary.isBefore(until) ? boundary : until;
      final micros =
          end.difference(cursor).inMicroseconds + progress.remainderMicros;
      final seconds = micros ~/ Duration.microsecondsPerSecond;
      progress.remainderMicros = micros % Duration.microsecondsPerSecond;
      if (seconds > 0) {
        final bucket = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          cursor.hour,
        );
        increments.update(
          bucket,
          (value) => value + seconds,
          ifAbsent: () => seconds,
        );
      }
      cursor = end;
    }
    progress.checkpoint = until;
    if (increments.isEmpty) return;
    final startEvent = state.events.firstWhere(
      (event) =>
          event.sessionId == sessionId &&
          event.kind == ReadingStatisticsEventKind.session,
    );
    for (final entry in increments.entries) {
      final datePart =
          '${entry.key.year.toString().padLeft(4, '0')}${entry.key.month.toString().padLeft(2, '0')}${entry.key.day.toString().padLeft(2, '0')}';
      final hourPart = entry.key.hour.toString().padLeft(2, '0');
      final id = '$sessionId:$datePart:$hourPart';
      final previous = _firstOrNull(
        state.events.where((event) => event.id == id),
      );
      final seconds = (previous?.seconds ?? 0) + entry.value;
      if (seconds > 86400) {
        throw StateError('Reading time bucket exceeded its limit.');
      }
      _upsert(
        ReadingStatisticsEvent(
          id: id,
          sessionId: sessionId,
          bookId: startEvent.bookId,
          source: startEvent.source,
          title: startEvent.title,
          kind: ReadingStatisticsEventKind.duration,
          occurredAt: entry.key,
          seconds: seconds,
        ),
      );
    }
    _queuePersist();
  }

  Future<void> endSession(String sessionId, {DateTime? at}) async {
    if (!_activeSessions.containsKey(sessionId)) return;
    recordElapsed(sessionId, at ?? _clock());
    _activeSessions.remove(sessionId);
    await _queuePersist();
  }

  ReadingStatisticsSnapshot snapshot({SourceId? source}) {
    final events =
        source == null
            ? state.events
            : state.events
                .where((event) => event.source == source.name)
                .toList(growable: false);
    return ReadingStatisticsSnapshot._(events);
  }

  String exportJson({SourceId? source}) {
    final events =
        source == null
            ? state.events
            : state.events
                .where((event) => event.source == source.name)
                .toList(growable: false);
    return _encodeEvents(events);
  }

  /// Merges a statistics backup. Identical ids are deduplicated; duration
  /// buckets keep the largest cumulative value so importing twice adds no time.
  Future<int> importJsonMerge(String raw) async {
    await initialize();
    if (utf8.encode(raw).length > maximumJsonBytes) {
      throw const FormatException('统计备份超过允许大小');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != readingStatisticsSchemaVersion) {
      throw const FormatException('统计备份版本不支持');
    }
    final rawEvents = decoded['events'];
    if (rawEvents is! List || rawEvents.length > maximumEvents) {
      throw const FormatException('统计事件数量无效');
    }
    final merged = {for (final event in state.events) event.id: event};
    var addedOrUpdated = 0;
    for (final rawEvent in rawEvents) {
      final event = ReadingStatisticsEvent.fromJson(rawEvent);
      final next = _mergeEvent(merged[event.id], event);
      if (next != merged[event.id]) {
        merged[event.id] = next;
        addedOrUpdated++;
      }
    }
    if (merged.length > maximumEvents) {
      throw const FormatException('合并后统计事件超过允许数量');
    }
    if (addedOrUpdated > 0) {
      emit(
        ReadingStatisticsState(
          initialized: true,
          events: _sortEvents(merged.values),
        ),
      );
      await _queuePersist();
    }
    return addedOrUpdated;
  }

  Future<void> persist() => _queuePersist();

  String _encodeEvents(Iterable<ReadingStatisticsEvent> events) => jsonEncode({
    'version': readingStatisticsSchemaVersion,
    'events': _sortEvents(
      events,
    ).map((event) => event.toJson()).toList(growable: false),
  });

  void _upsert(ReadingStatisticsEvent event) {
    final byId = {for (final existing in state.events) existing.id: existing};
    final merged = _mergeEvent(byId[event.id], event);
    byId[event.id] = merged;
    if (byId.length > maximumEvents) {
      throw StateError('Reading statistics event limit reached.');
    }
    emit(
      ReadingStatisticsState(
        initialized: true,
        events: _sortEvents(byId.values),
      ),
    );
  }

  Future<void> _queuePersist() {
    final encoded = _encodeEvents(state.events);
    final writeFuture = _saveQueue.then((_) => _write(encoded));
    _saveQueue = writeFuture.catchError((Object _) {
      if (!isClosed) {
        emit(
          ReadingStatisticsState(
            initialized: true,
            events: state.events,
            warning: '阅读统计暂时无法保存，请检查本机存储空间。',
          ),
        );
      }
    });
    return _saveQueue;
  }

  ReadingStatisticsEvent _mergeEvent(
    ReadingStatisticsEvent? existing,
    ReadingStatisticsEvent incoming,
  ) {
    if (existing == null) return incoming;
    if (existing.id != incoming.id ||
        existing.sessionId != incoming.sessionId ||
        existing.bookId != incoming.bookId ||
        existing.source != incoming.source ||
        existing.kind != incoming.kind) {
      throw const FormatException('重复统计编号的内容不一致');
    }
    if (incoming.kind == ReadingStatisticsEventKind.duration) {
      if (existing.occurredAt != incoming.occurredAt) {
        throw const FormatException('统计时长桶编号不一致');
      }
      return incoming.seconds > existing.seconds ? incoming : existing;
    }
    return incoming.occurredAt.isAfter(existing.occurredAt)
        ? incoming
        : existing;
  }

  List<ReadingStatisticsEvent> _sortEvents(
    Iterable<ReadingStatisticsEvent> events,
  ) {
    final result = events.toList(growable: false)..sort((a, b) {
      final byTime = a.occurredAt.compareTo(b.occurredAt);
      return byTime == 0 ? a.id.compareTo(b.id) : byTime;
    });
    return result;
  }

  String _limitTitle(String title) =>
      title.length <= 1024 ? title : title.substring(0, 1024);
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _requiredString(
  Object? value,
  String field,
  int maximum, {
  bool allowEmpty = false,
}) {
  if (value is! String ||
      value.length > maximum ||
      (!allowEmpty && value.isEmpty)) {
    throw FormatException('统计字段 $field 无效');
  }
  return value;
}

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}
