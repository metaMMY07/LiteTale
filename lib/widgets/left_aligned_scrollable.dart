import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Operation cards fill the row between the page insets. The scroll viewport
/// also covers the insets so dragging near either screen edge still scrolls.
class LeftAlignedScrollView extends StatelessWidget {
  const LeftAlignedScrollView({
    super.key,
    required this.child,
    this.maxContentWidth = double.infinity,
    this.phoneInset = 16,
    this.tabletInset = 32,
    this.topInset = 0,
    this.bottomInset = 24,
    this.controller,
    this.physics,
  });

  final Widget child;
  final double maxContentWidth;
  final double phoneInset;
  final double tabletInset;
  final double topInset;
  final double bottomInset;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = constraints.maxWidth < 600 ? phoneInset : tabletInset;
      final contentWidth = math.max(
        0.0,
        math.min(maxContentWidth, constraints.maxWidth - inset * 2),
      );
      return SingleChildScrollView(
        controller: controller,
        physics: physics,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Padding(
            padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: Padding(
                padding: EdgeInsetsDirectional.only(start: inset),
                child: SizedBox(width: contentWidth, child: child),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Builder-based operation list with full-width rows and a full-page viewport.
class LeftAlignedListView extends StatelessWidget {
  const LeftAlignedListView.builder({
    super.key,
    required this.itemBuilder,
    required this.itemCount,
    this.maxContentWidth = double.infinity,
    this.phoneInset = 16,
    this.tabletInset = 32,
    this.topInset = 0,
    this.bottomInset = 0,
    this.controller,
    this.physics,
  });

  final IndexedWidgetBuilder itemBuilder;
  final int itemCount;
  final double maxContentWidth;
  final double phoneInset;
  final double tabletInset;
  final double topInset;
  final double bottomInset;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = constraints.maxWidth < 600 ? phoneInset : tabletInset;
      final contentWidth = math.max(
        0.0,
        math.min(maxContentWidth, constraints.maxWidth - inset * 2),
      );
      return ListView.builder(
        controller: controller,
        physics: physics,
        padding: EdgeInsets.fromLTRB(inset, topInset, inset, bottomInset),
        itemCount: itemCount,
        itemBuilder:
            (context, index) => Align(
              alignment: AlignmentDirectional.topStart,
              child: SizedBox(
                width: contentWidth,
                child: itemBuilder(context, index),
              ),
            ),
      );
    },
  );
}

/// Custom sliver counterpart for operation pages that need lazy sliver lists.
class LeftAlignedCustomScrollView extends StatelessWidget {
  const LeftAlignedCustomScrollView({
    super.key,
    required this.slivers,
    this.maxContentWidth = double.infinity,
    this.phoneInset = 16,
    this.tabletInset = 32,
    this.topInset = 0,
    this.bottomInset = 0,
    this.controller,
    this.physics,
  });

  final List<Widget> slivers;
  final double maxContentWidth;
  final double phoneInset;
  final double tabletInset;
  final double topInset;
  final double bottomInset;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = constraints.maxWidth < 600 ? phoneInset : tabletInset;
      final contentWidth = math.max(
        0.0,
        math.min(maxContentWidth, constraints.maxWidth - inset * 2),
      );
      return CustomScrollView(
        controller: controller,
        physics: physics,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, topInset, inset, bottomInset),
            sliver: SliverConstrainedCrossAxis(
              maxExtent: contentWidth,
              sliver: SliverMainAxisGroup(slivers: slivers),
            ),
          ),
        ],
      );
    },
  );
}
