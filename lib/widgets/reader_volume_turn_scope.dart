import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/utils/controller_event.dart';

/// Hardware volume belongs to the current, foreground reading route only.
/// ModalRoute also covers dialogs and bottom sheets, so their controls never
/// turn the page hidden underneath or keep intercepting normal volume keys.
class ReaderVolumeTurnScope extends StatefulWidget {
  const ReaderVolumeTurnScope({
    super.key,
    required this.onTurn,
    required this.child,
    this.active = true,
  });

  final ValueChanged<ReaderControllerEventArgs> onTurn;
  final Widget child;
  final bool active;

  @override
  State<ReaderVolumeTurnScope> createState() => _ReaderVolumeTurnScopeState();
}

class _ReaderVolumeTurnScopeState extends State<ReaderVolumeTurnScope>
    with WidgetsBindingObserver {
  VolumeControlCubit? _preferences;
  ModalRoute<dynamic>? _route;
  StreamSubscription<ReaderControllerEventArgs>? _subscription;
  Timer? _audioSessionTimer;
  late AppLifecycleState _lifecycle;

  bool get _canListen =>
      mounted &&
      widget.active &&
      _preferences?.isSupported == true &&
      _preferences?.isEnabled == true &&
      _route?.isCurrent == true &&
      _lifecycle == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _preferences = context.read<VolumeControlCubit>();
    _route = ModalRoute.of(context);
    _syncListener();
  }

  @override
  void didUpdateWidget(ReaderVolumeTurnScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncListener();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncListener();
  }

  void _syncListener() {
    if (!_canListen) {
      _stopListener();
      return;
    }
    if (_subscription != null) return;
    _subscription = readerVolumeEvents.listen(
      (event) {
        // A platform event may already be queued when a modal opens or a
        // preference changes. Never dispatch it to the covered reader.
        if (_canListen) widget.onTurn(event);
      },
      onError: (Object _, StackTrace __) {
        // A missing/closed platform stream must not break the reading route.
      },
    );
    if (Platform.isIOS) {
      _audioSessionTimer = Timer(const Duration(milliseconds: 300), () async {
        if (!_canListen) return;
        try {
          await const MethodChannel(
            'methods',
          ).invokeMethod<void>('reassertAudioSession');
        } on PlatformException catch (_) {
          // The observer remains usable if another audio session owns focus.
        } on MissingPluginException catch (_) {
          // No native observer exists on unsupported test/desktop platforms.
        }
      });
    }
  }

  void _stopListener() {
    _audioSessionTimer?.cancel();
    _audioSessionTimer = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocListener<VolumeControlCubit, bool>(
    listener: (_, _) => _syncListener(),
    child: widget.child,
  );
}
