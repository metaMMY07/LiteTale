import 'package:flutter/widgets.dart';

/// Keeps tap and volume turns away from an active drag.
class ReaderPageController extends PageController {
  ReaderPageController({super.initialPage});

  bool _turning = false;
  bool get isTurning =>
      _turning || (hasClients && position.isScrollingNotifier.value);

  Future<void> turn(int delta) async {
    if (!hasClients || isTurning) return;
    final target = page!.round() + delta;
    _turning = true;
    try {
      jumpToPage(target);
    } finally {
      _turning = false;
    }
  }
}
