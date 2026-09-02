import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Keeps book covers at a readable size on both narrow and desktop windows.
class BookGridDelegate extends SliverGridDelegate {
  const BookGridDelegate({
    this.preferredCardWidth = 220,
    this.childAspectRatio = 207 / 307,
    this.crossAxisSpacing = 8,
    this.mainAxisSpacing = 8,
    this.sectionItemCount,
  }) : assert(preferredCardWidth > 0),
       assert(childAspectRatio > 0),
       assert(crossAxisSpacing >= 0),
       assert(mainAxisSpacing >= 0),
       assert(sectionItemCount == null || sectionItemCount >= 0);

  final double preferredCardWidth;
  final double childAspectRatio;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  /// Only fixed recommendation sections should set this. A six-book section
  /// must not reserve a seventh, empty column when the window gets wider.
  /// Paginated lists and shelves leave this unset to keep sparse cards compact.
  final int? sectionItemCount;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    var columns = math.max(
      1,
      ((constraints.crossAxisExtent + crossAxisSpacing) /
              (preferredCardWidth + crossAxisSpacing))
          .ceil(),
    );
    final count = sectionItemCount;
    if (count != null && count > 0) columns = math.min(columns, count);

    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      childAspectRatio: childAspectRatio,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(covariant BookGridDelegate oldDelegate) {
    return preferredCardWidth != oldDelegate.preferredCardWidth ||
        childAspectRatio != oldDelegate.childAspectRatio ||
        crossAxisSpacing != oldDelegate.crossAxisSpacing ||
        mainAxisSpacing != oldDelegate.mainAxisSpacing ||
        sectionItemCount != oldDelegate.sectionItemCount;
  }
}
