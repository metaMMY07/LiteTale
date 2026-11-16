import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

bool get usesMaterialYou => defaultTargetPlatform == TargetPlatform.android;

const materialCardRadius = 28.0;
const materialPanelRadius = 32.0;

Color materialRaisedSurface(ColorScheme colors) =>
    colors.brightness == Brightness.dark
        ? colors.surfaceContainerHigh
        : colors.surfaceContainerLowest;

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
          ? _withSurfaceTones(dynamicScheme)
          : ColorScheme.fromSeed(
            seedColor: seedColor ?? const Color(0xFF6750A4),
            brightness: brightness,
          );
  final raised = materialRaisedSurface(colors);
  final fieldRadius = BorderRadius.circular(24);
  const rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(materialCardRadius)),
  );
  const pill = StadiumBorder();
  return ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: horizontalPageTransitionsTheme,
    brightness: brightness,
    colorScheme: colors,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontWeight: FontWeight.w700),
      headlineMedium: TextStyle(fontWeight: FontWeight.w700),
      headlineSmall: TextStyle(fontWeight: FontWeight.w700),
      titleLarge: TextStyle(fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontWeight: FontWeight.w600),
      labelLarge: TextStyle(fontWeight: FontWeight.w600),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      // Flutter 3.29 still needs this switch for the gapped indicators.
      // ignore: deprecated_member_use
      year2023: false,
      linearTrackColor: colors.secondaryContainer,
      linearMinHeight: 4,
    ),
    sliderTheme: const SliderThemeData(
      // Use Flutter's gapped track and narrow handle on standard sliders.
      // ignore: deprecated_member_use
      year2023: false,
      trackHeight: 8,
    ),
    scaffoldBackgroundColor: colors.surfaceContainerLow,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: colors.surfaceContainerLow,
      foregroundColor: colors.onSurface,
      titleTextStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 28,
        fontWeight: FontWeight.w700,
      ),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: colors.surfaceContainerLow,
        systemNavigationBarIconBrightness:
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
      ),
    ),
    cardTheme: CardTheme(
      elevation: 0,
      color: raised,
      margin: EdgeInsets.zero,
      shape: rounded,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: raised,
      indicatorColor: colors.secondaryContainer,
      indicatorShape: pill,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.onSurfaceVariant,
      selectedColor: colors.onSecondaryContainer,
      selectedTileColor: colors.secondaryContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(colors.secondaryContainer),
      textStyle: WidgetStatePropertyAll(
        TextStyle(color: colors.onSecondaryContainer),
      ),
      hintStyle: WidgetStatePropertyAll(
        TextStyle(color: colors.onSecondaryContainer),
      ),
      shape: const WidgetStatePropertyAll(pill),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        shape: pill,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 52),
        shape: pill,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(48, 52),
        shape: pill,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      side: BorderSide.none,
      backgroundColor: colors.surfaceContainerHigh,
      selectedColor: colors.secondaryContainer,
      checkmarkColor: colors.onSecondaryContainer,
    ),
    tabBarTheme: TabBarTheme(
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: colors.primary,
      unselectedLabelColor: colors.onSurfaceVariant,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(materialPanelRadius),
        ),
      ),
      backgroundColor: colors.surfaceContainer,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: raised,
      elevation: 3,
      shape: rounded,
    ),
    dialogTheme: DialogTheme(
      backgroundColor: colors.surfaceContainer,
      shape: rounded,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

ColorScheme _withSurfaceTones(ColorScheme colors) {
  if (colors.surfaceContainerLowest != colors.surface ||
      colors.surfaceContainerLow != colors.surface ||
      colors.surfaceContainer != colors.surface ||
      colors.surfaceContainerHigh != colors.surface ||
      colors.surfaceContainerHighest != colors.surface) {
    return colors;
  }
  // dynamic_color also supplies older core palettes without container roles.
  // Fill in just those missing neutrals using the wallpaper's surface inks.
  final dark = colors.brightness == Brightness.dark;
  Color towardInk(double fraction) =>
      Color.lerp(colors.surface, colors.onSurface, fraction)!;
  return colors.copyWith(
    surfaceContainerLowest: Color.lerp(
      colors.surface,
      dark ? Colors.black : Colors.white,
      dark ? .42 : .8,
    ),
    surfaceContainerLow: towardInk(.025),
    surfaceContainer: towardInk(.05),
    surfaceContainerHigh: towardInk(.08),
    surfaceContainerHighest: towardInk(.12),
  );
}
