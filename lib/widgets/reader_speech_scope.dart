import 'package:flutter/material.dart';
import 'package:wild/services/reader_listening_chapter.dart';
import 'package:wild/services/reader_speech.dart';

const readerMenuMotionDuration = Duration(milliseconds: 240);

/// The ordinary reader keeps its paper in place while both control bars exit.
class ReaderSpeechScope extends StatefulWidget {
  const ReaderSpeechScope({
    super.key,
    required this.chapter,
    required this.request,
    required this.child,
  });

  final ReaderListeningChapter? chapter;
  final ReaderListeningRequest Function(ReaderListeningChapter) request;
  final Widget child;

  static ({bool visible, VoidCallback? open}) actionOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_ReaderSpeechAction>();
    return (visible: scope != null, open: scope?.open);
  }

  static Animation<double>? exitOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ReaderSpeechAction>()?.exit;

  @override
  State<ReaderSpeechScope> createState() => _ReaderSpeechScopeState();
}

class _ReaderSpeechScopeState extends State<ReaderSpeechScope>
    with SingleTickerProviderStateMixin {
  late final _exit = AnimationController(
    vsync: this,
    duration: readerMenuMotionDuration,
  );
  late bool _canListen = _hasText(widget.chapter);
  bool _leaving = false;

  static bool _hasText(ReaderListeningChapter? chapter) =>
      chapter != null && !chapter.encoded && readerHasSpeech(chapter.text);

  @override
  void didUpdateWidget(covariant ReaderSpeechScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapter?.text != widget.chapter?.text ||
        oldWidget.chapter?.encoded != widget.chapter?.encoded) {
      _canListen = _hasText(widget.chapter);
    }
  }

  Future<void> _open() async {
    final chapter = widget.chapter;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (_leaving ||
        !_canListen ||
        chapter == null ||
        route?.isCurrent != true ||
        navigator.userGestureInProgress) {
      return;
    }
    final request = widget.request(chapter);
    setState(() => _leaving = true);
    try {
      if (MediaQuery.disableAnimationsOf(context)) {
        _exit.value = 1;
      } else {
        await _exit.forward().orCancel;
      }
      if (!mounted) return;
      if (route!.isCurrent &&
          !navigator.userGestureInProgress &&
          widget.chapter?.aid == chapter.aid &&
          widget.chapter?.cid == chapter.cid) {
        navigator.pop(request);
      } else {
        _exit.reset();
        setState(() => _leaving = false);
      }
    } on TickerCanceled {
      // The normal back gesture already removed this page.
    }
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!readerSpeechSupported ||
        ModalRoute.of(context) is! ModalRoute<ReaderListeningRequest>) {
      return widget.child;
    }
    return _ReaderSpeechAction(
      open: _canListen && !_leaving ? _open : null,
      exit: _leaving ? _exit : null,
      child: widget.child,
    );
  }
}

class _ReaderSpeechAction extends InheritedWidget {
  const _ReaderSpeechAction({
    required this.open,
    required this.exit,
    required super.child,
  });
  final VoidCallback? open;
  final Animation<double>? exit;

  @override
  bool updateShouldNotify(_ReaderSpeechAction oldWidget) =>
      open != oldWidget.open || exit != oldWidget.exit;
}
