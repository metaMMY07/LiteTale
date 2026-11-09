import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:wild/widgets/fluid_navigation_glyph.dart';

const _iconSlotTop = 10.0;
const _iconSlotHeight = 40.0;
const _indicatorHeight = 34.0;

class FluidNavigationDestination {
  const FluidNavigationDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.symbol,
    this.showBadge = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final FluidNavSymbol? symbol;
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
  late _IndicatorPlan _plan;
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    _plan = _IndicatorPlan.rest(widget.selectedIndex);
    _indicator = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context);
    if (!_animate) _settle();
  }

  @override
  void didUpdateWidget(covariant FluidNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex == widget.selectedIndex) return;
    if (!_animate) {
      _settle();
    } else {
      // Retarget each actual edge. Using a single estimated center would
      // collapse a stretched pill for one frame when tapping another tab.
      _plan = _IndicatorPlan(
        _plan.indicesAt(_indicator.value),
        widget.selectedIndex.toDouble(),
      );
      _indicator.forward(from: 0);
    }
  }

  void _settle() {
    _plan = _IndicatorPlan.rest(widget.selectedIndex);
    _indicator.value = 1;
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
    final labelStyle = theme.textTheme.labelMedium;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isLight ? colors.surfaceContainerHigh : colors.surface)
                .withValues(alpha: .72),
            border: Border(
              top: BorderSide(
                color: colors.outline.withValues(alpha: isLight ? .28 : .34),
              ),
            ),
          ),
          child: _navigationContent(
            colors: colors,
            isLight: isLight,
            labelStyle: labelStyle,
          ),
        ),
      ),
    );
  }

  Widget _navigationContent({
    required ColorScheme colors,
    required bool isLight,
    required TextStyle? labelStyle,
  }) {
    final selectedInk = isLight ? colors.onPrimary : colors.onPrimaryContainer;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 78,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final count = widget.destinations.length;
            if (count == 0) return const SizedBox.shrink();
            final itemWidth = constraints.maxWidth / count;
            return Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _FluidIndicatorPainter(
                        animation: _indicator,
                        plan: _plan,
                        count: count,
                        color:
                            isLight ? colors.primary : colors.primaryContainer,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var index = 0; index < count; index++)
                      Expanded(
                        child: _destination(
                          index,
                          itemWidth,
                          colors,
                          selectedInk,
                          labelStyle,
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _destination(
    int index,
    double width,
    ColorScheme colors,
    Color selectedInk,
    TextStyle? labelStyle,
  ) {
    final item = widget.destinations[index];
    final selected = index == widget.selectedIndex;
    final symbol = item.symbol;
    final idleInk = colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          onTap: () => widget.onDestinationSelected(index),
          child: Column(
            children: [
              const SizedBox(height: _iconSlotTop),
              SizedBox(
                height: _iconSlotHeight,
                child: Center(
                  child: Badge(
                    isLabelVisible: item.showBadge,
                    label: const Text('新'),
                    child:
                        symbol == null
                            ? Icon(
                              selected ? item.selectedIcon : item.icon,
                              size: fluidNavGlyphSize,
                              color: selected ? selectedInk : idleInk,
                            )
                            : FluidNavigationGlyph(
                              key: ValueKey(symbol),
                              symbol: symbol,
                              selected: selected,
                              color: _IndicatorInk(
                                _plan,
                                width,
                                index,
                                idleInk,
                                selectedInk,
                              ).animate(_indicator),
                            ),
                  ),
                ),
              ),
              Text(
                item.label,
                style: labelStyle?.copyWith(
                  color: selected ? colors.onSurface : idleInk,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Edges = ({double left, double right});

class _IndicatorPlan {
  const _IndicatorPlan(this.start, this.target);

  factory _IndicatorPlan.rest(int index) {
    final i = index.toDouble();
    return _IndicatorPlan((left: i, right: i), i);
  }

  final _Edges start;
  final double target;

  _Edges indicesAt(double t) {
    final lead = Curves.easeOutCubic.transform(t);
    final trail = Curves.easeInOutCubic.transform(t);
    final rightward = target >= (start.left + start.right) / 2;
    return (
      left: lerpDouble(start.left, target, rightward ? trail : lead)!,
      right: lerpDouble(start.right, target, rightward ? lead : trail)!,
    );
  }

  _Edges pixelsAt(double t, double itemWidth) {
    final halfPill = itemWidth.clamp(58.0, 88.0) / 2;
    final indices = indicesAt(t);
    return (
      left: (indices.left + .5) * itemWidth - halfPill,
      right: (indices.right + .5) * itemWidth + halfPill,
    );
  }
}

/// Contrast follows the pill across the icon slot instead of flipping the
/// moment selection changes while the pill is still on the old destination.
class _IndicatorInk extends Animatable<Color> {
  _IndicatorInk(this.plan, this.width, this.index, this.idle, this.selected);
  final _IndicatorPlan plan;
  final double width;
  final int index;
  final Color idle, selected;

  @override
  Color transform(double t) {
    final edges = plan.pixelsAt(t, width);
    final center = (index + .5) * width;
    const half = fluidNavGlyphSize / 2;
    final overlap =
        math.min(edges.right, center + half) -
        math.max(edges.left, center - half);
    final portion = (overlap / fluidNavGlyphSize).clamp(0.0, 1.0);
    return Color.lerp(idle, selected, Curves.easeInOut.transform(portion))!;
  }
}

class _FluidIndicatorPainter extends CustomPainter {
  _FluidIndicatorPainter({
    required this.animation,
    required this.plan,
    required this.count,
    required this.color,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final _IndicatorPlan plan;
  final int count;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (count == 0 || size.isEmpty) return;
    final edges = plan.pixelsAt(animation.value, size.width / count);
    final indicatorTop =
        _iconSlotTop + (_iconSlotHeight - _indicatorHeight) / 2;
    final rect = Rect.fromLTRB(
      edges.left,
      indicatorTop,
      edges.right,
      indicatorTop + _indicatorHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(24)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _FluidIndicatorPainter oldDelegate) =>
      oldDelegate.plan != plan ||
      oldDelegate.count != count ||
      oldDelegate.color != color ||
      oldDelegate.animation != animation;
}
