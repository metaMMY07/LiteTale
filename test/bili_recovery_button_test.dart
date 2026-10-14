import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/bili_recovery_button.dart';

void main() {
  late SourceId previousSource;
  late int previousRevision;

  setUp(() {
    previousSource = activeSource.value;
    previousRevision = sourceRevision.value;
    activeSource.value = SourceId.bili;
  });

  tearDown(() {
    activeSource.value = previousSource;
    sourceRevision.value = previousRevision;
  });

  BiliSiteVerificationRequired request() => BiliSiteVerificationRequired(
    target: Uri.parse('https://www.bilinovel.net/novel/2844/278138.html'),
    kind: BiliProbeKind.chapter,
    revision: sourceRevision.value,
  );

  Widget host({
    required Object? error,
    SourceId source = SourceId.bili,
    Future<bool> Function(BuildContext)? verify,
    required Future<void> Function() onRecovered,
  }) => MaterialApp(
    home: Scaffold(
      body: BiliRecoveryButton(
        key: const ValueKey('bili-recovery'),
        error: error,
        source: source,
        verify: verify,
        onRecovered: onRecovered,
      ),
    ),
  );

  testWidgets('retries exactly once only after successful verification', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      host(
        error: request(),
        verify: (_) async => true,
        onRecovered: () async {
          retries++;
        },
      ),
    );

    await tester.tap(find.text('打开哔哩原站验证'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('cancelling verification does not retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      host(
        error: request(),
        verify: (_) async => false,
        onRecovered: () async {
          retries++;
        },
      ),
    );

    await tester.tap(find.text('打开哔哩原站验证'));
    await tester.pumpAndSettle();

    expect(retries, 0);
  });

  testWidgets('non-Bili sources do not show the action', (tester) async {
    await tester.pumpWidget(
      host(error: request(), source: SourceId.lnovel, onRecovered: () async {}),
    );

    expect(find.text('打开哔哩原站验证'), findsNothing);
  });

  testWidgets('untyped Bili errors do not show the verification action', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(error: 'network error', onRecovered: () async {}),
    );

    expect(find.text('打开哔哩原站验证'), findsNothing);
  });

  testWidgets('hard denial does not advertise a verification action', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        error: BiliSiteAccessDenied(request().target),
        onRecovered: () async {},
      ),
    );
    expect(find.byType(OutlinedButton), findsNothing);
  });
  testWidgets(
    'partial content offers a reading flow and retries after confirmation',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        host(
          error: BiliSiteVerificationRequired(
            target: request().target,
            kind: BiliProbeKind.chapter,
            revision: sourceRevision.value,
            contentRequired: true,
          ),
          verify: (_) async => true,
          onRecovered: () async {
            retries++;
          },
        ),
      );
      expect(find.text('打开哔哩原站验证'), findsNothing);
      await tester.tap(find.text('打开原站加载完整正文'));
      await tester.pumpAndSettle();
      expect(retries, 1);
    },
  );

  testWidgets('source switch while verification is open cancels retry', (
    tester,
  ) async {
    final pending = Completer<bool>();
    var retries = 0;
    await tester.pumpWidget(
      host(
        error: request(),
        verify: (_) => pending.future,
        onRecovered: () async {
          retries++;
        },
      ),
    );

    await tester.tap(find.text('打开哔哩原站验证'));
    await tester.pump();
    activeSource.value = SourceId.wenku8;
    pending.complete(true);
    await tester.pumpAndSettle();

    expect(retries, 0);
  });

  testWidgets('source revision change while verifying cancels retry', (
    tester,
  ) async {
    final pending = Completer<bool>();
    var retries = 0;
    await tester.pumpWidget(
      host(
        error: request(),
        verify: (_) => pending.future,
        onRecovered: () async {
          retries++;
        },
      ),
    );

    await tester.tap(find.text('打开哔哩原站验证'));
    await tester.pump();
    sourceRevision.value++;
    pending.complete(true);
    await tester.pumpAndSettle();

    expect(retries, 0);
  });

  testWidgets('replacing the request while verifying cancels retry', (
    tester,
  ) async {
    final pending = Completer<bool>();
    var retries = 0;
    var currentError = request();
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return BiliRecoveryButton(
                key: const ValueKey('bili-recovery'),
                error: currentError,
                source: SourceId.bili,
                verify: (_) => pending.future,
                onRecovered: () async {
                  retries++;
                },
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开哔哩原站验证'));
    await tester.pump();
    update(() {
      currentError = request();
    });
    await tester.pump();
    pending.complete(true);
    await tester.pumpAndSettle();

    expect(retries, 0);
  });

  testWidgets('double tap shares one verification and recovery', (
    tester,
  ) async {
    final pending = Completer<bool>();
    var verificationCalls = 0;
    var retries = 0;
    await tester.pumpWidget(
      host(
        error: request(),
        verify: (_) {
          verificationCalls++;
          return pending.future;
        },
        onRecovered: () async {
          retries++;
        },
      ),
    );

    final button = find.text('打开哔哩原站验证');
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(verificationCalls, 1);

    pending.complete(true);
    await tester.pumpAndSettle();

    expect(retries, 1);
  });
}
