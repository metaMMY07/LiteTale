import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wild/theme/ios_page_arrival.dart';

bool get usesAppleGlass => defaultTargetPlatform == TargetPlatform.iOS;

class AppleGlassCard extends StatelessWidget {
  const AppleGlassCard({
    super.key,
    this.child,
    this.color,
    this.margin,
    this.clipBehavior = Clip.none,
    this.shape,
    this.elevation,
  }) : filled = false;
  const AppleGlassCard.filled({
    super.key,
    this.child,
    this.color,
    this.margin,
    this.clipBehavior = Clip.none,
    this.shape,
    this.elevation,
  }) : filled = true;
  final Widget? child;
  final Color? color;
  final EdgeInsetsGeometry? margin;
  final Clip clipBehavior;
  final ShapeBorder? shape;
  final double? elevation;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return filled
          ? Card.filled(
            color: color,
            margin: margin,
            shape: shape,
            elevation: elevation,
            clipBehavior: clipBehavior,
            child: child,
          )
          : Card(
            color: color,
            margin: margin,
            shape: shape,
            elevation: elevation,
            clipBehavior: clipBehavior,
            child: child,
          );
    }
    return Padding(
      padding: margin ?? const EdgeInsets.all(4),
      child: AppleGlassSurface(
        tint: color,
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

class AppleGlassSurface extends StatelessWidget {
  const AppleGlassSurface({
    super.key,
    required this.child,
    this.tint,
    this.capsule = false,
  });
  final Widget child;
  final Color? tint;
  final bool capsule;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) return child;
    final surface = Theme.of(context).colorScheme.surface;
    final content = Stack(
      children: [
        Positioned.fill(
          child: _AppleChrome(
            parameters: {
              'kind': 'surface',
              if (capsule) 'capsule': true,
              if (tint != null) 'tint': tint!.toARGB32(),
              'dark': Theme.of(context).brightness == Brightness.dark,
            },
            onAction: (_, _) {},
            attachmentFallback: ColoredBox(
              color: Color.alphaBlend(
                tint ?? Colors.transparent,
                surface,
              ).withValues(alpha: .86),
            ),
            fallback: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: ColoredBox(color: surface.withValues(alpha: .64)),
            ),
          ),
        ),
        child,
      ],
    );
    return capsule
        ? ClipPath(
          clipper: const ShapeBorderClipper(shape: StadiumBorder()),
          child: content,
        )
        : ClipRRect(borderRadius: BorderRadius.circular(20), child: content);
  }
}

class AppleGlassChoiceBar extends StatelessWidget {
  const AppleGlassChoiceBar({
    super.key,
    required this.labels,
    required this.index,
    required this.onSelect,
    this.enabled,
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onSelect;
  final List<bool>? enabled;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: _AppleChrome(
      parameters: {
        'kind': 'segments',
        'labels': labels,
        'accent': Theme.of(context).colorScheme.primary.toARGB32(),
        'index': index,
        if (enabled != null) 'enabled': enabled!,
        'dark': Theme.of(context).brightness == Brightness.dark,
      },
      onAction: (a, v) {
        if (a == 'select') onSelect(v as int);
      },
      attachmentFallback: _GlassSegmentsPreview(labels: labels, index: index),
      fallback:
          labels.length < 2
              ? Center(child: Text(labels.isEmpty ? '' : labels.first))
              : CupertinoSegmentedControl<int>(
                groupValue: index,
                children: {
                  for (var i = 0; i < labels.length; i++) i: Text(labels[i]),
                },
                onValueChanged: (v) {
                  onSelect(v);
                },
              ),
    ),
  );
}

/// Native selectors that remain readable when there are many bookcase/sort tabs.
class AppleGlassFilterBar extends StatelessWidget {
  const AppleGlassFilterBar({
    super.key,
    required this.labels,
    required this.index,
    required this.onSelect,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onSelect;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          var widestLabel = 0.0;
          for (final label in labels) {
            final painter = TextPainter(
              text: TextSpan(text: label, style: const TextStyle(fontSize: 17)),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            if (painter.width > widestLabel) widestLabel = painter.width;
            painter.dispose();
          }
          final desiredWidth = (widestLabel + 32) * labels.length + 24;
          final width =
              desiredWidth < constraints.maxWidth
                  ? constraints.maxWidth
                  : desiredWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: AppleGlassChoiceBar(
                labels: labels,
                index: index.clamp(0, labels.length - 1),
                onSelect: onSelect,
              ),
            ),
          );
        },
      ),
    );
  }
}

class AppleGlassMenu extends StatelessWidget {
  const AppleGlassMenu({
    super.key,
    required this.label,
    required this.items,
    required this.onSelect,
    this.selected,
    this.width = 98,
    this.symbol = 'line.3.horizontal.decrease',
  });
  final String label;
  final List<Map<String, String>> items;
  final String? selected;
  final double width;
  final String symbol;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 44,
    child: _AppleChrome(
      parameters: {
        'kind': 'menu',
        'accent': Theme.of(context).colorScheme.primary.toARGB32(),
        'label': label,
        'symbol': symbol,
        'items': items,
        'selected': selected ?? '',
        'dark': Theme.of(context).brightness == Brightness.dark,
      },
      onAction: (a, v) {
        if (a == 'select') onSelect(v as String);
      },
      attachmentFallback: _GlassButtonPreview(
        label: label,
        icon: switch (symbol) {
          'ellipsis' => CupertinoIcons.ellipsis,
          _ => CupertinoIcons.line_horizontal_3_decrease,
        },
      ),
      fallback: PopupMenuButton<String>(
        tooltip: label,
        onSelected: onSelect,
        itemBuilder:
            (_) => [
              for (final item in items)
                PopupMenuItem(
                  value: item['value'],
                  child: Text(item['label']!),
                ),
            ],
        child: Center(child: Text(label)),
      ),
    ),
  );
}

/// UIKit owns the material, selection animation, SF Symbols and accessibility.
class AppleGlassBottomBar extends StatelessWidget {
  const AppleGlassBottomBar({
    super.key,
    required this.index,
    required this.onSelect,
  });
  final int index;
  final ValueChanged<int> onSelect;
  static const _labels = ['发现', '书架', '历史', '我的'];
  static const _icons = [
    CupertinoIcons.compass,
    CupertinoIcons.book,
    CupertinoIcons.clock,
    CupertinoIcons.person_crop_circle,
  ];
  static const _selectedIcons = [
    CupertinoIcons.compass_fill,
    CupertinoIcons.book_fill,
    CupertinoIcons.clock_fill,
    CupertinoIcons.person_crop_circle_fill,
  ];

  static double heightFor(MediaQueryData media) =>
      76 + media.viewPadding.bottom;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: heightFor(MediaQuery.of(context)),
    child: _AppleChrome(
      parameters: {
        'kind': 'tabs',
        'index': index,
        'dark': Theme.of(context).brightness == Brightness.dark,
        'accent': Theme.of(context).colorScheme.primary.toARGB32(),
      },
      onAction: (action, value) {
        if (action == 'select') onSelect(value as int);
      },
      attachmentFallback: _DockPreview(index: index),
      fallback: CupertinoTabBar(
        currentIndex: index,
        onTap: onSelect,
        items: [
          for (var i = 0; i < _labels.length; i++)
            BottomNavigationBarItem(icon: Icon(_icons[i]), label: _labels[i]),
        ],
      ),
    ),
  );
}

class AppleGlassToolbar extends StatelessWidget {
  const AppleGlassToolbar({
    super.key,
    required this.source,
    required this.onSource,
    required this.onSearch,
    required this.onTheme,
  });
  final String source;
  final VoidCallback onSource, onSearch, onTheme;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: _AppleChrome(
      parameters: {
        'kind': 'toolbar',
        'source': source,
        'dark': Theme.of(context).brightness == Brightness.dark,
        'accent': Theme.of(context).colorScheme.primary.toARGB32(),
      },
      onAction: (action, _) {
        switch (action) {
          case 'source':
            onSource();
          case 'search':
            onSearch();
          case 'theme':
            onTheme();
        }
      },
      attachmentFallback: _ToolbarPreview(source: source),
      fallback: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('ios-source-switch'),
            onPressed: onSource,
            icon: const Icon(CupertinoIcons.book),
            label: Text(source),
          ),
          const Spacer(),
          const Text('发现', style: TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            onPressed: onTheme,
            tooltip: '切换深浅色模式',
            icon: const Icon(CupertinoIcons.moon),
          ),
          IconButton(
            onPressed: onSearch,
            tooltip: '搜索',
            icon: const Icon(CupertinoIcons.search),
          ),
        ],
      ),
    ),
  );
}

// Simple paint while UIKit attaches, with matching bounds and readable labels.
class _GlassButtonPreview extends StatelessWidget {
  const _GlassButtonPreview({required this.icon, this.label = ''});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: _previewDecoration(colors),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: label.isEmpty ? 0 : 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: label.isEmpty ? 21 : 16, color: colors.onSurface),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.onSurface, fontSize: 15),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GlassSegmentsPreview extends StatelessWidget {
  const _GlassSegmentsPreview({required this.labels, required this.index});

  final List<String> labels;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.onSurface.withValues(alpha: .09),
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: i == index ? colors.surface : null,
                      shape: const StadiumBorder(),
                    ),
                    child: Center(
                      child: Text(
                        labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

ShapeDecoration _previewDecoration(ColorScheme colors) => ShapeDecoration(
  color: colors.surface.withValues(alpha: .9),
  shape: StadiumBorder(
    side: BorderSide(color: colors.outlineVariant.withValues(alpha: .16)),
  ),
);

class _DockPreview extends StatelessWidget {
  const _DockPreview({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewPaddingOf(context).bottom + 4,
        ),
        child: SizedBox(
          height: 60,
          child: DecoratedBox(
            decoration: _previewDecoration(colors),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  for (var i = 0; i < AppleGlassBottomBar._labels.length; i++)
                    Expanded(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: i == index ? colors.primaryContainer : null,
                          shape: const StadiumBorder(),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              i == index
                                  ? AppleGlassBottomBar._selectedIcons[i]
                                  : AppleGlassBottomBar._icons[i],
                              size: 23,
                              color:
                                  i == index
                                      ? colors.primary
                                      : colors.onSurface,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              AppleGlassBottomBar._labels[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textScaler: MediaQuery.textScalerOf(
                                context,
                              ).clamp(maxScaleFactor: 1.4),
                              style: TextStyle(
                                fontSize: 10,
                                color:
                                    i == index
                                        ? colors.primary
                                        : colors.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarPreview extends StatelessWidget {
  const _ToolbarPreview({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final leadingWidth = (width * .34).clamp(0.0, 136.0);
      final titleInset = (leadingWidth + 16).clamp(112.0, double.infinity);
      return Stack(
        children: [
          Positioned(
            left: 8,
            top: 6,
            height: 44,
            width: leadingWidth,
            child: _GlassButtonPreview(
              icon: CupertinoIcons.book,
              label: source,
            ),
          ),
          if (width > titleInset * 2)
            Positioned(
              left: titleInset,
              right: titleInset,
              top: 6,
              height: 44,
              child: Center(
                child: Text(
                  '发现',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          Positioned(
            right: 60,
            top: 6,
            height: 44,
            width: 44,
            child: _GlassButtonPreview(
              icon:
                  Theme.of(context).brightness == Brightness.dark
                      ? CupertinoIcons.sun_max
                      : CupertinoIcons.moon,
            ),
          ),
          const Positioned(
            right: 8,
            top: 6,
            height: 44,
            width: 44,
            child: _GlassButtonPreview(icon: CupertinoIcons.search),
          ),
        ],
      );
    },
  );
}

class AppleGlassSegments extends StatelessWidget {
  const AppleGlassSegments({
    super.key,
    required this.index,
    required this.lastLabel,
    this.thirdLabel = '排行',
    required this.onSelect,
  });
  final int index;
  final String lastLabel;
  final String thirdLabel;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: _AppleChrome(
      parameters: {
        'kind': 'segments',
        'index': index,
        'lastLabel': lastLabel,
        'labels': ['推荐', '分类', thirdLabel, lastLabel],
        'dark': Theme.of(context).brightness == Brightness.dark,
        'accent': Theme.of(context).colorScheme.primary.toARGB32(),
      },
      onAction: (action, value) {
        if (action == 'select') onSelect(value as int);
      },
      attachmentFallback: _GlassSegmentsPreview(
        labels: ['推荐', '分类', thirdLabel, lastLabel],
        index: index,
      ),
      fallback: CupertinoSlidingSegmentedControl<int>(
        groupValue: index,
        children: {
          0: const Text('推荐'),
          1: const Text('分类'),
          2: Text(thirdLabel),
          3: Text(lastLabel),
        },
        onValueChanged: (value) {
          if (value != null) onSelect(value);
        },
      ),
    ),
  );
}

/// Uses the system control, including iOS 26's glass thumb and its physics.
/// Do not supply a custom thumb image/tint: that replaces the native material.
class AppleGlassSlider extends StatelessWidget {
  const AppleGlassSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
    this.onChangeCancel,
    this.activeColor,
    this.interactionRevision,
  });
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final VoidCallback? onChangeCancel;
  final Color? activeColor;
  final Object? interactionRevision;

  double _value(Object? raw) {
    var v = (raw as num).toDouble().clamp(min, max);
    if (divisions != null && divisions! > 0) {
      final step = (max - min) / divisions!;
      v = min + ((v - min) / step).round() * step;
    }
    return v.clamp(min, max);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: _AppleChrome(
      parameters: {
        'kind': 'slider',
        'min': min,
        'max': max,
        'value': value.clamp(min, max),
        'enabled': onChanged != null,
        'revision': Object.hash(min, max, interactionRevision),
        'accent':
            (activeColor ?? Theme.of(context).colorScheme.primary).toARGB32(),
        'dark': Theme.of(context).brightness == Brightness.dark,
      },
      onAction: (action, raw) {
        if (action == 'cancel') {
          onChangeCancel?.call();
          return;
        }
        if (onChanged == null || raw is! num || !raw.toDouble().isFinite) {
          return;
        }
        final v = _value(raw);
        switch (action) {
          case 'start':
            onChangeStart?.call(v);
          case 'change':
            onChanged?.call(v);
          case 'end':
            onChangeEnd?.call(v);
        }
      },
      attachmentFallback: _GlassSliderPreview(
        fraction:
            max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0) : 0.0,
        activeColor: activeColor,
      ),
      fallback: CupertinoSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
        activeColor: activeColor ?? Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _GlassSliderPreview extends StatelessWidget {
  const _GlassSliderPreview({required this.fraction, this.activeColor});

  final double fraction;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: SizedBox(
              width: double.infinity,
              height: 5,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: colors.onSurface.withValues(alpha: .15),
                  shape: const StadiumBorder(),
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: fraction,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: activeColor ?? colors.primary,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional(2 * fraction - 1, 0),
            child: const SizedBox(
              width: 32,
              height: 20,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: Colors.white,
                  shape: StadiumBorder(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppleChrome extends StatefulWidget {
  const _AppleChrome({
    required this.parameters,
    required this.onAction,
    required this.fallback,
    required this.attachmentFallback,
  });
  final Map<String, Object> parameters;
  final void Function(String action, Object? value) onAction;
  final Widget fallback;
  final Widget attachmentFallback;
  @override
  State<_AppleChrome> createState() => _AppleChromeState();
}

class _AppleChromeState extends State<_AppleChrome> {
  MethodChannel? _channel;
  ModalRoute<Object?>? _route;
  UiKitView? _nativeView;
  bool _nativeReady = false;
  bool _acceptActions = false;

  bool get _isSurface => widget.parameters['kind'] == 'surface';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _created(int id) {
    if (!mounted) return;
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel('litetale/apple_glass/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted || !_acceptActions || _route?.isCurrent == false) return;
      if (call.method == 'action') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        if (widget.parameters['kind'] == 'slider' &&
            args['revision'] != widget.parameters['revision']) {
          return;
        }
        widget.onAction(args['action'] as String, args['value']);
      }
    });
    // UIKit creation is asynchronous. Sync only when the Flutter values
    // changed since creation (including a selection made during attachment).
    if (!_sameParameter(_nativeView?.creationParams, widget.parameters)) {
      _update();
    }
    setState(() => _nativeReady = true);
  }

  @override
  void didUpdateWidget(covariant _AppleChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_channel != null &&
        !_sameParameter(widget.parameters, oldWidget.parameters)) {
      _update();
    }
  }

  // Choice labels and menu items are lists rebuilt by their parents. Comparing
  // only the outer map sends redundant UIKit configuration/layout work.
  static bool _sameParameter(Object? a, Object? b) {
    if (identical(a, b) || a == b) return true;
    if (a is List && b is List && a.length == b.length) {
      for (var i = 0; i < a.length; i++) {
        if (!_sameParameter(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map && a.length == b.length) {
      return a.entries.every(
        (e) => b.containsKey(e.key) && _sameParameter(e.value, b[e.key]),
      );
    }
    return false;
  }

  Future<void> _update() async {
    try {
      await _channel?.invokeMethod<void>('update', widget.parameters);
    } on MissingPluginException {
      // A pushed route may have already disposed its platform view.
    } on PlatformException {
      // The next onPlatformViewCreated receives the current full configuration.
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _route?.isCurrent != false;
    final onstage = TickerMode.of(context) && _route?.offstage != true;
    final interactive =
        current && onstage && IosPageArrival.chromeAtRestOf(context);
    if (kIsWeb || !Platform.isIOS) {
      return Offstage(
        offstage: !onstage,
        child: IgnorePointer(
          ignoring: !interactive,
          child: ExcludeFocus(excluding: !interactive, child: widget.fallback),
        ),
      );
    }
    // Start attachment in the destination's first layout. Once attached, a
    // live glass view follows its page even while an adjacent page slides.
    // Only the Navigator's fully covered routes and inactive tabs are parked.
    if (_nativeView == null && onstage) {
      _nativeView = _createView();
    }
    _acceptActions = interactive && _nativeReady;
    return Offstage(
      offstage: !onstage,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_nativeReady)
            Positioned.fill(
              key: const ValueKey('glass-preview'),
              child: IgnorePointer(
                child: ExcludeFocus(
                  child: ExcludeSemantics(child: widget.attachmentFallback),
                ),
              ),
            ),
          if (_nativeView case final view?)
            Positioned.fill(
              key: const ValueKey('glass-native'),
              child: IgnorePointer(
                ignoring: !_acceptActions,
                child: ExcludeSemantics(
                  excluding: !_acceptActions,
                  child: ExcludeFocus(excluding: !_acceptActions, child: view),
                ),
              ),
            ),
        ],
      ),
    );
  }

  UiKitView _createView() => UiKitView(
    viewType: 'litetale/apple_glass',
    creationParams: widget.parameters,
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: _created,
    // A slider owns horizontal drags and taps, but the surrounding settings
    // sheet must retain vertical scrolling and its expand/collapse gesture.
    gestureRecognizers:
        widget.parameters['kind'] == 'slider'
            ? <Factory<OneSequenceGestureRecognizer>>{
              Factory<HorizontalDragGestureRecognizer>(
                () => HorizontalDragGestureRecognizer(),
              ),
              Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
            }
            : const <Factory<OneSequenceGestureRecognizer>>{},
    // Decorative glass never intercepts its Flutter button or card content.
    hitTestBehavior:
        _isSurface
            ? PlatformViewHitTestBehavior.transparent
            : PlatformViewHitTestBehavior.opaque,
  );
}
