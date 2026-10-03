import 'package:flutter/painting.dart';
import 'package:wild/theme/app_fonts.dart';
import 'package:wild/settings/settings_preferences.dart' show readerHanLocale;

/// Explicit metrics keep a paper page independent of the surrounding app's
/// DefaultTextStyle. Both pagination and the rendered paragraphs use this.
TextStyle readerBodyStyle({
  required double fontSize,
  required double lineHeight,
  String? fontFamily,
  bool boldText = false,
  Color? color,
}) => TextStyle(
  inherit: false,
  locale: readerHanLocale,
  fontFamily: fontFamily ?? appFontFamily,
  fontFamilyFallback: const [appFontFamily],
  fontSize: fontSize,
  height: lineHeight,
  letterSpacing: 0.5,
  fontWeight: boldText ? FontWeight.bold : FontWeight.normal,
  color: color,
);
