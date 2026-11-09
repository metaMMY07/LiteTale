import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wild/theme/ios_page_arrival.dart';
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
  Future<void>? _ready;
  bool _entered = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ready ??= _enter(IosPageArrival.pendingOf(context));
  }

  Future<void> _enter(Future<bool>? arrival) async {
    // iOS insets can invalidate both pages if the system bars change while the
    // reader is sliding in. Android retains its immediate immersive behavior.
    if (arrival != null && !await arrival) return;
    if (!mounted) return;
    _entered = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Cache hits can otherwise measure the previous route's status-bar insets
    // before the platform has applied fullscreen, then immediately reflow.
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_entered && state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_entered) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReaderLayoutReady(
    ready: _ready!,
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
