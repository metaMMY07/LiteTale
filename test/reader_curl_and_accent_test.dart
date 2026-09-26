import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/widgets/app_color_settings.dart';

void main() {
  test('custom accent accepts any opaque RGB color and survives restart', () async {
    var saved = 'system';
    final cubit = AppAccentCubit(
      read: () async => saved,
      write: (value) async => saved = value,
    );
    const color = Color(0xFF9A7CE0);
    await cubit.select(customAccentValue(color));
    expect(cubit.state, 'custom:#9A7CE0');
    expect(appAccentSeed(cubit.state), color);
    final restarted = AppAccentCubit(
      read: () async => saved,
      write: (_) async {},
    );
    await restarted.load();
    expect(restarted.state, 'custom:#9A7CE0');
    await restarted.select('custom:#oops');
    expect(restarted.state, 'custom:#9A7CE0');
    await cubit.close();
    await restarted.close();
  });

  test('page curl stays off by default and persists an explicit choice', () async {
    var saved = '';
    final pending = Completer<String>();
    final cubit = ReaderCurlCubit(
      read: () => pending.future,
      write: (value) async => saved = value,
    );
    expect(cubit.state, isFalse);
    final loading = cubit.load();
    await cubit.setEnabled(true);
    pending.complete('false');
    await loading;
    expect(cubit.state, isTrue);
    final restarted = ReaderCurlCubit(
      read: () async => saved,
      write: (_) async {},
    );
    await restarted.load();
    expect(restarted.state, isTrue);
    await cubit.close();
    await restarted.close();
  });

  testWidgets('custom color can be applied from the settings picker', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cubit = AppAccentCubit(read: () async => '', write: (_) async {});
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AppColorSettings()),
          ),
        ),
      ),
    );
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题颜色'), findsOneWidget);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(cubit.state, startsWith('custom:#'));
    expect(find.text('自定义颜色（已选择）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
