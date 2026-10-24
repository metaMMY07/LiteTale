import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

ThemeData iosGlassTheme(Brightness brightness, {Color? accent}) {
  final dark = brightness == Brightness.dark;
  Color system(String token) => IosSystemColors.color(token, brightness);
  final tint = accent ?? system('ios-blue');
  final colors = ColorScheme(
    brightness: brightness,
    primary: tint,
    onPrimary: Colors.white,
    secondary: tint,
    onSecondary: Colors.white,
    tertiary: system('ios-teal'),
    onTertiary: Colors.white,
    error: system('ios-red'),
    onError: Colors.white,
    surface: system('surface'),
    onSurface: system('label'),
    onSurfaceVariant: system('secondaryLabel'),
    primaryContainer: system('fill'),
    onPrimaryContainer: tint,
    secondaryContainer: system('fill'),
    onSecondaryContainer: system('label'),
    tertiaryContainer: system('fill'),
    onTertiaryContainer: system('label'),
    errorContainer: system('ios-red').withValues(alpha: .12),
    onErrorContainer: system('ios-red'),
    surfaceContainerLowest: system('background'),
    surfaceContainerLow: system('surface'),
    surfaceContainer: system('surface'),
    surfaceContainerHigh: system('tertiarySurface'),
    surfaceContainerHighest: system('tertiarySurface'),
    surfaceDim: system('background'),
    surfaceBright: system('surface'),
    outline: system('opaqueSeparator'),
    outlineVariant: system('separator'),
    inverseSurface: IosSystemColors.color(
      'surface',
      dark ? Brightness.light : Brightness.dark,
    ),
    onInverseSurface: IosSystemColors.color(
      'label',
      dark ? Brightness.light : Brightness.dark,
    ),
    inversePrimary: tint,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    platform: TargetPlatform.iOS,
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    // Flutter's iOS typography selects registered CupertinoSystem fonts.
    // Imported app fonts are applied afterwards by the app root.
    scaffoldBackgroundColor: system('background'),
    pageTransitionsTheme: horizontalPageTransitionsTheme,
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: system('background'),
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
    dividerColor: system('separator'),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: system('surface'),
      contentTextStyle: TextStyle(color: system('label'), fontSize: 15),
      actionTextColor: tint,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    progressIndicatorTheme: ProgressIndicatorThemeData(color: tint),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tint,
      selectionColor: tint.withValues(alpha: .22),
      selectionHandleColor: tint,
    ),
  );
}
