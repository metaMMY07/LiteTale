import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

const iosAccentColors = <String, (String, CupertinoDynamicColor)>{
  'ios-blue': ('蓝色', CupertinoColors.systemBlue),
  'ios-indigo': ('靛蓝', CupertinoColors.systemIndigo),
  'ios-purple': ('紫色', CupertinoColors.systemPurple),
  'ios-pink': ('粉色', CupertinoColors.systemPink),
  'ios-red': ('红色', CupertinoColors.systemRed),
  'ios-orange': ('橙色', CupertinoColors.systemOrange),
  'ios-yellow': ('黄色', CupertinoColors.systemYellow),
  'ios-green': ('绿色', CupertinoColors.systemGreen),
  'ios-teal': ('青色', CupertinoColors.systemTeal),
};

const _legacyAccents = {
  'system': 'ios-blue',
  'iris': 'ios-purple',
  'blue': 'ios-blue',
  'rose': 'ios-pink',
  'orange': 'ios-orange',
  'teal': 'ios-teal',
  'green': 'ios-green',
};

String iosAccentKey(String value) {
  if (iosAccentColors.containsKey(value)) return value;
  return _legacyAccents[value] ?? 'ios-blue';
}

/// UIKit resolves system colors for both appearances, including device contrast.
/// Cupertino's semantic palette is the fallback during startup and in tests.
class IosSystemColors {
  static const _channel = MethodChannel('litetale/apple_palette');
  static Map<String, dynamic> _native = {};

  static Future<void> initialize() async {
    if (!Platform.isIOS) return;
    try {
      _native = Map<String, dynamic>.from(
        await _channel
                .invokeMapMethod<String, dynamic>('colors')
                .timeout(const Duration(seconds: 1)) ??
            {},
      );
    } on Exception {
      // Palette lookup never blocks access to books.
    }
  }

  static Color color(String token, Brightness brightness) {
    final values = _native[brightness == Brightness.dark ? 'dark' : 'light'];
    final native = values is Map ? values[token] : null;
    if (native is int) return Color(native);
    final dynamicColor =
        iosAccentColors[token]?.$2 ??
        switch (token) {
          'background' => CupertinoColors.systemGroupedBackground,
          'surface' => CupertinoColors.secondarySystemGroupedBackground,
          'tertiarySurface' => CupertinoColors.tertiarySystemGroupedBackground,
          'label' => CupertinoColors.label,
          'secondaryLabel' => CupertinoColors.secondaryLabel,
          'separator' => CupertinoColors.separator,
          'opaqueSeparator' => CupertinoColors.opaqueSeparator,
          'fill' => CupertinoColors.tertiarySystemFill,
          _ => CupertinoColors.systemBlue,
        };
    return brightness == Brightness.dark
        ? dynamicColor.darkColor
        : dynamicColor.color;
  }

  static Color accent(String preference, Brightness brightness) =>
      color(iosAccentKey(preference), brightness);
}
