import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef AppleReaderChange =
    Future<Map<String, Object?>> Function(Map<Object?, Object?> event);

/// One native form, not a platform view for every slider. The invisible Flutter
/// route owns modality so reader gestures/volume keys pause while UIKit is up.
class AppleReaderPanel {
  static const channel = MethodChannel('litetale/reader_panel');
  static int _nextId = 0;
  static final _routes = <int, _AppleReaderRoute>{};
  static Future<bool>? _support;
  static bool _listening = false;

  static Future<bool> get available {
    if (kIsWeb || !Platform.isIOS) return SynchronousFuture(false);
    return _support ??= channel
        .invokeMethod<bool>('supported')
        .then((v) => v == true, onError: (Object _) => false);
  }

  static Future<Map<Object?, Object?>?> show(
    BuildContext context, {
    required Map<String, Object?> Function() configuration,
    AppleReaderChange? onChange,
  }) {
    if (!_listening) {
      _listening = true;
      channel.setMethodCallHandler((call) async {
        final args = call.arguments;
        if (args is! Map) return null;
        final route = _routes[args['session']];
        if (route == null || !route.isActive) return null;
        if (call.method == 'change') {
          return route.onChange?.call(Map<Object?, Object?>.from(args));
        }
        if (call.method == 'dismissed') {
          route.finish(
            args['selection'] is Map
                ? Map<Object?, Object?>.from(args['selection'] as Map)
                : null,
          );
        }
        return null;
      });
    }
    final route = _AppleReaderRoute(++_nextId, configuration, onChange);
    _routes[route.id] = route;
    return Navigator.of(context).push(route);
  }
}

class _AppleReaderRoute extends PopupRoute<Map<Object?, Object?>> {
  _AppleReaderRoute(this.id, this.configuration, this.onChange);
  final int id;
  final Map<String, Object?> Function() configuration;
  final AppleReaderChange? onChange;
  bool _finished = false;
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => '阅读面板';
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _AppleReaderRouteHost(route: this);

  void finish(Map<Object?, Object?>? value) {
    if (_finished || !isActive) return;
    _finished = true;
    // Never pop a different route if navigation changed during dismissal.
    if (isCurrent) {
      navigator?.pop(value);
    } else {
      navigator?.removeRoute(this);
    }
  }

  @override
  void dispose() {
    AppleReaderPanel._routes.remove(id);
    unawaited(
      AppleReaderPanel.channel
          .invokeMethod<void>('dismiss', {'session': id})
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}

class _AppleReaderRouteHost extends StatefulWidget {
  const _AppleReaderRouteHost({required this.route});
  final _AppleReaderRoute route;
  @override
  State<_AppleReaderRouteHost> createState() => _AppleReaderRouteHostState();
}

class _AppleReaderRouteHostState extends State<_AppleReaderRouteHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.route.isActive) return;
      try {
        await AppleReaderPanel.channel.invokeMethod<void>('present', {
          'session': widget.route.id,
          'configuration': widget.route.configuration(),
        });
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('无法打开阅读面板：$error')));
        widget.route.finish(null);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      const AbsorbPointer(child: SizedBox.expand());
}

/// Also used by “我的 → 显示 → 阅读显示”; the same native form has a single
/// clipping/scrolling owner on this page and in the modal reader sheet.
class AppleReaderSettingsView extends StatefulWidget {
  const AppleReaderSettingsView({
    super.key,
    required this.configuration,
    required this.onChange,
  });
  final Map<String, Object?> Function() configuration;
  final AppleReaderChange onChange;
  @override
  State<AppleReaderSettingsView> createState() =>
      _AppleReaderSettingsViewState();
}

class _AppleReaderSettingsViewState extends State<AppleReaderSettingsView> {
  MethodChannel? _channel;
  @override
  void didUpdateWidget(covariant AppleReaderSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(
      _channel
          ?.invokeMethod<void>('update', widget.configuration())
          .catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.of(context)?.isCurrent == false)
      return const SizedBox.shrink();
    return UiKitView(
      viewType: 'litetale/reader_settings',
      creationParams: widget.configuration(),
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        _channel?.setMethodCallHandler(null);
        final channel = MethodChannel('litetale/reader_settings/$id');
        _channel = channel;
        channel.setMethodCallHandler((call) async {
          if (!mounted || ModalRoute.of(context)?.isCurrent == false)
            return null;
          if (call.method != 'change' || call.arguments is! Map) return null;
          return widget.onChange(
            Map<Object?, Object?>.from(call.arguments as Map),
          );
        });
      },
    );
  }
}
