import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/wenku8_recovery_button.dart';

void main() {
  tearDown(() => activeSource.value = SourceId.wenku8);
  for (final verified in [false, true]) {
    testWidgets('verification $verified replays only on successful return', (
      tester,
    ) async {
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wenku8RecoveryButton(
              error: const Wenku8SiteVerificationRequired(),
              source: SourceId.wenku8,
              verify: (_) async => verified,
              onRecovered: () async {
                retries++;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开文库8验证 / 登录'));
      await tester.pumpAndSettle();
      expect(retries, verified ? 1 : 0);
    });
  }

  testWidgets('switching source cancels a pending recovery', (tester) async {
    final pending = Completer<bool>();
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wenku8RecoveryButton(
            error: const Wenku8SiteVerificationRequired(),
            source: SourceId.wenku8,
            verify: (_) => pending.future,
            onRecovered: () async {
              retries++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开文库8验证 / 登录'));
    await tester.pump();
    activeSource.value = SourceId.lightNovelShelf;
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(retries, 0);
  });

  testWidgets('another source never displays the Wenku8 recovery action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wenku8RecoveryButton(
            error: const Wenku8SiteVerificationRequired(),
            source: SourceId.lightNovelShelf,
            onRecovered: () async {},
          ),
        ),
      ),
    );
    expect(find.text('打开文库8验证 / 登录'), findsNothing);
  });
}
