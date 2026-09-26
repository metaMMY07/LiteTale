import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/src/rust/api/database.dart';

const appAccentColors = <String, (String, Color)>{
  'iris': ('鸢尾紫', Color(0xFF6750A4)),
  'blue': ('晴空蓝', Color(0xFF3864A0)),
  'rose': ('蔷薇粉', Color(0xFFAD416B)),
  'orange': ('暖杏橙', Color(0xFF995C22)),
  'teal': ('湖水青', Color(0xFF006B65)),
  'green': ('森林绿', Color(0xFF526B50)),
};

final _customAccentPattern = RegExp(r'^custom:#[0-9a-fA-F]{6}$');

/// A system palette has no seed; preset and custom choices have one.
Color? appAccentSeed(String value) {
  final preset = appAccentColors[value];
  if (preset != null) return preset.$2;
  if (!_customAccentPattern.hasMatch(value)) return null;
  return Color(0xFF000000 | int.parse(value.substring(8), radix: 16));
}

String customAccentValue(Color color) =>
    'custom:#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

bool _validAccent(String value) =>
    value == 'system' ||
    appAccentColors.containsKey(value) ||
    _customAccentPattern.hasMatch(value);

class AppAccentCubit extends Cubit<String> {
  AppAccentCubit({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => loadProperty(key: 'app_accent_v1')),
       _write =
           write ??
           ((value) => saveProperty(key: 'app_accent_v1', value: value)),
       super('system');

  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  Future<void> _pendingWrite = Future.value();
  int _revision = 0;

  Future<void> load() async {
    final revision = _revision;
    try {
      final value = await _read();
      if (!isClosed && revision == _revision && _validAccent(value)) {
        emit(value);
      }
    } catch (_) {
      // A missing preference uses the system palette.
    }
  }

  Future<void> select(String value) async {
    if (!_validAccent(value)) return;
    _revision++;
    emit(value);
    // Preserve selection order when the user taps several colors quickly.
    final next = _pendingWrite.then((_) => _write(value));
    _pendingWrite = next.catchError((Object _) {});
    await next;
  }
}
