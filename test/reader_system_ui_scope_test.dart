import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/reader_system_ui_scope.dart';

void main() {
  testWidgets('immersive reader survives reflow and restores UI on exit', (
    tester,
  ) async {
    final modes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const ReaderSystemUiScope(
        child: SizedBox(key: ValueKey('first-chapter')),
      ),
    );
    expect(modes, ['SystemUiMode.immersiveSticky']);
    await tester.pumpWidget(
      const ReaderSystemUiScope(child: SizedBox(key: ValueKey('repaginated'))),
    );
    expect(modes, ['SystemUiMode.immersiveSticky']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(modes.last, 'SystemUiMode.immersiveSticky');
    await tester.pumpWidget(const SizedBox());
    expect(modes.last, 'SystemUiMode.edgeToEdge');
  });
}
