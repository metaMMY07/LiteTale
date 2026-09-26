import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';

Future<Uint8List> indicatorPixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(
      of: find.byType(ExpressiveLoadingIndicator),
      matching: find.byType(RepaintBoundary),
    ),
  );
  final image = await boundary.toImage(pixelRatio: 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> saveIndicatorPreview(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(
      of: find.byType(ExpressiveLoadingIndicator),
      matching: find.byType(RepaintBoundary),
    ),
  );
  final image = await boundary.toImage(pixelRatio: 6);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final directory = Directory('build/material-loading');
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(
    data!.buffer.asUint8List(),
  );
}

void main() {
  testWidgets('loading shape changes while staying in its own paint boundary', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CenteredLoadingIndicator())),
    );
    final initial = (await tester.runAsync(() => indicatorPixels(tester)))!;
    if (Platform.environment['LITETALE_LOADING_CAPTURE'] == '1') {
      await tester.runAsync(() => saveIndicatorPreview(tester, 'shape-circle'));
    }
    await tester.pump(const Duration(milliseconds: 1100));
    final later = (await tester.runAsync(() => indicatorPixels(tester)))!;
    if (Platform.environment['LITETALE_LOADING_CAPTURE'] == '1') {
      await tester.runAsync(() => saveIndicatorPreview(tester, 'shape-morphed'));
    }
    expect(listEquals(initial, later), isFalse);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == '正在加载',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('system reduced motion keeps a stable loading shape', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: const Scaffold(body: CenteredLoadingIndicator()),
              ),
        ),
      ),
    );
    final initial = (await tester.runAsync(() => indicatorPixels(tester)))!;
    await tester.pump(const Duration(seconds: 2));
    final later = (await tester.runAsync(() => indicatorPixels(tester)))!;
    expect(listEquals(initial, later), isTrue);
  });
}
