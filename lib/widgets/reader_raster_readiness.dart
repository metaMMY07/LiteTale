import 'package:flutter/material.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';

/// Resources belonging to one reader page must paint before its PNG is cached.
/// Changes during asynchronous readback invalidate that readback's revision.
class ReaderRasterReadiness {
  ReaderRasterReadiness({required this.onChanged});

  final VoidCallback onChanged;
  final Set<Object> _pending = {};
  int _revision = 0;

  bool get isReady => _pending.isEmpty;
  int get revision => _revision;

  void waitFor(Object resource) {
    if (_pending.add(resource)) {
      _revision++;
      onChanged();
    }
  }

  void complete(Object resource) {
    if (_pending.remove(resource)) {
      _revision++;
      onChanged();
    }
  }
}

class ReaderRasterScope extends InheritedWidget {
  const ReaderRasterScope({
    super.key,
    required this.readiness,
    required super.child,
  });

  final ReaderRasterReadiness readiness;

  static ReaderRasterReadiness? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderRasterScope>()
          ?.readiness;

  @override
  bool updateShouldNotify(ReaderRasterScope oldWidget) =>
      readiness != oldWidget.readiness;
}

/// Uses Image's actual first-frame lifecycle, without fetching/decoding twice.
/// An error is also a finished, paintable state so it cannot stall page turns.
class ReaderRasterImage extends StatefulWidget {
  const ReaderRasterImage({
    super.key,
    required this.image,
    required this.errorChild,
  });

  final ImageProvider image;
  final Widget errorChild;

  @override
  State<ReaderRasterImage> createState() => _ReaderRasterImageState();
}

class _ReaderRasterImageState extends State<ReaderRasterImage> {
  Object _resource = Object();
  ReaderRasterReadiness? _readiness;
  bool _finished = false;

  void _finish() {
    _finished = true;
    _readiness?.complete(_resource);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final readiness = ReaderRasterScope.maybeOf(context);
    if (readiness != _readiness) {
      _readiness?.complete(_resource);
      _readiness = readiness;
      if (!_finished) _readiness?.waitFor(_resource);
    }
  }

  @override
  void didUpdateWidget(ReaderRasterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _readiness?.complete(_resource);
      _resource = Object();
      _finished = false;
      _readiness?.waitFor(_resource);
    }
  }

  @override
  void dispose() {
    _readiness?.complete(_resource);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
    image: widget.image,
    fit: BoxFit.contain,
    frameBuilder: (context, child, frame, synchronous) {
      if (frame == null) return const CenteredLoadingIndicator();
      _finish();
      return child;
    },
    errorBuilder: (context, error, stack) {
      _finish();
      return widget.errorChild;
    },
  );
}
