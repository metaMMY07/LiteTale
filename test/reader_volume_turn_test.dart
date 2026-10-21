import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/widgets/page_curl_view.dart';
import 'package:wild/widgets/reader_volume_turn_scope.dart';
import 'package:wild/widgets/reader_volume_turn_setting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'existing preference survives restart and a delayed initial read',
    () async {
      var saved = 'true';
      final read = Completer<String>();
      final volume = VolumeControlCubit(
        supported: true,
        read: () => read.future,
        write: (value) async => saved = value,
      );
      addTearDown(volume.close);
      final loading = volume.init();
      await volume.updateVolumeControl(true);
      read.complete('false');
      await loading;
      expect(volume.isEnabled, isTrue);
      final restarted = VolumeControlCubit(
        supported: true,
        read: () async => saved,
        write: (_) async {},
      );
      addTearDown(restarted.close);
      await restarted.init();
      expect(restarted.isEnabled, isTrue);
    },
  );

  test(
    'rapid choices save in order; a failed save rolls back and can retry',
    () async {
      final firstWrite = Completer<void>();
      final writes = <String>[];
      final volume = VolumeControlCubit(
        supported: true,
        write: (value) async {
          writes.add(value);
          if (writes.length == 1) await firstWrite.future;
          if (writes.length == 3) throw StateError('test save failure');
        },
      );
      addTearDown(volume.close);
      final on = volume.updateVolumeControl(true);
      final off = volume.updateVolumeControl(false);
      await Future<void>.delayed(Duration.zero);
      expect(volume.isEnabled, isFalse);
      expect(writes, ['true']);
      firstWrite.complete();
      await Future.wait([on, off]);
      expect(writes, ['true', 'false']);
      await expectLater(volume.updateVolumeControl(true), throwsStateError);
      expect(volume.isEnabled, isFalse);
      await volume.updateVolumeControl(true);
      expect(volume.isEnabled, isTrue);
      expect(writes, ['true', 'false', 'true', 'true']);
    },
  );

  test(
    'unsupported platforms never read or write a volume preference',
    () async {
      var accesses = 0;
      final volume = VolumeControlCubit(
        supported: false,
        read: () async {
          accesses++;
          return 'true';
        },
        write: (_) async => accesses++,
      );
      addTearDown(volume.close);
      await volume.init();
      await volume.updateVolumeControl(true);
      expect(volume.isEnabled, isFalse);
      expect(accesses, 0);
    },
  );

  testWidgets(
    'disabled reader never subscribes; later enabled readers stay balanced',
    (tester) async {
      final platform = _VolumePlatform(tester);
      final volume = _volume();
      addTearDown(volume.close);
      final turns = <String>[];
      final app = _app(volume, turns);
      await tester.pumpWidget(app);
      await tester.pump();
      expect(platform.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(platform.calls, isEmpty);

      await volume.updateVolumeControl(true);
      await tester.pumpWidget(_app(volume, turns));
      await tester.pump();
      expect(platform.calls, ['listen']);
      await platform.send('UP');
      await platform.send('DOWN');
      await tester.pump();
      expect(turns, ['UP', 'DOWN']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(platform.calls, ['listen', 'cancel']);
      await tester.pumpWidget(_app(volume, turns));
      await tester.pump();
      await platform.send('DOWN');
      await tester.pump();
      expect(turns, ['UP', 'DOWN', 'DOWN']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(platform.calls, ['listen', 'cancel', 'listen', 'cancel']);
    },
  );

  testWidgets(
    'shared setting immediately enables and disables the visible reader',
    (tester) async {
      final platform = _VolumePlatform(tester);
      final volume = _volume();
      addTearDown(volume.close);
      final turns = <String>[];
      await tester.pumpWidget(_app(volume, turns, setting: true));
      await tester.pump();
      expect(platform.calls, isEmpty);
      await tester.tap(find.text('音量键翻页'));
      await tester.pump();
      expect(volume.isEnabled, isTrue);
      expect(platform.calls, ['listen']);
      await platform.send('DOWN');
      await tester.pump();
      expect(turns, ['DOWN']);
      await tester.tap(find.text('音量键翻页'));
      await tester.pump();
      expect(volume.isEnabled, isFalse);
      expect(platform.calls, ['listen', 'cancel']);
      await platform.send('UP');
      await tester.pump();
      expect(turns, ['DOWN']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dialogs, sheets and covering routes release hardware volume', (
    tester,
  ) async {
    final platform = _VolumePlatform(tester);
    final volume = _volume();
    addTearDown(volume.close);
    await volume.updateVolumeControl(true);
    final turns = <String>[];
    await tester.pumpWidget(_app(volume, turns));
    await tester.pumpAndSettle();

    for (final kind in ['dialog', 'sheet', 'route']) {
      final context = tester.element(find.byKey(const ValueKey('reader-body')));
      final pending = switch (kind) {
        'dialog' => showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('test dialog')),
        ),
        'sheet' => showModalBottomSheet<void>(
          context: context,
          builder: (_) => const SizedBox(height: 180),
        ),
        _ => Navigator.of(
          context,
        ).push<void>(MaterialPageRoute(builder: (_) => const Scaffold())),
      };
      // An already queued platform event must be ignored even before the
      // inherited route status has rebuilt the volume scope.
      await platform.send('DOWN');
      await tester.pumpAndSettle();
      expect(turns, isEmpty, reason: kind);
      expect(platform.calls.last, 'cancel', reason: kind);
      Navigator.of(context).pop();
      await pending;
      await tester.pumpAndSettle();
      expect(platform.calls.last, 'listen', reason: kind);
    }
    await platform.send('UP');
    await tester.pump();
    expect(turns, ['UP']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(platform.calls.last, 'cancel');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'background and loading readers release keys, resume restores them',
    (tester) async {
      final platform = _VolumePlatform(tester);
      final volume = _volume();
      addTearDown(volume.close);
      await volume.updateVolumeControl(true);
      final turns = <String>[];
      final key = GlobalKey<_ActiveReaderState>();
      await tester.pumpWidget(
        BlocProvider.value(
          value: volume,
          child: MaterialApp(home: _ActiveReader(key: key, turns: turns)),
        ),
      );
      await tester.pump();
      expect(platform.calls, isEmpty);
      key.currentState!.setLoaded(true);
      await tester.pump();
      expect(platform.calls, ['listen']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await platform.send('DOWN');
      await tester.pump();
      expect(platform.calls.last, 'cancel');
      expect(turns, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.calls.last, 'listen');
      await platform.send('unrecognized');
      await platform.send(0);
      await platform.send('DOWN');
      await tester.pump();
      expect(turns, ['DOWN']);
      key.currentState!.setLoaded(false);
      await tester.pump();
      expect(platform.calls.last, 'cancel');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'volume uses the existing curl turn API once per completed spread',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final platform = _VolumePlatform(tester);
      final volume = _volume();
      addTearDown(volume.close);
      await volume.updateVolumeControl(true);
      final curl = GlobalKey<PageCurlViewState>();
      final changed = <int>[];
      var index = 1;
      await tester.pumpWidget(
        BlocProvider.value(
          value: volume,
          child: MaterialApp(
            home: StatefulBuilder(
              builder:
                  (_, rebuild) => ReaderVolumeTurnScope(
                    onTurn:
                        (event) => curl.currentState!.turn(
                          event.key == 'DOWN' ? 1 : -1,
                        ),
                    child: PageCurlView(
                      key: curl,
                      pageCount: 4,
                      index: index,
                      isSpread: true,
                      paperDecoration: const BoxDecoration(color: Colors.white),
                      paperColor: Colors.white,
                      pageBuilder:
                          (_, page) => Center(child: Text('spread $page')),
                      onPageChanged: (next) {
                        changed.add(next);
                        rebuild(() => index = next);
                      },
                    ),
                  ),
            ),
          ),
        ),
      );
      await tester.pump();
      await platform.send('DOWN');
      await tester.pumpAndSettle();
      expect(changed, [2]);
      await platform.send('UP');
      await tester.pumpAndSettle();
      expect(changed, [2, 1]);
      // Turning already consumes its entire spread; no second handler advances
      // an additional physical leaf after the animation finishes.
      expect(find.text('spread 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

VolumeControlCubit _volume() => VolumeControlCubit(
  supported: true,
  read: () async => '',
  write: (_) async {},
);

Widget _app(
  VolumeControlCubit volume,
  List<String> turns, {
  bool setting = false,
}) => BlocProvider.value(
  value: volume,
  child: MaterialApp(
    home: Scaffold(
      body: ReaderVolumeTurnScope(
        onTurn: (event) => turns.add(event.key),
        child:
            setting
                ? const ReaderVolumeTurnSetting()
                : const SizedBox(key: ValueKey('reader-body')),
      ),
    ),
  ),
);

class _ActiveReader extends StatefulWidget {
  const _ActiveReader({super.key, required this.turns});
  final List<String> turns;

  @override
  State<_ActiveReader> createState() => _ActiveReaderState();
}

class _ActiveReaderState extends State<_ActiveReader> {
  bool loaded = false;
  void setLoaded(bool value) => setState(() => loaded = value);

  @override
  Widget build(BuildContext context) => ReaderVolumeTurnScope(
    active: loaded,
    onTurn: (event) => widget.turns.add(event.key),
    child: const SizedBox(),
  );
}

class _VolumePlatform {
  _VolumePlatform(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('volume_button'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('volume_button'),
        null,
      );
    });
  }

  final WidgetTester tester;
  final calls = <String>[];

  Future<void> send(Object value) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'volume_button',
        const StandardMethodCodec().encodeSuccessEnvelope(value),
        (_) {},
      );
}
