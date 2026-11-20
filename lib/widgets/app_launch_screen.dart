import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/reader_speech_scope.dart'
    show readerMenuMotionDuration;

/// The same approved book artwork used by the native launch screen and login.
class AppLaunchScreen extends StatelessWidget {
  const AppLaunchScreen({super.key, this.reveal});

  final Animation<double>? reveal;

  @override
  Widget build(BuildContext context) {
    final apple = defaultTargetPlatform == TargetPlatform.iOS;
    final brightness = MediaQuery.platformBrightnessOf(context);
    final background = IosSystemColors.color('background', brightness);
    final artwork = Image.asset(
      'lib/assets/app_brand.png',
      width: 104,
      height: 104,
      fit: BoxFit.contain,
      semanticLabel: 'LiteTale',
    );
    final mark = Center(
      child:
          apple
              ? ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: artwork,
              )
              : artwork,
    );
    final indicator = SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 48),
          child: AppLoadingIndicator(
            size: 24,
            color: apple ? IosSystemColors.color('ios-blue', brightness) : null,
          ),
        ),
      ),
    );
    if (reveal case final progress?) {
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SlideTransition(
                    position: progress.drive(_launchTopExit),
                    child: ColoredBox(color: background),
                  ),
                ),
                Expanded(
                  child: SlideTransition(
                    position: progress.drive(_launchBottomExit),
                    child: ColoredBox(color: background),
                  ),
                ),
              ],
            ),
            FadeTransition(opacity: ReverseAnimation(progress), child: mark),
            SlideTransition(
              position: progress.drive(_launchBottomExit),
              child: indicator,
            ),
          ],
        ),
      );
    }
    // Match the canvas and centred mark in LaunchScreen.storyboard.
    final content = Stack(fit: StackFit.expand, children: [mark, indicator]);
    return Scaffold(
      backgroundColor: apple ? background : null,
      body: apple ? content : SafeArea(child: content),
    );
  }
}

final _launchTopExit = Tween(begin: Offset.zero, end: const Offset(0, -1));
final _launchBottomExit = Tween(begin: Offset.zero, end: const Offset(0, 1));

/// Keeps the launch artwork in front of the home's first layout and UIKit
/// attachments. Only the cover animates once these frames have been submitted.
class IosStartupTransition extends StatefulWidget {
  const IosStartupTransition({
    super.key,
    required this.homeMounted,
    required this.child,
  });

  final bool homeMounted;
  final Widget child;

  /// Called when a native view starts attaching during the startup layout.
  static VoidCallback? waitForGlass(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_IosStartupScope>()?.trackGlass();

  @override
  State<IosStartupTransition> createState() => _IosStartupTransitionState();
}

class _IosStartupTransitionState extends State<IosStartupTransition>
    with SingleTickerProviderStateMixin {
  final _pending = <Object>{};
  late final _reveal = AnimationController(
    vsync: this,
    duration: readerMenuMotionDuration,
  )..addStatusListener(_onStatus);
  late final _position = _reveal.drive(
    CurveTween(curve: Curves.easeInOutCubic),
  );
  Timer? _deadline;
  bool _scheduled = false;
  bool _started = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    if (widget.homeMounted) _prepare();
  }

  @override
  void didUpdateWidget(covariant IosStartupTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.homeMounted && !oldWidget.homeMounted) _prepare();
  }

  void _prepare() {
    if (_started) return;
    _deadline ??= Timer(const Duration(milliseconds: 650), () {
      // A delayed or missing plugin reply must not trap the user at launch.
      _pending.clear();
      _maybeReveal();
    });
    _maybeReveal();
  }

  VoidCallback? _trackGlass() {
    if (_started) return null;
    final attachment = Object();
    _pending.add(attachment);
    return () {
      if (_pending.remove(attachment)) _maybeReveal();
    };
  }

  void _maybeReveal() {
    if (_started || _scheduled || !widget.homeMounted || _pending.isNotEmpty) {
      return;
    }
    _scheduled = true;
    unawaited(
      WidgetsBinding.instance.endOfFrame.then((_) {
        _scheduled = false;
        if (!mounted || _started || _pending.isNotEmpty) return;
        _started = true;
        _deadline?.cancel();
        if (MediaQuery.disableAnimationsOf(context)) {
          setState(() => _finished = true);
        } else {
          _reveal.forward();
        }
      }),
    );
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) setState(() => _finished = true);
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final covering = widget.homeMounted && !_finished;
    return Stack(
      fit: StackFit.expand,
      children: [
        _IosStartupScope(
          trackGlass: _trackGlass,
          child: IgnorePointer(
            ignoring: covering,
            child: ExcludeSemantics(excluding: covering, child: widget.child),
          ),
        ),
        if (covering) AppLaunchScreen(reveal: _position),
      ],
    );
  }
}

class _IosStartupScope extends InheritedWidget {
  const _IosStartupScope({required this.trackGlass, required super.child});

  final VoidCallback? Function() trackGlass;

  @override
  bool updateShouldNotify(_IosStartupScope oldWidget) => false;
}
