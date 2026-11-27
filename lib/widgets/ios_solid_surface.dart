import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

const double iosGroupedDividerThickness = 0.5;

Color iosGroupedDividerColor(BuildContext context) =>
    IosSystemColors.color('separator', Theme.of(context).brightness);

Widget iosGroupedDivider(
  BuildContext context, {
  EdgeInsetsGeometry indent = EdgeInsetsDirectional.zero,
}) => Padding(
  padding: indent,
  child: Divider(
    height: 1,
    thickness: iosGroupedDividerThickness,
    color: iosGroupedDividerColor(context),
  ),
);

BorderSide iosHairlineBorderSide(
  BuildContext context, {
  Color? color,
  double width = 0.5,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BorderSide(
    color:
        color ??
        (dark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.065)),
    width: width,
  );
}

ShapeBorder iosGroupedSolidShape(
  BuildContext context, {
  ShapeBorder? base,
  Color? borderColor,
  double borderWidth = 0.5,
}) {
  final side = iosHairlineBorderSide(
    context,
    color: borderColor,
    width: borderWidth,
  );
  final target = base ?? iosGroupedCardShape;
  if (target is OutlinedBorder) {
    return target.copyWith(side: side);
  }
  return iosGroupedCardShape.copyWith(side: side);
}

/// Shared continuous-corner iOS grouped container using borderless tonal
/// surface separation aligned with `01-card-reference.png` without modifying Android.
class IosGroupedCardSurface extends StatelessWidget {
  const IosGroupedCardSurface({
    super.key,
    required this.child,
    this.color,
    this.shape,
    this.elevation = 0,
    this.clipBehavior = Clip.antiAlias,
    this.bordered = false,
  });

  final Widget child;
  final Color? color;
  final ShapeBorder? shape;
  final double elevation;
  final Clip clipBehavior;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final resolvedShape = shape ?? iosGroupedCardShape;
    final resolvedColor = color ?? Theme.of(context).colorScheme.surface;
    final card = Material(
      color: resolvedColor,
      elevation: elevation,
      shape: resolvedShape,
      clipBehavior: clipBehavior,
      child: child,
    );
    if (!bordered) return card;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: iosGroupedSolidShape(context, base: resolvedShape),
      ),
      child: card,
    );
  }
}

/// Lightweight local press feedback for iOS solid controls and cards.
///
/// Uses local state on the individual control rather than ancestor rebuilds or
/// full-screen layers, and automatically settles on release, drag-out, scroll,
/// or route transitions so content always remains visible.
class IosPressFeedback extends StatefulWidget {
  const IosPressFeedback({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.passive = false,
    this.underlay = false,
    this.borderRadius,
    this.shape,
    this.scaleOnPress = 1.0,
    this.highlightColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool passive;
  final bool underlay;
  final BorderRadius? borderRadius;
  final ShapeBorder? shape;
  final double scaleOnPress;
  final Color? highlightColor;

  @override
  State<IosPressFeedback> createState() => _IosPressFeedbackState();
}

class _IosPressFeedbackState extends State<IosPressFeedback> {
  static const _pressDuration = Duration(milliseconds: 55);
  static const _releaseDuration = Duration(milliseconds: 140);
  static const _dragSlop = 18.0;

  bool _pressed = false;
  int? _pointer;
  Offset? _downPosition;
  ModalRoute<dynamic>? _route;

  bool get _interactive =>
      widget.enabled &&
      (widget.passive || widget.onTap != null || widget.onLongPress != null);

  bool get _routeCovered =>
      _route != null &&
      (!_route!.isCurrent ||
          _route!.offstage ||
          (_route!.secondaryAnimation?.value ?? 0) > 0);

  void _attachRoute(ModalRoute<dynamic>? next) {
    if (identical(_route, next)) return;
    _route?.animation?.removeListener(_onRouteChanged);
    _route?.secondaryAnimation?.removeListener(_onRouteChanged);
    _route = next;
    _route?.animation?.addListener(_onRouteChanged);
    _route?.secondaryAnimation?.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    if (!mounted) return;
    if (_pressed && _routeCovered) {
      _clearPointer();
    }
  }

  void _setPressed(bool value) {
    if (value && (_routeCovered || !TickerMode.of(context))) return;
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _clearPointer() {
    _pointer = null;
    _downPosition = null;
    _setPressed(false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachRoute(ModalRoute.of(context));
    if (_pressed && (_routeCovered || !TickerMode.of(context))) {
      _pointer = null;
      _downPosition = null;
      _pressed = false;
    }
  }

  @override
  void didUpdateWidget(covariant IosPressFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_interactive && _pressed) {
      _clearPointer();
    }
  }

  @override
  void deactivate() {
    _pointer = null;
    _downPosition = null;
    _pressed = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _attachRoute(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass || !_interactive) {
      return widget.child;
    }
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final tickerActive = TickerMode.of(context);
    final activePress = _pressed && !_routeCovered && tickerActive;

    Color overlayColor =
        widget.highlightColor ??
        theme.colorScheme.onSurface.withValues(alpha: dark ? 0.11 : 0.06);
    // Foreground overlays sit above child content; cap alpha so an accidental
    // opaque highlightColor can never mask row text, icons, or chevrons.
    if (!widget.underlay && overlayColor.a > 0.24) {
      overlayColor = overlayColor.withValues(alpha: 0.24);
    }

    final radius = widget.borderRadius ?? BorderRadius.circular(18);
    final Decoration overlayDecoration =
        widget.shape != null
            ? ShapeDecoration(
              color: activePress ? overlayColor : Colors.transparent,
              shape: widget.shape!,
            )
            : BoxDecoration(
              color: activePress ? overlayColor : Colors.transparent,
              borderRadius: radius,
            );

    final duration =
        disableAnimations || _routeCovered || !tickerActive
            ? Duration.zero
            : (activePress ? _pressDuration : _releaseDuration);

    final highlightLayer = Positioned.fill(
      child: IgnorePointer(
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          decoration: overlayDecoration,
        ),
      ),
    );

    Widget content = Stack(
      fit: StackFit.passthrough,
      children:
          widget.underlay
              ? [highlightLayer, widget.child]
              : [widget.child, highlightLayer],
    );

    if (widget.scaleOnPress != 1.0 && !disableAnimations) {
      content = AnimatedScale(
        scale: activePress ? widget.scaleOnPress : 1.0,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: content,
      );
    }

    Widget pointerTracked = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _pointer = event.pointer;
        _downPosition = event.position;
        _setPressed(true);
      },
      onPointerMove: (event) {
        if (_pointer != event.pointer || _downPosition == null) return;
        if ((event.position - _downPosition!).distance > _dragSlop) {
          _clearPointer();
        }
      },
      onPointerUp: (event) {
        if (_pointer == event.pointer) _clearPointer();
      },
      onPointerCancel: (event) {
        if (_pointer == event.pointer) _clearPointer();
      },
      child: content,
    );

    if (widget.passive) {
      return pointerTracked;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _clearPointer(),
      onTapCancel: _clearPointer,
      onTap:
          widget.enabled && widget.onTap != null
              ? () {
                _clearPointer();
                widget.onTap!();
              }
              : null,
      onLongPress:
          widget.enabled && widget.onLongPress != null
              ? () {
                _clearPointer();
                widget.onLongPress!();
              }
              : null,
      child: pointerTracked,
    );
  }
}

/// Solid iOS container replacing decorative Liquid Glass on normal UI chrome.
class IosSolidSurface extends StatelessWidget {
  const IosSolidSurface({
    super.key,
    required this.child,
    this.color,
    this.capsule = false,
    this.borderRadius,
    this.borderColor,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final Color? color;
  final bool capsule;
  final BorderRadius? borderRadius;
  final Color? borderColor;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final side = iosHairlineBorderSide(context, color: borderColor);
    final ShapeBorder shape =
        capsule
            ? StadiumBorder(side: side)
            : RoundedRectangleBorder(
              borderRadius: borderRadius ?? BorderRadius.circular(18),
              side: side,
            );
    return Material(
      color: color ?? colors.surface,
      shape: shape,
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}

/// Adaptive solid grouped card matching `AppleGlassCard`'s API without mounting
/// `UiKitView` or `BackdropFilter` inside scrolling lists.
class IosSolidCard extends StatelessWidget {
  const IosSolidCard({
    super.key,
    this.child,
    this.color,
    this.margin,
    this.clipBehavior = Clip.none,
    this.shape,
    this.elevation,
    this.onTap,
    this.onLongPress,
    this.pressFeedback = false,
    this.scaleOnPress = 1.0,
  }) : filled = false;

  const IosSolidCard.filled({
    super.key,
    this.child,
    this.color,
    this.margin,
    this.clipBehavior = Clip.none,
    this.shape,
    this.elevation,
    this.onTap,
    this.onLongPress,
    this.pressFeedback = false,
    this.scaleOnPress = 1.0,
  }) : filled = true;

  final Widget? child;
  final Color? color;
  final EdgeInsetsGeometry? margin;
  final Clip clipBehavior;
  final ShapeBorder? shape;
  final double? elevation;
  final bool filled;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool pressFeedback;
  final double scaleOnPress;

  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      final Widget? content =
          onTap != null || onLongPress != null
              ? InkWell(onTap: onTap, onLongPress: onLongPress, child: child)
              : child;
      return filled
          ? Card.filled(
            color: color,
            margin: margin,
            shape: shape,
            elevation: elevation,
            clipBehavior: clipBehavior,
            child: content,
          )
          : Card(
            color: color,
            margin: margin,
            shape: shape,
            elevation: elevation,
            clipBehavior: clipBehavior,
            child: content,
          );
    }

    final colors = Theme.of(context).colorScheme;
    final resolvedShape = shape ?? iosGroupedCardShape;
    final effectiveClip =
        clipBehavior == Clip.none ? Clip.antiAlias : clipBehavior;

    Widget cardContent = child ?? const SizedBox.shrink();
    if (onTap != null || onLongPress != null) {
      cardContent = IosPressFeedback(
        onTap: onTap,
        onLongPress: onLongPress,
        shape: resolvedShape,
        scaleOnPress: scaleOnPress,
        child: cardContent,
      );
    } else if (pressFeedback) {
      cardContent = IosPressFeedback(
        passive: true,
        shape: resolvedShape,
        scaleOnPress: scaleOnPress,
        child: cardContent,
      );
    }

    return Padding(
      padding: margin ?? const EdgeInsets.all(4),
      child: IosGroupedCardSurface(
        color:
            color ?? (filled ? colors.surfaceContainerHigh : colors.surface),
        elevation: elevation ?? 0,
        shape: resolvedShape,
        clipBehavior: effectiveClip,
        child: cardContent,
      ),
    );
  }
}

class IosSolidCircleButton extends StatelessWidget {
  const IosSolidCircleButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.size = 44,
    this.selected = false,
    this.backgroundColor,
    this.iconColor,
    this.iconSize,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool selected;
  final Color? backgroundColor;
  final Color? iconColor;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enabled = onPressed != null;
    final dimension = math.max(44.0, size);

    final fill =
        backgroundColor ??
        (selected
            ? Color.alphaBlend(
              colors.primary.withValues(alpha: dark ? 0.24 : 0.12),
              colors.surface,
            )
            : colors.surface);
    final border =
        selected
            ? BorderSide(
              color: colors.primary.withValues(alpha: dark ? 0.55 : 0.45),
              width: 0.75,
            )
            : iosHairlineBorderSide(context);
    final resolvedIconColor =
        enabled
            ? (iconColor ?? (selected ? colors.primary : colors.onSurface))
            : colors.onSurfaceVariant.withValues(alpha: 0.6);

    return SizedBox.square(
      dimension: dimension,
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: selected,
        label: label,
        onTap: onPressed,
        child: Tooltip(
          message: label,
          child: IosPressFeedback(
            enabled: enabled,
            onTap: onPressed,
            shape: const CircleBorder(),
            scaleOnPress: 0.96,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: fill,
                shape: CircleBorder(side: border),
              ),
              child: Center(
                child: ExcludeSemantics(
                  child: Icon(
                    icon,
                    size: iconSize ?? (dimension >= 52 ? 22 : 20),
                    color: resolvedIconColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class IosSolidPillButton extends StatelessWidget {
  const IosSolidPillButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.minHeight = 56,
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
    this.backgroundColor,
    this.foregroundColor,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final double minHeight;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enabled = onPressed != null;

    final fill =
        enabled
            ? (backgroundColor ??
                (dark ? Colors.white : const Color(0xFF111114)))
            : colors.primaryContainer;
    final ink =
        enabled
            ? (foregroundColor ??
                (dark ? const Color(0xFF111114) : Colors.white))
            : colors.onSurfaceVariant;
    final border =
        enabled && !dark
            ? BorderSide.none
            : iosHairlineBorderSide(
              context,
              color: enabled ? Colors.white.withValues(alpha: 0.12) : null,
            );

    return IosPressFeedback(
      passive: true,
      enabled: enabled,
      scaleOnPress: 0.98,
      borderRadius: BorderRadius.circular(999),
      highlightColor: ink.withValues(alpha: dark ? 0.14 : 0.16),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: fill,
            shape: StadiumBorder(side: border),
          ),
          child: CupertinoButton(
            padding: padding,
            minSize: minHeight,
            borderRadius: BorderRadius.circular(999),
            pressedOpacity: 0.92,
            onPressed: onPressed,
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: ink,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: ink, size: 20),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Primary accent-tinted native glass capsule button for iOS CTAs (such as
/// `关于 → 检查更新` and `字体设置 → 导入字体`), reusing `AppleGlassSurface`
/// without altering shared native glass chrome.
class IosAccentGlassCapsuleButton extends StatelessWidget {
  const IosAccentGlassCapsuleButton({
    super.key,
    required this.label,
    this.icon,
    this.trailingIcon,
    this.trailingIconSize = 14,
    required this.onPressed,
    this.busy = false,
    this.fullWidth = false,
    this.minHeight = 48,
    this.fontSize = 17,
    this.maxLines = 1,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    this.semanticsLabel,
    this.glassKey,
    this.buttonKey,
  });

  final String label;
  final IconData? icon;
  final IconData? trailingIcon;
  final double trailingIconSize;
  final VoidCallback? onPressed;
  final bool busy;
  final bool fullWidth;
  final double minHeight;
  final double fontSize;
  final int maxLines;
  final EdgeInsetsGeometry padding;
  final String? semanticsLabel;
  final Key? glassKey;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final enabled = onPressed != null && !busy;
    final foreground =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : const Color(0xFF111114);
    final contentColor =
        enabled
            ? foreground
            : foreground.withValues(alpha: busy ? 0.9 : 0.65);
    final tint = enabled || busy ? accent : accent.withValues(alpha: 0.52);

    final row = Row(
      mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy) ...[
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(contentColor),
            ),
          ),
          const SizedBox(width: 8),
        ] else if (icon != null) ...[
          Icon(icon, size: 19, color: contentColor),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: contentColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (trailingIcon != null) ...[
          const SizedBox(width: 5),
          Icon(trailingIcon, size: trailingIconSize, color: contentColor),
        ],
      ],
    );

    final body = IosPressFeedback(
      passive: true,
      enabled: enabled,
      scaleOnPress: 0.985,
      borderRadius: BorderRadius.circular(999),
      highlightColor: foreground.withValues(alpha: 0.16),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: AppleGlassSurface(
          key: glassKey,
          capsule: true,
          tint: tint,
          preserveTint: true,
          holdEnabled: enabled,
          child: CupertinoButton(
            key: buttonKey,
            padding: padding,
            minSize: minHeight,
            borderRadius: BorderRadius.circular(999),
            pressedOpacity: 0.9,
            onPressed: enabled ? onPressed : null,
            child: row,
          ),
        ),
      ),
    );

    if (semanticsLabel == null) return body;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: semanticsLabel,
      excludeSemantics: true,
      child: body,
    );
  }
}
