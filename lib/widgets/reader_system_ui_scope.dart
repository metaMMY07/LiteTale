import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wild/widgets/reading_progress_scope.dart';

/// The route owns immersive mode, so changing chapters or repaginating does
/// not briefly restore the status bar and invalidate the new page bounds.
class ReaderSystemUiScope extends StatefulWidget {
  const ReaderSystemUiScope({super.key, required this.child});
  final Widget child;

  static Future<void>? layoutReadyOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ReaderLayoutReady>()?.ready;

  @override
  State<ReaderSystemUiScope> createState() => _ReaderSystemUiScopeState();
}

class _ReaderSystemUiScopeState extends State<ReaderSystemUiScope>
    with WidgetsBindingObserver {
  late final Future<void> _ready;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ready = _enter();
  }

  Future<void> _enter() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Cache hits can otherwise measure the previous route's status-bar insets
    // before the platform has applied fullscreen, then immediately reflow.
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReaderLayoutReady(
    ready: _ready,
    child: ReadingProgressScope(child: widget.child),
  );
}

class _ReaderLayoutReady extends InheritedWidget {
  const _ReaderLayoutReady({required this.ready, required super.child});
  final Future<void> ready;
  @override
  bool updateShouldNotify(_ReaderLayoutReady oldWidget) =>
      ready != oldWidget.ready;
}
