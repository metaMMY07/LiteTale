import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:wild/services/reading_progress.dart';

/// Flush accepted positions when leaving the foreground or a reader route.
class ReadingProgressScope extends StatefulWidget {
  const ReadingProgressScope({super.key, required this.child});
  final Widget child;
  @override
  State<ReadingProgressScope> createState() => _ReadingProgressScopeState();
}

class _ReadingProgressScopeState extends State<ReadingProgressScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(ReadingProgressQueue.instance.flushBounded());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(ReadingProgressQueue.instance.flushBounded());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
