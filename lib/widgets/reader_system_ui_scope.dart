import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The route owns immersive mode, so changing chapters or repaginating does
/// not briefly restore the status bar and invalidate the new page bounds.
class ReaderSystemUiScope extends StatefulWidget {
  const ReaderSystemUiScope({super.key, required this.child});
  final Widget child;

  @override
  State<ReaderSystemUiScope> createState() => _ReaderSystemUiScopeState();
}

class _ReaderSystemUiScopeState extends State<ReaderSystemUiScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
  Widget build(BuildContext context) => widget.child;
}
