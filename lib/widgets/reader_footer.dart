import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wild/services/reader_viewport_layout.dart';
import 'package:wild/theme/app_fonts.dart';

/// Outside the moving/rasterized papers: a minute tick never rebuilds text,
/// invalidates page images or re-fetches a chapter.
class ReaderFooter extends StatefulWidget {
  const ReaderFooter({
    super.key,
    required this.layout,
    required this.pageLabel,
    required this.color,
    this.fontFamily = appFontFamily,
    this.now,
  });

  final ReaderViewportLayout layout;
  final String pageLabel;
  final Color color;
  final String fontFamily;
  final DateTime Function()? now;

  @override
  State<ReaderFooter> createState() => _ReaderFooterState();
}

class _ReaderFooterState extends State<ReaderFooter>
    with WidgetsBindingObserver {
  Timer? _timer;
  late DateTime _time;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  void _refresh() {
    _timer?.cancel();
    _time = (widget.now ?? DateTime.now)();
    // Wake at the next wall-clock minute, not 60 seconds after opening a book.
    final next = DateTime(
      _time.year,
      _time.month,
      _time.day,
      _time.hour,
      _time.minute + 1,
    );
    _timer = Timer(next.difference(_time), () {
      if (mounted) setState(_refresh);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(_refresh);
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock =
        '${_time.hour.toString().padLeft(2, '0')}:'
        '${_time.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          widget.layout.insets.left,
          0,
          widget.layout.insets.right,
          widget.layout.footerBottom,
        ),
        child: SizedBox(
          height: widget.layout.footerHeight,
          child: DefaultTextStyle(
            style: TextStyle(
              color: widget.color.withValues(alpha: .60),
              fontFamily: widget.fontFamily,
              fontFamilyFallback: const [appFontFamily],
              fontSize: 11,
              height: 1.25,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: Row(
              textDirection: TextDirection.ltr,
              children: [
                Text(clock, key: const ValueKey('reader-clock')),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    widget.pageLabel,
                    key: const ValueKey('reader-page-number'),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
