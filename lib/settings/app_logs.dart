import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class AppLogEntry {
  const AppLogEntry(this.time, this.level, this.message);
  final DateTime time;
  final String level;
  final String message;
  Map<String, String> toJson() => {
    'time': time.toIso8601String(),
    'level': level,
    'message': message,
  };
}

/// Operation messages are authored at call sites. Never capture request bodies,
/// user credentials, headers, book text, or raw exception strings.
class AppLogs extends ChangeNotifier {
  static final instance = AppLogs();
  String level = 'error';
  File? _file;
  final List<AppLogEntry> _entries = [];
  Future<void> _pending = Future.value();
  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  Future<void> initialize(String root) async {
    _file = File('$root/litetale_app.log');
    try {
      if (await _file!.exists() && await _file!.length() < 512 * 1024) {
        final rows = jsonDecode(await _file!.readAsString()) as List;
        _entries.clear();
        for (final item in rows.take(200)) {
          if (item is Map &&
              item['message'] is String &&
              item['level'] is String) {
            final time = DateTime.tryParse('${item['time']}');
            if (time != null) {
              _entries.add(AppLogEntry(time, item['level'], item['message']));
            }
          }
        }
        notifyListeners();
      }
    } catch (_) {
      /* Invalid optional diagnostic data is ignored. */
    }
  }

  Future<void> record(String severity, String message) {
    const levels = ['off', 'error', 'info', 'debug'];
    if (level == 'off' || levels.indexOf(severity) > levels.indexOf(level)) {
      return Future.value();
    }
    if (message.length > 256) return Future.value();
    _entries.insert(0, AppLogEntry(DateTime.now(), severity, message));
    if (_entries.length > 200) _entries.length = 200;
    notifyListeners();
    final payload = jsonEncode(_entries.map((e) => e.toJson()).toList());
    final next = _pending.then(
      (_) async => _file?.writeAsString(payload, flush: true),
    );
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return _pending;
  }

  String exportText() => _entries
      .map((e) => '${e.time.toIso8601String()} [${e.level}] ${e.message}')
      .join('\n');
}
