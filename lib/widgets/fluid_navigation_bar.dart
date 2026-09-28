import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';

const _iconSlotTop = 10.0;
const _iconSlotHeight = 40.0;
const _indicatorHeight = 34.0;

class FluidNavigationDestination {
  const FluidNavigationDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.showBadge = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool showBadge;
}

/// A small, paint-only navigation indicator inspired by the supplied video.
/// The leading edge arrives first, then the trailing edge catches up.
class FluidNavigationBar extends StatefulWidget {
  const FluidNavigationBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<FluidNavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  State<FluidNavigationBar> createState() => _FluidNavigationBarState();
}

class _FluidNavigationBarState extends State<FluidNavigationBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _indicator;
  late double _fromIndex;
  late double _toIndex;

  @override
  void initState() {
    super.initState();
    _fromIndex = widget.selectedIndex.toDouble();
    _toIndex = _fromIndex;
    _indicator = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant FluidNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex == widget.selectedIndex) return;
    final eased = Curves.easeInOutCubic.transform(_indicator.value);
    _fromIndex = lerpDouble(_fromIndex, _toIndex, eased)!;
    _toIndex = widget.selectedIndex.toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _fromIndex = _toIndex;
      _indicator.value = 1;
    } else {
      _indicator.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _indicator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isLight = theme.brightness == Brightness.light;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final labelStyle = theme.textTheme.labelMedium;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isLight ? colors.surfaceContainerHigh : colors.surface)
                .withValues(alpha: 0.72),
            border: Border(
              top: BorderSide(
                color: colors.outline.withValues(alpha: isLight ? 0.28 : 0.34),
              ),
            ),
          ),
          child: _navigationContent(
            colors: colors,
            isLight: isLight,
            reduceMotion: reduceMotion,
            labelStyle: labelStyle,
          ),
        ),
      ),
    );
  }

  Widget _navigationContent({
    required ColorScheme colors,
    required bool isLight,
    required bool reduceMotion,
    required TextStyle? labelStyle,
  }) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 78,
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _FluidIndicatorPainter(
                    animation: _indicator,
                    fromIndex: _fromIndex,
                    toIndex: _toIndex,
                    count: widget.destinations.length,
                    color: isLight ? colors.primary : colors.primaryContainer,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (var index = 0; index < widget.destinations.length; index++)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: index == widget.selectedIndex,
                      label: widget.destinations[index].label,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          splashFactory: NoSplash.splashFactory,
                          overlayColor: WidgetStateProperty.all(
                            Colors.transparent,
                          ),
                          onTap: () => widget.onDestinationSelected(index),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              const SizedBox(height: _iconSlotTop),
                              SizedBox(
                                height: _iconSlotHeight,
                                child: Center(
                                  child: AnimatedScale(
                                    scale:
                                        index == widget.selectedIndex
                                            ? 1.08
                                            : 1,
                                    duration:
                                        reduceMotion
                                            ? Duration.zero
                                            : const Duration(milliseconds: 190),
                                    curve: Curves.easeOutCubic,
                                    child: Badge(
                                      isLabelVisible:
                                          widget.destinations[index].showBadge,
                                      label: const Text('新'),
                                      child: Icon(
                                        index == widget.selectedIndex
                                            ? widget
                                                .destinations[index]
                                                .selectedIcon
                                            : widget.destinations[index].icon,
                                        size: 25,
                                        color:
                                            index == widget.selectedIndex
                                                ? (isLight
                                                    ? colors.onPrimary
                                                    : colors.onPrimaryContainer)
                                                : colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                widget.destinations[index].label,
                                style: labelStyle?.copyWith(
                                  color:
                                      index == widget.selectedIndex
                                          ? colors.onSurface
                                          : colors.onSurfaceVariant,
                                  fontWeight:
                                      index == widget.selectedIndex
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FluidIndicatorPainter extends CustomPainter {
  _FluidIndicatorPainter({
    required this.animation,
    required this.fromIndex,
    required this.toIndex,
    required this.count,
    required this.color,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final double fromIndex;
  final double toIndex;
  final int count;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (count == 0 || size.isEmpty) return;
    final itemWidth = size.width / count;
    final pillWidth = itemWidth.clamp(58.0, 88.0).toDouble();
    final startCenter = (fromIndex + 0.5) * itemWidth;
    final endCenter = (toIndex + 0.5) * itemWidth;
    final startLeft = startCenter - pillWidth / 2;
    final startRight = startCenter + pillWidth / 2;
    final endLeft = endCenter - pillWidth / 2;
    final endRight = endCenter + pillWidth / 2;
    final progress = animation.value;
    final lead = Curves.easeOutCubic.transform(progress);
    final trail = Curves.easeInOutCubic.transform(progress);
    final movingRight = endCenter >= startCenter;
    final left = lerpDouble(startLeft, endLeft, movingRight ? trail : lead)!;
    final right = lerpDouble(startRight, endRight, movingRight ? lead : trail)!;
    final indicatorTop =
        _iconSlotTop + (_iconSlotHeight - _indicatorHeight) / 2;
    final rect = Rect.fromLTRB(
      left,
      indicatorTop,
      right,
      indicatorTop + _indicatorHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(24)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _FluidIndicatorPainter oldDelegate) =>
      oldDelegate.fromIndex != fromIndex ||
      oldDelegate.toIndex != toIndex ||
      oldDelegate.count != count ||
      oldDelegate.color != color ||
      oldDelegate.animation != animation;
}
