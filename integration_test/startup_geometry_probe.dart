import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wild/main.dart' as app;
import 'package:wild/pages/home_page.dart';
import 'package:wild/theme/ios_dock_insets.dart';
import 'package:wild/widgets/app_launch_screen.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final start = Timeline.now;
  final frames = <List<int>>[];
  final geometry = <Map<String, Object?>>[];
  var signature = '';
  var done = false;
  binding.addTimingsCallback((batch) {
    if (done) return;
    for (final frame in batch) {
      frames.add([
        frame.timestampInMicroseconds(ui.FramePhase.vsyncStart) - start,
        frame.buildDuration.inMicroseconds,
        frame.rasterDuration.inMicroseconds,
        frame.totalSpan.inMicroseconds,
      ]);
    }
  });
  binding.addPersistentFrameCallback((_) {
    if (done) return;
    final snapshot = <String, Object?>{};
    var native = 0;
    var placeholders = 0;
    void visit(Element node) {
      final widget = node.widget;
      if (widget is Offstage && widget.offstage) return;
      if (widget is TickerMode && !widget.enabled) return;
      final name = switch (widget) {
        AppLaunchScreen() => 'launch',
        HomePage() => 'home',
        AppleGlassToolbar() => 'toolbar',
        AppleGlassBottomBar() => 'dock',
        _ => null,
      };
      if (name != null) {
        final box = node.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final origin = box.localToGlobal(Offset.zero);
          snapshot[name] = [origin.dx, origin.dy, box.size.width, box.size.height]
              .map((v) => double.parse(v.toStringAsFixed(1)))
              .toList();
          if (widget is HomePage) {
            final media = node.getInheritedWidgetOfExactType<MediaQuery>()?.data;
            snapshot['padding'] = [media?.padding.top, media?.padding.bottom];
          }
        }
      }
      if (widget is IosDockInsets) snapshot['dockInset'] = widget.height;
      if (widget is UiKitView && widget.viewType == 'litetale/apple_glass') {
        native++;
      }
      if (widget.key == const ValueKey('glass-preview')) placeholders++;
      node.visitChildren(visit);
    }

    final root = binding.rootElement;
    if (root != null) visit(root);
    snapshot['native'] = native;
    snapshot['placeholders'] = placeholders;
    final nextSignature = jsonEncode(snapshot);
    if (signature == nextSignature) return;
    signature = nextSignature;
    geometry.add({'us': Timeline.now - start, ...snapshot});
  });
  await app.main();
  Timer(const Duration(seconds: 9), () {
    done = true;
    for (final row in geometry) {
      debugPrintSynchronously('LITETALE_GEOMETRY ${jsonEncode(row)}');
    }
    for (final frame in frames) {
      debugPrintSynchronously('LITETALE_FRAME ${jsonEncode(frame)}');
    }
    debugPrintSynchronously('LITETALE_PROBE_DONE');
  });
}
