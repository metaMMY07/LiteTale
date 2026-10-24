import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/theme/ios_system_colors.dart';

enum _ButtonKind { filled, tonal, outlined, text, elevated }

/// Keeps Android controls intact; iOS uses Cupertino interaction over real glass.
class AppButton extends StatelessWidget {
  const AppButton.filled({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  }) : _kind = _ButtonKind.filled,
       icon = null;
  const AppButton.tonal({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  }) : _kind = _ButtonKind.tonal,
       icon = null;
  const AppButton.outlined({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  }) : _kind = _ButtonKind.outlined,
       icon = null;
  const AppButton.text({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  }) : _kind = _ButtonKind.text,
       icon = null;
  const AppButton.elevated({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  }) : _kind = _ButtonKind.elevated,
       icon = null;
  const AppButton.filledIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.icon,
    required Widget label,
  }) : _kind = _ButtonKind.filled,
       child = label;
  const AppButton.tonalIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.icon,
    required Widget label,
  }) : _kind = _ButtonKind.tonal,
       child = label;
  const AppButton.outlinedIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.icon,
    required Widget label,
  }) : _kind = _ButtonKind.outlined,
       child = label;
  const AppButton.textIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.icon,
    required Widget label,
  }) : _kind = _ButtonKind.text,
       child = label;
  const AppButton.elevatedIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.icon,
    required Widget label,
  }) : _kind = _ButtonKind.elevated,
       child = label;

  final VoidCallback? onPressed, onLongPress;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Widget child;
  final Widget? icon;
  final _ButtonKind _kind;

  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      if (icon != null) {
        return switch (_kind) {
          _ButtonKind.filled => FilledButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            icon: icon,
            label: child,
          ),
          _ButtonKind.tonal => FilledButton.tonalIcon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            icon: icon,
            label: child,
          ),
          _ButtonKind.outlined => OutlinedButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            icon: icon,
            label: child,
          ),
          _ButtonKind.text => TextButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            icon: icon,
            label: child,
          ),
          _ButtonKind.elevated => ElevatedButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            icon: icon,
            label: child,
          ),
        };
      }
      return switch (_kind) {
        _ButtonKind.filled => FilledButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          child: child,
        ),
        _ButtonKind.tonal => FilledButton.tonal(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          child: child,
        ),
        _ButtonKind.outlined => OutlinedButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          child: child,
        ),
        _ButtonKind.text => TextButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          child: child,
        ),
        _ButtonKind.elevated => ElevatedButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          child: child,
        ),
      };
    }
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    final colors = Theme.of(context).colorScheme;
    final color = style?.foregroundColor?.resolve(states) ?? colors.primary;
    if (context.findAncestorWidgetOfExactType<CupertinoAlertDialog>() != null) {
      return CupertinoDialogAction(onPressed: onPressed, child: child);
    }
    Widget content = child;
    if (icon != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [icon!, const SizedBox(width: 8), Flexible(child: child)],
      );
    }
    final button = CupertinoButton(
      padding:
          style?.padding?.resolve(states) ??
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: onPressed == null ? colors.onSurfaceVariant : color,
          fontSize: 17,
        ),
        child: IconTheme.merge(
          data: IconThemeData(color: color, size: 20),
          child: content,
        ),
      ),
    );
    if (_kind == _ButtonKind.text) return button;
    return AppleGlassSurface(
      tint:
          _kind == _ButtonKind.filled || _kind == _ButtonKind.elevated
              ? colors.primary.withValues(alpha: .12)
              : null,
      child: button,
    );
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.color,
    this.iconSize,
    this.padding,
    this.constraints,
    this.style,
    this.alignment = Alignment.center,
    this.visualDensity,
  });
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double? iconSize;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;
  final ButtonStyle? style;
  final AlignmentGeometry alignment;
  final VisualDensity? visualDensity;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return IconButton(
        icon: icon,
        onPressed: onPressed,
        tooltip: tooltip,
        color: color,
        iconSize: iconSize,
        padding: padding,
        constraints: constraints,
        style: style,
        alignment: alignment,
        visualDensity: visualDensity,
      );
    }
    final button = CupertinoButton(
      padding: padding ?? const EdgeInsets.all(8),
      onPressed: onPressed,
      child: IconTheme.merge(
        data: IconThemeData(
          size: iconSize ?? 24,
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
        child: icon,
      ),
    );
    return tooltip == null ? button : Semantics(label: tooltip, child: button);
  }
}

class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: IosSystemColors.color(
              'ios-green',
              Theme.of(context).brightness,
            ),
          )
          : Switch(
            value: value,
            onChanged: onChanged,
            activeColor: activeColor,
          );
}

class AppSwitchListTile extends StatelessWidget {
  const AppSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.dense,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title, subtitle, secondary;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? ListTile(
            leading: secondary,
            title: title,
            subtitle: subtitle,
            contentPadding: contentPadding,
            dense: dense,
            trailing: AppSwitch(value: value, onChanged: onChanged),
            onTap: onChanged == null ? null : () => onChanged!(!value),
          )
          : SwitchListTile(
            value: value,
            onChanged: onChanged,
            title: title,
            subtitle: subtitle,
            secondary: secondary,
            contentPadding: contentPadding,
            dense: dense,
          );
}

class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeStart,
    this.onChangeEnd,
    this.activeColor,
    this.inactiveColor,
  });
  final double value, min, max;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final Color? activeColor, inactiveColor;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? CupertinoSlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd,
            activeColor: activeColor ?? Theme.of(context).colorScheme.primary,
          )
          : Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
          );
}

String controlLabel(Widget? child) => switch (child) {
  Text() => child.data ?? child.textSpan?.toPlainText() ?? '',
  ListTile() => controlLabel(child.title),
  Row() => child.children
      .map(controlLabel)
      .where((s) => s.isNotEmpty)
      .join(' '),
  _ => '',
};

class AppSegmentedButton<T> extends StatelessWidget {
  const AppSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.style,
  });
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon, multiSelectionEnabled, emptySelectionAllowed;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return SegmentedButton<T>(
        segments: segments,
        selected: selected,
        onSelectionChanged: onSelectionChanged,
        showSelectedIcon: showSelectedIcon,
        multiSelectionEnabled: multiSelectionEnabled,
        emptySelectionAllowed: emptySelectionAllowed,
        style: style,
      );
    }
    return AppleGlassChoiceBar(
      labels: segments.map((s) => controlLabel(s.label)).toList(),
      index: segments.indexWhere((s) => selected.contains(s.value)),
      enabled:
          segments.map((s) => s.enabled && onSelectionChanged != null).toList(),
      onSelect: (index) {
        if (segments[index].enabled) {
          onSelectionChanged?.call({segments[index].value});
        }
      },
    );
  }
}

class AppCheckboxListTile extends StatelessWidget {
  const AppCheckboxListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.controlAffinity = ListTileControlAffinity.platform,
    this.contentPadding,
    this.dense,
  });
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget? title, subtitle;
  final ListTileControlAffinity controlAffinity;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return CheckboxListTile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        controlAffinity: controlAffinity,
        contentPadding: contentPadding,
        dense: dense,
      );
    }
    final check = CupertinoCheckbox(value: value, onChanged: onChanged);
    return ListTile(
      title: title,
      subtitle: subtitle,
      contentPadding: contentPadding,
      dense: dense,
      leading:
          controlAffinity == ListTileControlAffinity.leading ? check : null,
      trailing:
          controlAffinity == ListTileControlAffinity.leading ? null : check,
      onTap: onChanged == null ? null : () => onChanged!(!(value ?? false)),
    );
  }
}

class AppRadioListTile<T> extends StatelessWidget {
  const AppRadioListTile({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.contentPadding,
    this.dense,
  });
  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final Widget? title, subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? ListTile(
            title: title,
            subtitle: subtitle,
            dense: dense,
            contentPadding: contentPadding,
            trailing: CupertinoRadio<T>(
              value: value,
              groupValue: groupValue,
              onChanged: onChanged,
            ),
            onTap: onChanged == null ? null : () => onChanged!(value),
          )
          : RadioListTile<T>(
            value: value,
            groupValue: groupValue,
            onChanged: onChanged,
            title: title,
            subtitle: subtitle,
            dense: dense,
            contentPadding: contentPadding,
          );
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.enabled,
    this.style,
    this.readOnly = false,
    this.inputFormatters,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofillHints,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText, autofocus, readOnly, autocorrect, enableSuggestions;
  final bool? enabled;
  final Iterable<String>? autofillHints;
  final int? maxLines, minLines;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onEditingComplete;
  final TextStyle? style;
  final List<TextInputFormatter>? inputFormatters;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        obscureText: obscureText,
        autofocus: autofocus,
        maxLines: maxLines,
        minLines: minLines,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onEditingComplete: onEditingComplete,
        enabled: enabled,
        style: style,
        readOnly: readOnly,
        inputFormatters: inputFormatters,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        autofillHints: autofillHints,
      );
    }
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (decoration.labelText != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              decoration.labelText!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        CupertinoTextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          obscureText: obscureText,
          autofocus: autofocus,
          maxLines: maxLines,
          minLines: minLines,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          onEditingComplete: onEditingComplete,
          enabled: enabled ?? true,
          style: style ?? Theme.of(context).textTheme.bodyLarge,
          readOnly: readOnly,
          inputFormatters: inputFormatters,
          autocorrect: autocorrect,
          enableSuggestions: enableSuggestions,
          autofillHints: autofillHints,
          placeholder: decoration.hintText,
          prefix: decoration.prefixIcon,
          suffix: decoration.suffixIcon,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.outlineVariant),
          ),
        ),
        if (decoration.errorText != null)
          Text(decoration.errorText!, style: TextStyle(color: colors.error)),
      ],
    );
  }
}

class AppTextFormField extends StatelessWidget {
  const AppTextFormField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.validator,
    this.onSaved,
    this.onChanged,
    this.onFieldSubmitted,
    this.enabled,
    this.autovalidateMode,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofillHints,
  });
  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText, autofocus, autocorrect, enableSuggestions;
  final bool? enabled;
  final Iterable<String>? autofillHints;
  final int? maxLines;
  final FormFieldValidator<String>? validator;
  final FormFieldSetter<String>? onSaved;
  final ValueChanged<String>? onChanged, onFieldSubmitted;
  final AutovalidateMode? autovalidateMode;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return TextFormField(
        controller: controller,
        initialValue: initialValue,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        obscureText: obscureText,
        autofocus: autofocus,
        maxLines: maxLines,
        validator: validator,
        onSaved: onSaved,
        onChanged: onChanged,
        onFieldSubmitted: onFieldSubmitted,
        enabled: enabled,
        autovalidateMode: autovalidateMode ?? AutovalidateMode.disabled,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        autofillHints: autofillHints,
      );
    }
    final field = CupertinoTextFormFieldRow(
      controller: controller,
      initialValue: initialValue,
      focusNode: focusNode,
      placeholder: decoration.hintText ?? decoration.labelText,
      prefix: decoration.prefixIcon,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      autofocus: autofocus,
      maxLines: maxLines,
      validator: validator,
      onSaved: onSaved,
      onChanged: onChanged,
      onFieldSubmitted: onFieldSubmitted,
      enabled: enabled,
      autovalidateMode: autovalidateMode ?? AutovalidateMode.disabled,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      autofillHints: autofillHints,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
    if (decoration.suffixIcon == null) return field;
    return Row(children: [Expanded(child: field), decoration.suffixIcon!]);
  }
}

class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.icon,
    this.child,
    this.tooltip,
    this.enabled = true,
  });
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final Widget? icon, child;
  final String? tooltip;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return PopupMenuButton<T>(
        itemBuilder: itemBuilder,
        onSelected: onSelected,
        icon: icon,
        tooltip: tooltip,
        enabled: enabled,
        child: child,
      );
    }
    final entries = itemBuilder(context).whereType<PopupMenuItem<T>>().toList();
    return AppleGlassMenu(
      label: child == null ? '' : controlLabel(child),
      symbol: 'ellipsis',
      width: child == null ? 44 : 130,
      items: [
        for (var i = 0; i < entries.length; i++)
          {
            'label': controlLabel(entries[i].child),
            'value': '$i',
            if (!entries[i].enabled || !enabled) 'disabled': 'true',
          },
      ],
      onSelect: (value) {
        final entry = entries[int.parse(value)];
        if (!entry.enabled || !enabled) return;
        entry.onTap?.call();
        if (entry.value != null) onSelected?.call(entry.value as T);
      },
    );
  }
}

class AppDropdownButtonFormField<T> extends StatelessWidget {
  const AppDropdownButtonFormField({
    super.key,
    required this.items,
    this.value,
    this.onChanged,
    this.decoration = const InputDecoration(),
    this.isExpanded = false,
    this.validator,
    this.onSaved,
  });
  final List<DropdownMenuItem<T>>? items;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final bool isExpanded;
  final FormFieldValidator<T>? validator;
  final FormFieldSetter<T>? onSaved;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return DropdownButtonFormField<T>(
        items: items,
        value: value,
        onChanged: onChanged,
        decoration: decoration,
        isExpanded: isExpanded,
        validator: validator,
        onSaved: onSaved,
      );
    }
    final entries = items ?? [];
    return FormField<T>(
      key: ValueKey(value),
      initialValue: value,
      validator: validator,
      onSaved: onSaved,
      builder: (state) {
        final index = entries.indexWhere(
          (item) => item.value == (state.value ?? value),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (decoration.labelText != null)
              Text(
                decoration.labelText!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            AppleGlassMenu(
              label: index < 0 ? '请选择' : controlLabel(entries[index].child),
              width: 240,
              selected: '$index',
              items: [
                for (var i = 0; i < entries.length; i++)
                  {
                    'label': controlLabel(entries[i].child),
                    'value': '$i',
                    if (!entries[i].enabled || onChanged == null)
                      'disabled': 'true',
                  },
              ],
              onSelect: (selected) {
                final entry = entries[int.parse(selected)];
                if (!entry.enabled || onChanged == null) return;
                state.didChange(entry.value);
                onChanged!(entry.value);
              },
            ),
            if (state.errorText != null)
              Text(
                state.errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        );
      },
    );
  }
}

class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.avatar,
    this.backgroundColor,
    this.padding,
    this.labelStyle,
  });
  final Widget label;
  final TextStyle? labelStyle;
  final Widget? avatar;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? AppleGlassSurface(
            child: Padding(
              padding:
                  padding ??
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (avatar != null) ...[avatar!, const SizedBox(width: 6)],
                  DefaultTextStyle.merge(style: labelStyle, child: label),
                ],
              ),
            ),
          )
          : Chip(
            label: label,
            labelStyle: labelStyle,
            avatar: avatar,
            backgroundColor: backgroundColor,
            padding: padding,
          );
}

class AppCheckbox extends StatelessWidget {
  const AppCheckbox({super.key, required this.value, required this.onChanged});
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? CupertinoCheckbox(value: value, onChanged: onChanged)
          : Checkbox(value: value, onChanged: onChanged);
}

Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
  bool useSafeArea = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  BoxConstraints? constraints,
}) {
  if (!usesAppleGlass) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      backgroundColor: backgroundColor,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      showDragHandle: showDragHandle,
      constraints: constraints,
    );
  }
  return showCupertinoModalPopup<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: isDismissible,
    builder:
        (sheetContext) => AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints:
                  constraints ??
                  BoxConstraints(
                    maxHeight:
                        MediaQuery.sizeOf(sheetContext).height *
                        (isScrollControlled ? .92 : .6),
                  ),
              child: AppleGlassSurface(
                child: Material(
                  type: MaterialType.transparency,
                  child: SafeArea(top: false, child: builder(sheetContext)),
                ),
              ),
            ),
          ),
        ),
  );
}
