import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ShelfSession {
  ShelfSession._();
  static final instance = ShelfSession._();
  static const _storage = FlutterSecureStorage();
  static const _key = 'litetale.lns.refresh';
  final signedIn = ValueNotifier(false);
  String? _access;
  DateTime? _expires;
  Future<String?>? _refreshing;
  int _generation = 0;

  Future<void> load() async {
    signedIn.value = (await _storage.read(key: _key))?.isNotEmpty ?? false;
  }

  Future<void> login(String email, String password) async {
    final response = await http
        .post(
          Uri.parse('https://api.lightnovel.life/api/user/login'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'LiteTale/0.0.18',
          },
          // Matches the provider's official login form protocol.
          body: jsonEncode({
            'email': email.trim(),
            'password': sha256.convert(utf8.encode(password)).toString(),
          }),
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw StateError('登录服务暂不可用，请稍后重试');
    final raw = jsonDecode(utf8.decode(response.bodyBytes));
    if (raw is! Map || (raw['Success'] ?? raw['success']) != true) {
      throw StateError('登录未成功，请检查邮箱和密码或稍后重试');
    }
    final result = raw['Response'] ?? raw['response'];
    final refresh = result is Map ? result['RefreshToken'] : null;
    if (refresh is! String || refresh.isEmpty) throw StateError('登录状态缺失，请重试');
    await accept(refresh);
  }

  Future<void> accept(String refresh) async {
    if (refresh.isEmpty) throw const FormatException('尚未完成登录');
    final access = await _exchange(refresh);
    await _storage.write(key: _key, value: refresh);
    _generation++;
    _access = access;
    _expires = DateTime.now().add(const Duration(seconds: 30));
    signedIn.value = true;
  }

  Future<void> logout() async {
    _generation++;
    _access = null;
    _expires = null;
    await _storage.delete(key: _key);
    signedIn.value = false;
  }

  Future<String?> token({bool refresh = false}) {
    if (!refresh && _access != null && _expires!.isAfter(DateTime.now())) {
      return Future.value(_access);
    }
    return _refreshing ??= _renew().whenComplete(() => _refreshing = null);
  }

  Future<String?> _renew() async {
    final generation = _generation;
    final refresh = await _storage.read(key: _key);
    if (refresh == null || refresh.isEmpty) return null;
    final value = await _exchange(refresh);
    if (generation != _generation) return null;
    _access = value;
    _expires = DateTime.now().add(const Duration(seconds: 30));
    signedIn.value = true;
    return value;
  }

  Future<String> _exchange(String refresh) async {
    final response = await http
        .post(
          Uri.parse('https://api.lightnovel.life/api/user/refresh_token'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'LiteTale/0.0.18',
          },
          body: jsonEncode({'token': refresh}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('轻书架登录已失效或网络不可用，请重新登录');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is Map && (data['Success'] ?? data['success']) != true) {
      throw StateError('轻书架登录已失效，请重新登录');
    }
    final token =
        data is String
            ? data
            : data is Map
            ? data['Response'] ?? data['response'] ?? data['Token']
            : null;
    if (token is! String || token.isEmpty) {
      throw StateError('轻书架登录未完成，请在站点完成登录后重试');
    }
    return token;
  }
}
