import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

bool get usesMaterialYou => defaultTargetPlatform == TargetPlatform.android;

/// Android 12 palettes may omit newer surface roles. Preserve the real accent
/// palette while still separating an opaque card from the page beneath it.
Color materialSurface(ColorScheme colors, Color role, double alpha) =>
    role == colors.surface
        ? Color.alphaBlend(
          colors.onSurface.withValues(alpha: alpha),
          colors.surface,
        )
        : role;

/// Android follows wallpaper colors when available, with a violet fallback or a chosen accent.
ThemeData materialYouTheme(
  Brightness brightness, {
  ColorScheme? dynamicScheme,
  Color? seedColor,
}) {
  // Preserve Android's actual wallpaper palette when system color is chosen.
  // Re-seeding from only its primary color loses the platform's tonal roles.
  final colors =
      seedColor == null && dynamicScheme != null
          ? dynamicScheme
          : ColorScheme.fromSeed(
            seedColor: seedColor ?? const Color(0xFF6750A4),
            brightness: brightness,
          );
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(24),
  );
  return ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: horizontalPageTransitionsTheme,
    brightness: brightness,
    colorScheme: colors,
    // Flutter 3.29 still needs this switch for the updated inline indicators.
    // ignore: deprecated_member_use
    progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
    scaffoldBackgroundColor: materialSurface(
      colors,
      colors.surfaceContainerLow,
      .025,
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: materialSurface(
        colors,
        colors.surfaceContainerLow,
        .025,
      ),
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
      color: materialSurface(colors, colors.surfaceContainerHigh, .08),
      margin: EdgeInsets.zero,
      shape: rounded,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: colors.surfaceContainer,
      indicatorColor: colors.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    listTileTheme: ListTileThemeData(iconColor: colors.onSurfaceVariant),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(
        materialSurface(colors, colors.surfaceContainerHigh, .08),
      ),
      side: const WidgetStatePropertyAll(BorderSide.none),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
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
      backgroundColor: colors.surfaceContainerHigh,
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
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceContainerHigh,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
