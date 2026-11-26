import 'package:flutter/services.dart';

/// One shared broadcast stream lets Flutter balance the platform listener for
/// the visible reader. There is no separate reference count to underflow when a
/// reader was opened with the preference disabled.
final Stream<ReaderControllerEventArgs> readerVolumeEvents = const EventChannel(
      'volume_button',
    )
    .receiveBroadcastStream()
    .where((event) => event == 'UP' || event == 'DOWN')
    .map((event) => ReaderControllerEventArgs(event as String));

class ReaderControllerEventArgs {
  const ReaderControllerEventArgs(this.key);

  final String key;
}
