import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Gives each ordinary iOS route its own scroll clearance. A fullscreen
/// route above it can hide the bar without resizing the covered page.
class IosDockInsets extends InheritedWidget {
  const IosDockInsets({
    required this.height,
    required this.fullscreenRoutes,
    required super.child,
    super.key,
  });

  final double height;
  final Set<String> fullscreenRoutes;

  static Widget applyToPage(
    BuildContext context,
    PageRoute<dynamic> route,
    Widget child,
  ) {
    final insets = context.dependOnInheritedWidgetOfExactType<IosDockInsets>();
    if (insets == null ||
        route.fullscreenDialog ||
        insets.fullscreenRoutes.contains(route.settings.name)) {
      return child;
    }
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          bottom: math.max(media.padding.bottom, insets.height),
        ),
      ),
      child: child,
    );
  }

  /// For scroll views that supply explicit padding. SafeArea may already
  /// have consumed this clearance, in which case the remaining inset is zero.
  static double bottomOf(BuildContext context) {
    final insets = context.dependOnInheritedWidgetOfExactType<IosDockInsets>();
    if (insets == null || insets.height == 0) return 0;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return bottom >= insets.height ? insets.height : 0;
  }

  static EdgeInsets scrollPadding(BuildContext context, EdgeInsets padding) =>
      padding.copyWith(bottom: padding.bottom + bottomOf(context));

  @override
  bool updateShouldNotify(IosDockInsets oldWidget) =>
      oldWidget.height != height ||
      oldWidget.fullscreenRoutes != fullscreenRoutes;
}
