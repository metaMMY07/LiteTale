import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

/// Shared iOS Scaffold wrapper that extends scrolling content behind a
/// transparent top bar and renders a bounded progressive real-scene blur with
/// a feathered bottom edge (`03-top-blur-reference.png`).
///
/// Leaves Android and non-iOS platforms completely unchanged.
class IosTopBarScaffold extends StatefulWidget {
  const IosTopBarScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.backgroundColor,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.resetKey,
    this.backdropKey = const ValueKey('ios-progressive-top-bar-backdrop'),
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Object? resetKey;
  final Key backdropKey;

  static double progressForOffset(double pixels) =>
      ((pixels - 4.0) / 76.0).clamp(0.0, 1.0);

  @override
  State<IosTopBarScaffold> createState() => _IosTopBarScaffoldState();
}

class _IosTopBarScaffoldState extends State<IosTopBarScaffold> {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  @override
  void didUpdateWidget(covariant IosTopBarScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) {
      _progress.value = 0;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _updateMetrics(ScrollMetrics metrics) {
    if (!usesAppleGlass || metrics.axis != Axis.vertical) return;
    _progress.value = IosTopBarScaffold.progressForOffset(metrics.pixels);
  }

  bool _onScroll(ScrollNotification notification) {
    _updateMetrics(notification.metrics);
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    _updateMetrics(notification.metrics);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final appBar = widget.appBar;
    if (!usesAppleGlass || appBar == null) {
      return Scaffold(
        appBar: appBar,
        body: widget.body,
        backgroundColor: widget.backgroundColor,
        floatingActionButton: widget.floatingActionButton,
        bottomNavigationBar: widget.bottomNavigationBar,
      );
    }

    final statusBarTop = MediaQuery.paddingOf(context).top;
    final barBottom = statusBarTop + appBar.preferredSize.height;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: widget.backgroundColor,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.bottomNavigationBar,
      appBar: appBar,
      body: Stack(
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollMetricsNotification>(
            onNotification: _onMetrics,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: widget.body,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: barBottom + IosProgressiveTopBarBackdrop.featherExtent,
            child: IosProgressiveTopBarBackdrop(
              progress: _progress,
              barBottom: barBottom,
              backdropKey: widget.backdropKey,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bounded progressive real-scene blur + feathered translucent veil behind iOS
/// navigation bars. Covers only `SafeArea.top + appBarHeight + 22pt`, steps
/// blur sigma down across non-overlapping horizontal strips so the bottom edge
/// dissolves naturally without a hard white plate, and never intercepts touches.
class IosProgressiveTopBarBackdrop extends StatelessWidget {
  const IosProgressiveTopBarBackdrop({
    super.key,
    required this.progress,
    required this.barBottom,
    this.backdropKey = const ValueKey('ios-progressive-top-bar-backdrop'),
  });

  final ValueListenable<double> progress;
  final double barBottom;
  final Key backdropKey;

  static const double featherExtent = 22.0;
  static const List<double> _bandSigmas = <double>[14.0, 10.0, 6.2, 3.0, 1.1];

  @override
  Widget build(BuildContext context) {
    final onstage = TickerMode.of(context);
    if (!usesAppleGlass || !onstage) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final pageBg = theme.scaffoldBackgroundColor;
    final totalHeight = barBottom + featherExtent;
    final coreEnd = math.max(0.0, barBottom - 8.0);
    final tailSpan = totalHeight - coreEnd;
    final stepHeight = tailSpan / (_bandSigmas.length - 1);

    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, rawProgress, _) {
              final t = rawProgress.clamp(0.0, 1.0);
              if (t <= 0.005) return const SizedBox.shrink();

              return Stack(
                key: backdropKey,
                fit: StackFit.expand,
                children: [
                  if (coreEnd > 0)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: coreEnd,
                      child: ClipRect(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(
                            sigmaX: _bandSigmas[0] * t,
                            sigmaY: _bandSigmas[0] * t,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  for (var i = 1; i < _bandSigmas.length; i++)
                    Positioned(
                      top: coreEnd + stepHeight * (i - 1),
                      left: 0,
                      right: 0,
                      height: stepHeight,
                      child: ClipRect(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(
                            sigmaX: _bandSigmas[i] * t,
                            sigmaY: _bandSigmas[i] * t,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const <double>[0.0, 0.48, 0.76, 0.90, 1.0],
                        colors: <Color>[
                          pageBg.withValues(alpha: (dark ? 0.52 : 0.54) * t),
                          pageBg.withValues(alpha: (dark ? 0.34 : 0.36) * t),
                          pageBg.withValues(alpha: 0.14 * t),
                          pageBg.withValues(alpha: 0.04 * t),
                          pageBg.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
