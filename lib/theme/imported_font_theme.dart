import 'package:flutter/material.dart';
import 'package:wild/theme/app_fonts.dart';

/// Keep the native default theme on reset, and retain CJK fallback when an
/// imported UI font only supplies Latin glyphs. Material Icons keep their family.
ThemeData applyImportedAppFont(ThemeData base, String? family) {
  if (family == null) return base;
  const fallback = [appFontFamily];
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: family,
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: family,
      fontFamilyFallback: fallback,
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: (base.appBarTheme.titleTextStyle ??
              base.textTheme.titleLarge)
          ?.copyWith(fontFamily: family, fontFamilyFallback: fallback),
      toolbarTextStyle: (base.appBarTheme.toolbarTextStyle ??
              base.textTheme.bodyMedium)
          ?.copyWith(fontFamily: family, fontFamilyFallback: fallback),
    ),
  );
}
