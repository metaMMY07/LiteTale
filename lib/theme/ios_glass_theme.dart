import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

ThemeData iosGlassTheme(Brightness brightness, {Color? accent}) {
  final dark = brightness == Brightness.dark;
  final tint = accent ?? const Color(0xFFFF2D55);
  final colors = ColorScheme.fromSeed(
    seedColor: tint,
    brightness: brightness,
  ).copyWith(
    primary: tint,
    surface: dark ? const Color(0xFF1C1C1E) : Colors.white,
  );
  return ThemeData(
    platform: TargetPlatform.iOS,
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    // Flutter's iOS typography selects registered CupertinoSystem fonts.
    // Imported app fonts are applied afterwards by the app root.
    scaffoldBackgroundColor:
        dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
    pageTransitionsTheme: horizontalPageTransitionsTheme,
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
      foregroundColor: dark ? Colors.white : Colors.black,
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: tint,
    ),
    cardTheme: CardTheme(
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerColor: dark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6),
  );
}
