import 'package:flutter/material.dart';
import 'package:wild/theme/material_you.dart';

/// Filled, separated choices instead of the older outlined segmented control.
/// Keeps the same enabled, single/multiple-selection and empty-selection rules.
class MaterialChoiceBar<T> extends StatelessWidget {
  const MaterialChoiceBar({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.style,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;
  final ButtonStyle? style;

  void _select(T value) {
    final next = multiSelectionEnabled ? {...selected} : <T>{};
    if (selected.contains(value)) {
      if (multiSelectionEnabled) next.remove(value);
      if (next.isEmpty && !emptySelectionAllowed) return;
    } else {
      next.add(value);
    }
    onSelectionChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minimumWidth =
            64 * MediaQuery.textScalerOf(context).scale(14) / 14;
        final scroll =
            constraints.hasBoundedWidth &&
            constraints.maxWidth <
                minimumWidth * segments.length + 6 * (segments.length - 1);
        final expand = constraints.hasBoundedWidth && !scroll;
        final row = Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          spacing: 6,
          children: [
            for (final segment in segments)
              if (expand)
                Expanded(child: _choice(context, segment))
              else
                ConstrainedBox(
                  constraints: BoxConstraints(minWidth: minimumWidth),
                  child: _choice(context, segment),
                ),
          ],
        );
        return scroll
            ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: row,
            )
            : row;
      },
    );
  }

  Widget _choice(BuildContext context, ButtonSegment<T> segment) {
    if (Theme.of(context).platform == TargetPlatform.android) {
      return _AnimatedChoiceSegment<T>(
        segment: segment,
        selected: selected.contains(segment.value),
        enabled: segment.enabled && onSelectionChanged != null,
        showSelectedIcon: showSelectedIcon,
        style: style,
        onSelected: () => _select(segment.value),
      );
    }
    return _staticChoice(context, segment);
  }

  Widget _staticChoice(BuildContext context, ButtonSegment<T> segment) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isSelected = selected.contains(segment.value);
    final enabled = segment.enabled && onSelectionChanged != null;
    final states = <WidgetState>{
      if (isSelected) WidgetState.selected,
      if (!enabled) WidgetState.disabled,
    };
    final foreground =
        style?.foregroundColor?.resolve(states) ??
        (enabled
            ? (isSelected ? colors.onPrimary : colors.onSurfaceVariant)
            : colors.onSurface.withValues(alpha: .38));
    final background =
        style?.backgroundColor?.resolve(states) ??
        (!enabled
            ? colors.surfaceContainer
            : isSelected
            ? colors.primary
            : materialRaisedSurface(colors));
    final shape = style?.shape?.resolve(states) ?? const StadiumBorder();
    Widget content = Semantics(
      button: true,
      selected: isSelected,
      enabled: enabled,
      child: Material(
        color: background,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => _select(segment.value) : null,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding:
                  style?.padding?.resolve(states) ??
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: DefaultTextStyle(
                style: (style?.textStyle?.resolve(states) ??
                        theme.textTheme.labelLarge ??
                        const TextStyle())
                    .copyWith(color: foreground),
                textAlign: TextAlign.center,
                child: IconTheme(
                  data: IconThemeData(color: foreground, size: 18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isSelected && showSelectedIcon)
                        const Icon(Icons.check_rounded)
                      else if (segment.icon != null)
                        segment.icon!,
                      if ((isSelected && showSelectedIcon ||
                              segment.icon != null) &&
                          segment.label != null)
                        const SizedBox(width: 6),
                      if (segment.label != null)
                        Flexible(child: segment.label!),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (segment.tooltip != null) {
      content = Tooltip(message: segment.tooltip!, child: content);
    }
    return content;
  }
}

class _AnimatedChoiceSegment<T> extends StatefulWidget {
  const _AnimatedChoiceSegment({
    required this.segment,
    required this.selected,
    required this.enabled,
    required this.showSelectedIcon,
    required this.style,
    required this.onSelected,
  });

  final ButtonSegment<T> segment;
  final bool selected;
  final bool enabled;
  final bool showSelectedIcon;
  final ButtonStyle? style;
  final VoidCallback onSelected;

  @override
  State<_AnimatedChoiceSegment<T>> createState() =>
      _AnimatedChoiceSegmentState<T>();
}

class _AnimatedChoiceSegmentState<T> extends State<_AnimatedChoiceSegment<T>> {
  final _states = WidgetStatesController();
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_statesChanged);
  }

  void _statesChanged() {
    final pressed = _states.value.contains(WidgetState.pressed);
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  void didUpdateWidget(covariant _AnimatedChoiceSegment<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _pressed) {
      _pressed = false;
      _states.update(WidgetState.pressed, false);
    }
  }

  @override
  void dispose() {
    _states.removeListener(_statesChanged);
    _states.dispose();
    super.dispose();
  }

  Widget _icon() {
    if (widget.selected && widget.showSelectedIcon) {
      return const Icon(Icons.check_rounded, key: ValueKey('choice-check'));
    }
    final icon = widget.segment.icon;
    if (icon == null) {
      return const SizedBox.shrink(key: ValueKey('choice-empty'));
    }
    return KeyedSubtree(key: ValueKey<Object>(icon), child: icon);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final selectedTarget = widget.enabled && widget.selected ? 1.0 : 0.0;
    final pressedTarget = widget.enabled && _pressed ? 1.0 : 0.0;
    final baseStates = <WidgetState>{if (!widget.enabled) WidgetState.disabled};
    final selectedStates = <WidgetState>{
      ...baseStates,
      if (selectedTarget == 1) WidgetState.selected,
    };
    final background =
        widget.style?.backgroundColor?.resolve(baseStates) ??
        (!widget.enabled
            ? colors.surfaceContainer
            : materialRaisedSurface(colors));
    final selectedBackground =
        widget.style?.backgroundColor?.resolve(selectedStates) ??
        (!widget.enabled ? colors.surfaceContainer : colors.primary);
    final foreground =
        widget.style?.foregroundColor?.resolve(baseStates) ??
        (!widget.enabled
            ? colors.onSurface.withValues(alpha: .38)
            : colors.onSurfaceVariant);
    final selectedForeground =
        widget.style?.foregroundColor?.resolve(selectedStates) ??
        (!widget.enabled
            ? colors.onSurface.withValues(alpha: .38)
            : colors.onPrimary);
    final customShape = widget.style?.shape?.resolve(selectedStates);
    final hasIconSlot = widget.showSelectedIcon || widget.segment.icon != null;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: selectedTarget, end: selectedTarget),
      duration:
          reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (context, selected, _) {
        final backgroundNow =
            Color.lerp(background, selectedBackground, selected)!;
        final foregroundNow =
            Color.lerp(foreground, selectedForeground, selected)!;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: pressedTarget),
          duration:
              reduceMotion
                  ? Duration.zero
                  : Duration(milliseconds: _pressed ? 100 : 180),
          curve: Curves.easeOutCubic,
          builder: (context, press, _) {
            final restingRadius = 12 + 12 * selected;
            final radius = restingRadius + (8 - restingRadius) * press;
            final shape =
                customShape ??
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                );
            Widget content = Semantics(
              button: true,
              selected: widget.selected,
              enabled: widget.enabled,
              child: Material(
                color: backgroundNow,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  statesController: _states,
                  onTap: widget.enabled ? widget.onSelected : null,
                  customBorder: shape,
                  overlayColor: WidgetStateProperty.resolveWith<Color?>((
                    states,
                  ) {
                    if (!widget.enabled) return Colors.transparent;
                    if (states.contains(WidgetState.pressed) ||
                        states.contains(WidgetState.focused)) {
                      return foregroundNow.withValues(alpha: .10);
                    }
                    if (states.contains(WidgetState.hovered)) {
                      return foregroundNow.withValues(alpha: .08);
                    }
                    return null;
                  }),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    child: Padding(
                      padding:
                          widget.style?.padding?.resolve(selectedStates) ??
                          const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                      child: DefaultTextStyle(
                        style: (widget.style?.textStyle?.resolve(
                                  selectedStates,
                                ) ??
                                theme.textTheme.labelLarge ??
                                const TextStyle())
                            .copyWith(color: foregroundNow),
                        textAlign: TextAlign.center,
                        child: IconTheme(
                          data: IconThemeData(color: foregroundNow, size: 18),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (hasIconSlot)
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: AnimatedSwitcher(
                                    duration:
                                        reduceMotion
                                            ? Duration.zero
                                            : const Duration(milliseconds: 180),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeOutCubic,
                                    transitionBuilder:
                                        (child, animation) => FadeTransition(
                                          opacity: animation,
                                          child: ScaleTransition(
                                            scale: Tween<double>(
                                              begin: .82,
                                              end: 1,
                                            ).animate(animation),
                                            child: child,
                                          ),
                                        ),
                                    child: _icon(),
                                  ),
                                ),
                              if (hasIconSlot && widget.segment.label != null)
                                const SizedBox(width: 6),
                              if (widget.segment.label != null)
                                Flexible(child: widget.segment.label!),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (widget.segment.tooltip != null) {
              content = Tooltip(
                message: widget.segment.tooltip!,
                child: content,
              );
            }
            return content;
          },
        );
      },
    );
  }
}
