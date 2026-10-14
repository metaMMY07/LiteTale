import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/bili_site_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live website home and SeaBed detail use public HTML',
    () async {
      final original = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = original);
      final source = BiliSiteSource(
        searcher: (_, __) => throw StateError('not used'),
        chapterLoader: (_, __) => throw StateError('not used'),
      );
      final clock = Stopwatch()..start();
      final home = await source.discover();
      final homeMs = clock.elapsedMilliseconds;
      expect(home.single.list, isNotEmpty);
      expect(home.single.list.any((b) => b.img.startsWith('https://')), true);
      clock.reset();
      final detail = await source.detail('bili:2844');
      expect(detail.info.title, 'SeaBed');
      expect(detail.volumes.expand((v) => v.chapters).length, 224);
      // Only public timing/counts, no prose or account/session data.
      // ignore: avoid_print
      print(
        'Bili website: home ${homeMs}ms, SeaBed detail ${clock.elapsedMilliseconds}ms, 224 chapters',
      );
    },
    skip: !const bool.fromEnvironment('BILI_SITE_ONLINE'),
    timeout: const Timeout(Duration(seconds: 55)),
  );
}
