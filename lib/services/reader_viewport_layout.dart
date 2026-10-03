import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Pagination and painting share the same leaf bounds, including in split
/// windows. A phone in landscape remains one page; a wide tablet gets a spread.
class ReaderViewportLayout {
  ReaderViewportLayout({
    required Size size,
    required this.systemPadding,
    required double leftPadding,
    required double rightPadding,
    required double topBarHeight,
    required double bottomBarHeight,
    this.textScaler = TextScaler.noScaling,
    this.boldText = false,
  }) : isSpread = size.width > size.height && size.shortestSide >= 600,
       viewportSize = size {
    leafWidth = size.width / (isSpread ? 2 : 1);
    final bookInset = isSpread ? (leafWidth * 0.105).clamp(24.0, 80.0) : 0.0;
    headerHeight = isSpread ? math.max(28, textScaler.scale(12) * 1.2) : 0;
    insets = EdgeInsets.fromLTRB(
      leftPadding + bookInset,
      systemPadding.top +
          (isSpread ? math.max(20, topBarHeight / 2) : topBarHeight),
      rightPadding + bookInset,
      systemPadding.bottom + bottomBarHeight,
    );
  }

  final bool isSpread;
  final Size viewportSize;
  final EdgeInsets systemPadding;
  final TextScaler textScaler;
  final bool boldText;
  late final double leafWidth;
  late final EdgeInsets insets;
  late final double headerHeight;

  double get contentWidth => leafWidth - insets.horizontal;
  double get contentHeight =>
      viewportSize.height - insets.vertical - headerHeight;
  int viewCount(int physicalPages) =>
      isSpread ? (physicalPages + 1) ~/ 2 : physicalPages;
  int viewIndex(int physicalPage) =>
      isSpread ? physicalPage ~/ 2 : physicalPage;
  int firstPage(int view) => isSpread ? view * 2 : view;
}
