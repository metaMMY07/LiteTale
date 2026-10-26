import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/huanmeng_http_transport.dart';
import 'package:wild/sources/huanmeng_source.dart';

void main() {
  test(
    'published Huanmeng API supports the real direct reading chain',
    () async {
      final source = HuanmengSource(
        transport: HuanmengHttpTransport(
          userAgent:
              const bool.fromEnvironment('HUANMENG_IOS_CLIENT')
                  ? HuanmengHttpTransport.iosUserAgent
                  : null,
        ),
      );
      final clock = Stopwatch()..start();
      final list = await source.list();
      final next = await source.list(page: 2);
      expect(list.records, isNotEmpty);
      expect(
        next.records.any((b) => !list.records.any((a) => a.aid == b.aid)),
        isTrue,
      );
      final search = await source.search('败北', 'title', 1);
      expect(search.records.any((b) => b.aid == 'hm:4799'), isTrue);
      final detail = await source.detail('hm:4799');
      expect(detail.info.title, contains('败北'));
      final chapters = detail.volumes.expand((v) => v.chapters).toList();
      expect(chapters.length, greaterThan(10));
      expect(chapters.any((c) => c.cid == 'hm:4799:1841'), isTrue);
      final chapter = await source.chapter('hm:4799', 'hm:4799:1841');
      expect(chapter.content.length, greaterThan(200));
      expect(chapter.content, isNot(contains('接口密码错误')));
      expect(chapter.content, isNot(contains('书籍下架通知')));
      stdout.writeln(
        'HUANMENG_LIVE_RESULT=${jsonEncode({'network': 'Dart-default-direct-no-proxy', 'list': list.records.length, 'next': next.records.length, 'search': search.records.length, 'catalog': chapters.length, 'chapterCharacters': chapter.content.length, 'elapsedMs': clock.elapsedMilliseconds})}',
      );
    },
    skip: !const bool.fromEnvironment('HUANMENG_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
