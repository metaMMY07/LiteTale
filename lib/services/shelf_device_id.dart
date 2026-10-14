import 'dart:async';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'shelf_api_error.dart';

/// An installation's anonymous LightNovelShelf identifier, independent of login.
class ShelfDeviceId {
  ShelfDeviceId({
    Future<String?> Function()? readValue,
    Future<void> Function(String)? writeValue,
    this.storageTimeout = const Duration(seconds: 5),
  }) : _read = readValue ?? (() => _storage.read(key: _key)),
       _write = writeValue ?? ((id) => _storage.write(key: _key, value: id));

  static final instance = ShelfDeviceId();
  static const _storage = FlutterSecureStorage();
  static const _key = 'litetale.lns.deviceId';
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  static const _unavailable = ShelfApiException('轻书架设备标识暂时无法读取或保存，请稍后重试。');

  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final Duration storageTimeout;
  Future<String>? _pending;

  Future<String> value() {
    // Share the whole read/create/write operation, including first-use races.
    final request =
        _pending ??= _resolve().then(
          (id) => id,
          onError: (Object _, StackTrace __) {
            _pending = null;
            throw _unavailable;
          },
        );
    // Keep the actual operation after a caller times out. A late platform write
    // must not race a second generated identifier and overwrite it afterwards.
    return request.timeout(storageTimeout, onTimeout: () => throw _unavailable);
  }

  Future<String> _resolve() async {
    final stored = await _read();
    if (stored != null && stored.isNotEmpty) {
      if (stored.length != 36 || !_uuid.hasMatch(stored)) {
        throw const FormatException();
      }
      return stored;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    // Never send an identifier until its persistence has succeeded.
    await _write(id);
    return id;
  }
}
