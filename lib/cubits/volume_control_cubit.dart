import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/src/rust/api/database.dart';

class VolumeControlCubit extends Cubit<bool> {
  VolumeControlCubit({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
    bool? supported,
  }) : _read = read ?? (() => loadProperty(key: _key)),
       _write = write ?? ((value) => saveProperty(key: _key, value: value)),
       isSupported = supported ?? (Platform.isAndroid || Platform.isIOS),
       super(false);

  static const String _key = "_volumeControlProperty";
  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  final bool isSupported;
  Future<void> _pendingWrite = Future.value();
  int _revision = 0;
  bool _persistedEnabled = false;

  Future<void> init() async {
    if (!isSupported) return;

    final revision = _revision;
    try {
      final value = await _read();
      if (!isClosed && revision == _revision) {
        _persistedEnabled = value == 'true';
        emit(_persistedEnabled);
      }
    } catch (_) {
      // An unavailable preference leaves hardware volume control unchanged.
    }
  }

  Future<void> updateVolumeControl(bool enabled) async {
    if (!isSupported || isClosed) return;

    final revision = ++_revision;
    emit(enabled);
    final next = _pendingWrite.then((_) async {
      await _write(enabled.toString());
      _persistedEnabled = enabled;
    });
    _pendingWrite = next.catchError((Object _) {});
    try {
      await next;
    } catch (_) {
      if (!isClosed && revision == _revision) emit(_persistedEnabled);
      rethrow;
    }
  }

  bool get isEnabled => state;
}
