import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

bool get usesAppleGlass => defaultTargetPlatform == TargetPlatform.iOS;

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
    required this.onSelect,
  });
  final int index;
  final String lastLabel;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: _AppleChrome(
      parameters: {
        'kind': 'segments',
        'index': index,
        'lastLabel': lastLabel,
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
          2: const Text('排行'),
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
    if (ModalRoute.of(context)?.isCurrent == false) {
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
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    );
  }
}
