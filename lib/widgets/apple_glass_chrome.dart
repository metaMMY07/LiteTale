import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

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
  const AppleGlassSurface({super.key, required this.child, this.tint});
  final Widget child;
  final Color? tint;
  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          Positioned.fill(
            child: _AppleChrome(
              parameters: {
                'kind': 'surface',
                if (tint != null) 'tint': tint!.toARGB32(),
                'dark': Theme.of(context).brightness == Brightness.dark,
              },
              onAction: (_, _) {},
              fallback: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: ColoredBox(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: .64),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
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
/// The fallback is for desktop widget tests; an iPhone uses the native view.
class AppleGlassBottomBar extends StatelessWidget {
  const AppleGlassBottomBar({
    super.key,
    required this.index,
    required this.onSelect,
  });
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 76 + MediaQuery.viewPaddingOf(context).bottom,
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
      fallback: CupertinoTabBar(
        currentIndex: index,
        onTap: onSelect,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.compass),
            label: '发现',
          ),
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.book), label: '书架'),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.clock),
            label: '历史',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.person_crop_circle),
            label: '我的',
          ),
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

class _AppleChrome extends StatefulWidget {
  const _AppleChrome({
    required this.parameters,
    required this.onAction,
    required this.fallback,
  });
  final Map<String, Object> parameters;
  final void Function(String action, Object? value) onAction;
  final Widget fallback;
  @override
  State<_AppleChrome> createState() => _AppleChromeState();
}

class _AppleChromeState extends State<_AppleChrome> {
  MethodChannel? _channel;

  void _created(int id) {
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel('litetale/apple_glass/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      if (call.method == 'action') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        widget.onAction(args['action'] as String, args['value']);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _AppleChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(widget.parameters, oldWidget.parameters)) _update();
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
    // UIKit chrome must never float above a reader, pushed page or popup.
    if (widget.parameters['kind'] != 'surface' &&
        ModalRoute.of(context)?.isCurrent == false) {
      return const SizedBox.shrink();
    }
    if (kIsWeb || !Platform.isIOS) return widget.fallback;
    return UiKitView(
      viewType: 'litetale/apple_glass',
      creationParams: widget.parameters,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
      // The floating bar overlaps tappable book covers. Keep those recognizers
      // out of its gesture arena so a tab press reaches UIKit immediately.
      hitTestBehavior:
          widget.parameters['kind'] == 'surface'
              ? PlatformViewHitTestBehavior.transparent
              : PlatformViewHitTestBehavior.opaque,
    );
  }
}
