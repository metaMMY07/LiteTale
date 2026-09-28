import 'package:flutter/services.dart';

const launcherIconChoices = <String, String>{
  'iris': '鸢尾紫',
  'blue': '晴空蓝',
  'rose': '蔷薇粉',
  'orange': '暖杏橙',
  'teal': '湖水青',
  'green': '森林绿',
};

class LauncherIconService {
  const LauncherIconService();

  static const _channel = MethodChannel('litetale/launcher_icon');

  Future<String> current() async {
    final name = await _channel.invokeMethod<String>('getIcon');
    return launcherIconChoices.containsKey(name) ? name! : 'iris';
  }

  Future<void> select(String name) async {
    if (!launcherIconChoices.containsKey(name)) {
      throw ArgumentError.value(name, 'name', 'Unknown launcher icon');
    }
    await _channel.invokeMethod<String>('setIcon', name);
  }
}
