import 'package:flutter/material.dart';
import 'package:wild/settings/settings_preferences.dart';

ThemeData applySettingsTheme(ThemeData theme, SettingsPreferences settings) {
  final locale = hanLocale(settings.hanVariant);
  TextTheme regional(TextTheme t) => t.copyWith(
    displayLarge: t.displayLarge?.copyWith(locale: locale),
    displayMedium: t.displayMedium?.copyWith(locale: locale),
    displaySmall: t.displaySmall?.copyWith(locale: locale),
    headlineLarge: t.headlineLarge?.copyWith(locale: locale),
    headlineMedium: t.headlineMedium?.copyWith(locale: locale),
    headlineSmall: t.headlineSmall?.copyWith(locale: locale),
    titleLarge: t.titleLarge?.copyWith(locale: locale),
    titleMedium: t.titleMedium?.copyWith(locale: locale),
    titleSmall: t.titleSmall?.copyWith(locale: locale),
    bodyLarge: t.bodyLarge?.copyWith(locale: locale),
    bodyMedium: t.bodyMedium?.copyWith(locale: locale),
    bodySmall: t.bodySmall?.copyWith(locale: locale),
    labelLarge: t.labelLarge?.copyWith(locale: locale),
    labelMedium: t.labelMedium?.copyWith(locale: locale),
    labelSmall: t.labelSmall?.copyWith(locale: locale),
  );
  final black = settings.blackTheme && theme.brightness == Brightness.dark;
  return theme.copyWith(
    textTheme: regional(theme.textTheme),
    primaryTextTheme: regional(theme.primaryTextTheme),
    colorScheme:
        black
            ? theme.colorScheme.copyWith(
              surface: Colors.black,
              surfaceContainerLowest: Colors.black,
              surfaceContainerLow: const Color(0xFF101010),
            )
            : theme.colorScheme,
    scaffoldBackgroundColor:
        black ? Colors.black : theme.scaffoldBackgroundColor,
    appBarTheme: theme.appBarTheme.copyWith(
      backgroundColor: black ? Colors.black : theme.appBarTheme.backgroundColor,
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        locale: locale,
      ),
    ),
  );
}
