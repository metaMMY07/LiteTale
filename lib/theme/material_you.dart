import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get usesMaterialYou => defaultTargetPlatform == TargetPlatform.android;

/// Android follows wallpaper colors when available, with a violet fallback or a chosen accent.
ThemeData materialYouTheme(
  Brightness brightness, {
  ColorScheme? dynamicScheme,
  Color? seedColor,
}) {
  // The compatible dynamic_color plugin supplies the original M3 roles only.
  // Regenerate from its wallpaper accent to include current tonal surfaces.
  final colors = ColorScheme.fromSeed(
    seedColor: seedColor ?? dynamicScheme?.primary ?? const Color(0xFF6750A4),
    brightness: brightness,
  );
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(24),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      titleTextStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 26,
        fontWeight: FontWeight.w600,
      ),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: colors.surfaceContainer,
        systemNavigationBarIconBrightness:
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
      ),
    ),
    cardTheme: CardTheme(
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: rounded,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: colors.surfaceContainer,
      indicatorColor: colors.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: colors.surfaceContainerLow,
      selectedColor: colors.secondaryContainer,
    ),
    tabBarTheme: TabBarTheme(
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: colors.primary,
      unselectedLabelColor: colors.onSurfaceVariant,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: colors.surfaceContainerLow,
      shape: rounded,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
