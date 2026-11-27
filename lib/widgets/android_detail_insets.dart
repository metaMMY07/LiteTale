import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The reader may hide the status bar while this page is still painted.
/// Reserve the same room for the detail toolbar in both visibility states.
class AndroidDetailInsets extends StatefulWidget {
  const AndroidDetailInsets({super.key, required this.child});

  final Widget child;

  @override
  State<AndroidDetailInsets> createState() => _AndroidDetailInsetsState();
}

class _AndroidDetailInsetsState extends State<AndroidDetailInsets> {
  static const _channel = MethodChannel('litetale/window_insets');
  ({Size size, double ratio})? _viewport;
  int _revision = 0;
  double _top = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final viewport = (size: media.size, ratio: media.devicePixelRatio);
    if (_viewport == viewport) {
      _top = math.max(_top, media.viewPadding.top);
      return;
    }
    _viewport = viewport;
    _top = media.viewPadding.top;
    unawaited(_readStableInset(++_revision, viewport.ratio));
  }

  Future<void> _readStableInset(int revision, double ratio) async {
    try {
      final pixels = await _channel.invokeMethod<int>('stableTopInset');
      if (!mounted || _revision != revision || pixels == null) return;
      final top = pixels / ratio;
      if (top > _top) setState(() => _top = top);
    } on MissingPluginException {
      // The Flutter view can still retain its last visible inset.
    } on PlatformException {
      // Keep the inset already delivered with the Flutter view.
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (_top <= media.viewPadding.top) {
      return MediaQuery(data: media, child: widget.child);
    }
    return MediaQuery(
      data: media.copyWith(
        viewPadding: media.viewPadding.copyWith(top: _top),
        padding: media.padding.copyWith(
          top: math.max(0, _top - media.viewInsets.top),
        ),
      ),
      child: widget.child,
    );
  }
}
