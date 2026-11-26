import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:wild/services/shelf_api_error.dart';
import 'package:wild/services/shelf_device_id.dart';

export 'package:wild/services/shelf_api_error.dart' show ShelfSignInRequired;

class ShelfSession {
  ShelfSession({
    http.Client Function()? createClient,
    Future<String?> Function()? readCredential,
    Future<void> Function(String)? writeCredential,
    Future<void> Function()? deleteCredential,
    Future<String> Function()? deviceId,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _createClient = createClient ?? http.Client.new,
       _deviceId = deviceId ?? ShelfDeviceId.instance.value,
       _readCredential = readCredential ?? (() => _storage.read(key: _key)),
       _writeCredential =
           writeCredential ?? ((v) => _storage.write(key: _key, value: v)),
       _deleteCredential =
           deleteCredential ?? (() => _storage.delete(key: _key));
  static final instance = ShelfSession();
  static const _storage = FlutterSecureStorage();
  static const _key = 'litetale.lns.refresh';
  final http.Client Function() _createClient;
  final Future<String> Function() _deviceId;
  final Future<String?> Function() _readCredential;
  final Future<void> Function(String) _writeCredential;
  final Future<void> Function() _deleteCredential;
  final Duration requestTimeout;
  final signedIn = ValueNotifier(false);
  String? _access;
  DateTime? _expires;
  Future<String?>? _refreshing;
  Future<void> _credentialWrites = Future.value();
  int _generation = 0;
  int get generation => _generation;

  Future<T> _credentials<T>(Future<T> Function() action) {
    final next = _credentialWrites.then(
      (_) => action(),
      onError: (_) => action(),
    );
    _credentialWrites = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  Future<void> load() async {
    final generation = _generation;
    final refresh = await _readRefresh();
    if (generation != _generation) return;
    signedIn.value = refresh?.isNotEmpty ?? false;
    if (!signedIn.value) {
      _access = null;
      _expires = null;
    }
  }

  int _beginChange() {
    _generation++;
    _access = null;
    _expires = null;
    _refreshing = null;
    return _generation;
  }

  Future<void> login(String email, String password) async {
    final generation = _beginChange();
    // Exactly one login POST. Retrying credentials can duplicate a login or
    // trigger rate limits, so only a user's explicit retry may submit again.
    final raw = await _post('/api/user/login', {
      'email': email.trim(),
      'password': sha256.convert(utf8.encode(password)).toString(),
    });
    if (raw is! Map) throw shelfInvalidResponse;
    if ((raw['Success'] ?? raw['success']) != true) {
      throw const ShelfApiException('登录未成功，请检查邮箱和密码或稍后重试。');
    }
    final result = raw['Response'] ?? raw['response'];
    final refresh =
        result is Map ? result['RefreshToken'] ?? result['refreshToken'] : null;
    final access = result is Map ? result['Token'] ?? result['token'] : null;
    if (refresh is! String || refresh.isEmpty) throw shelfInvalidResponse;
    await _accept(
      refresh,
      generation,
      access: access is String && access.isNotEmpty ? access : null,
    );
  }

  Future<void> accept(String refresh) => _accept(refresh, _beginChange());

  Future<void> _accept(String refresh, int generation, {String? access}) async {
    if (refresh.isEmpty) throw const FormatException('尚未完成登录');
    if (generation != _generation) throw const ShelfApiException('登录已取消，请重试。');
    final value = access ?? await _exchange(refresh);
    final saved = await _credentials(() async {
      if (generation != _generation) return false;
      await _writeCredential(refresh);
      return generation == _generation;
    });
    if (!saved || generation != _generation) {
      throw const ShelfApiException('登录已取消，请重试。');
    }
    _cacheAccess(value);
    signedIn.value = true;
  }

  Future<void> logout() async {
    _beginChange();
    signedIn.value = false;
    // This deletion is queued before any replacement login can save its token.
    // A replacement login that fails must not cancel the explicit logout.
    await _credentials(_deleteCredential);
  }

  Future<String?> token({bool refresh = false, String? rejectedToken}) {
    if (_access != null &&
        _expires!.isAfter(DateTime.now()) &&
        (!refresh || (rejectedToken != null && rejectedToken != _access))) {
      return Future.value(_access);
    }
    if (_refreshing case final pending?) return pending;
    late final Future<String?> request;
    request = _renew().whenComplete(() {
      if (identical(_refreshing, request)) _refreshing = null;
    });
    _refreshing = request;
    return request;
  }

  Future<String?> _renew() async {
    final generation = _generation;
    final refresh = await _readRefresh();
    if (generation != _generation || refresh == null || refresh.isEmpty) {
      return null;
    }
    try {
      final value = await _exchange(refresh);
      if (generation != _generation) return null;
      _cacheAccess(value);
      signedIn.value = true;
      return value;
    } on ShelfSignInRequired {
      // Only an explicit 401/404/-100 for this refresh token invalidates it.
      // DNS, timeout and 5xx leave the account and its credential intact.
      if (generation == _generation) await logout();
      rethrow;
    }
  }

  void _cacheAccess(String token) {
    var lifetime = const Duration(seconds: 30);
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
      );
      if (claims is Map && claims['exp'] is num) {
        final remaining =
            DateTime.fromMillisecondsSinceEpoch(
              (claims['exp'] as num).toInt() * 1000,
            ).difference(DateTime.now()) -
            const Duration(seconds: 30);
        lifetime = Duration(seconds: remaining.inSeconds.clamp(0, 300));
      }
    } catch (_) {
      /* Opaque tokens use a conservative short cache. */
    }
    _access = token;
    _expires = DateTime.now().add(lifetime);
  }

  Future<String?> _readRefresh() async {
    final generation = _generation;
    try {
      return await _credentials(_readCredential);
    } on PlatformException catch (error) {
      if (!_isUnreadableCredential(error)) rethrow;
      if (generation != _generation) return null;
      final clearedGeneration = _beginChange();
      signedIn.value = false;
      try {
        await _credentials(() async {
          if (clearedGeneration == _generation) await _deleteCredential();
        });
      } on PlatformException {
        throw const ShelfSignInRequired();
      }
      return null;
    }
  }

  bool _isUnreadableCredential(PlatformException error) {
    if (error.message != 'read') return false;
    final details = error.details?.toString().toLowerCase() ?? '';
    return details.contains('bad_decrypt') ||
        details.contains('badpaddingexception') ||
        details.contains('aeadbadtagexception') ||
        details.contains('failed to unwrap key');
  }

  Future<String> _exchange(String refresh) async {
    final data = await _post('/api/user/refresh_token', {
      'token': refresh,
    }, refreshing: true);
    if (data is Map && (data['Success'] ?? data['success']) != true) {
      throw ShelfApiException.envelope(data);
    }
    final token =
        data is String
            ? data
            : data is Map
            ? data['Response'] ??
                data['response'] ??
                data['Token'] ??
                data['token']
            : null;
    if (token is! String || token.isEmpty) throw shelfInvalidResponse;
    return token;
  }

  Future<Object?> _post(
    String path,
    Map<String, String> body, {
    bool refreshing = false,
  }) async {
    final client = _createClient();
    final generation = _generation;
    final elapsed = Stopwatch()..start();
    try {
      final deviceId = await _deviceId().timeout(requestTimeout);
      if (generation != _generation) {
        throw const ShelfApiException('轻书架账号状态已变化，请重试。');
      }
      final remaining = requestTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw shelfTimeoutError;
      final response = await client
          .post(
            Uri.parse('https://api.lightnovel.life$path'),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'LiteTale/0.1.17',
              'x-id': deviceId,
            },
            body: jsonEncode(body),
          )
          .timeout(remaining);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ShelfApiException.http(
          response.statusCode,
          refreshing: refreshing,
        );
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on TimeoutException {
      throw shelfTimeoutError;
    } on http.ClientException {
      throw shelfNetworkError;
    } on IOException {
      throw shelfNetworkError;
    } on FormatException {
      throw shelfInvalidResponse;
    } finally {
      client.close();
    }
  }
}
