import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

// Matches the native Discover toolbar's 17pt Semibold title (PingFang SC Semibold on CJK).
const iosHomeTitleStyle = TextStyle(
  fontSize: 17,
  fontWeight: FontWeight.w600,
  letterSpacing: 0,
);

/// Continuous squircle card border matching iOS 26 inset-grouped surfaces
/// (`01-card-reference.png`), preserving a full ~26pt corner radius on both
/// multi-row groups and 56pt single-row cards without Flutter's
/// `ContinuousRectangleBorder` 2.3x radius shrinkage.
class IosGroupedCardBorder extends OutlinedBorder {
  const IosGroupedCardBorder({this.radius = 26, super.side});

  final double radius;

  static const double _kShoulder = 1.52866483;

  @override
  IosGroupedCardBorder copyWith({BorderSide? side, double? radius}) =>
      IosGroupedCardBorder(
        side: side ?? this.side,
        radius: radius ?? this.radius,
      );

  @override
  ShapeBorder scale(double t) =>
      IosGroupedCardBorder(side: side.scale(t), radius: radius * t);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is IosGroupedCardBorder) {
      return IosGroupedCardBorder(
        side: BorderSide.lerp(a.side, side, t),
        radius: a.radius + (radius - a.radius) * t,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is IosGroupedCardBorder) {
      return IosGroupedCardBorder(
        side: BorderSide.lerp(side, b.side, t),
        radius: radius + (b.radius - radius) * t,
      );
    }
    return super.lerpTo(b, t);
  }

  Path _buildPath(Rect rect) {
    if (rect.isEmpty) return Path();
    final shortest = math.min(rect.width, rect.height);
    final r = math.min(radius, shortest / 2.0);
    if (r <= 0) return Path()..addRect(rect);

    // Blend smoothly between an exact circular endcap when height == 2*r
    // and UIKit's full `.continuous` superellipse shoulder when height >= 3.06*r.
    final half = shortest / 2.0;
    final blend =
        r > 0 ? ((half - r) / ((_kShoulder - 1.0) * r)).clamp(0.0, 1.0) : 0.0;
    if (blend <= 0.001) {
      return Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
    }

    double mix(double circular, double continuous) =>
        circular + (continuous - circular) * blend;

    // Circular quarter-arc split at 45° vs Apple UIKit `.continuous` 3-segment corner.
    // Circle of radius r: tangent at 1.0*r, 45° point at (1 - cos45)*r = 0.2928932*r.
    // UIKit continuous: shoulder at 1.5286648*r, circular mid-arc of radius r around (r, r).
    const c45 = 0.29289322;
    const kHalfArc = 0.26521649; // (4/3)*tan(pi/16)
    final p = mix(1.0, _kShoulder) * r;
    final a = mix(1.0, 1.08849296) * r;
    final b = mix(1.0 - kHalfArc, 0.86840694) * r;
    final c = mix(c45 + kHalfArc * 0.70710678, 0.63149379) * r;
    final d = mix(c45 - kHalfArc * 0.70710678, 0.07491139) * r;
    final arcNear = mix(c45, 0.37159242) * r;
    final arcFar = mix(c45, 0.16905956) * r;

    final l = rect.left;
    final t = rect.top;
    final right = rect.right;
    final bottom = rect.bottom;
    final path = Path()..moveTo(l + p, t);

    void addCorner(
      double cx,
      double cy,
      double ux,
      double uy,
      double vx,
      double vy,
    ) {
      double px(double u, double v) => cx + u * ux + v * vx;
      double py(double u, double v) => cy + u * uy + v * vy;
      path
        ..lineTo(px(p, 0), py(p, 0))
        ..cubicTo(px(a, 0), py(a, 0), px(b, 0), py(b, 0), px(c, d), py(c, d))
        ..cubicTo(
          px(arcNear, arcFar),
          py(arcNear, arcFar),
          px(arcFar, arcNear),
          py(arcFar, arcNear),
          px(d, c),
          py(d, c),
        )
        ..cubicTo(px(0, b), py(0, b), px(0, a), py(0, a), px(0, p), py(0, p));
    }

    addCorner(right, t, -1, 0, 0, 1);
    addCorner(right, bottom, 0, -1, -1, 0);
    addCorner(l, bottom, 1, 0, 0, -1);
    addCorner(l, t, 0, 1, 1, 0);
    path.close();
    return path;
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _buildPath(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _buildPath(rect.deflate(side.strokeInset));

  @override
  bool get preferPaintInterior => true;

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) {
    canvas.drawPath(_buildPath(rect), paint);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style != BorderStyle.solid || side.width <= 0) return;
    canvas.drawPath(
      _buildPath(rect.deflate(side.strokeInset / 2)),
      side.toPaint(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IosGroupedCardBorder &&
          other.side == side &&
          other.radius == radius);

  @override
  int get hashCode => Object.hash(side, radius);
}

const iosGroupedCardShape = IosGroupedCardBorder(radius: 26);

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
      systemOverlayStyle:
          dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
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
      shape: iosGroupedCardShape,
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
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: tint),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tint,
      selectionColor: tint.withValues(alpha: .22),
      selectionHandleColor: tint,
    ),
  );
}
