import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/esj_source.dart';

// Opt-in host QA only. This override is never imported by production code.
class _QaProxy extends HttpOverrides {
  _QaProxy(this.proxy);
  final String proxy;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'PROXY $proxy';
}

// Opt-in anonymous live acceptance. Ordinary website requests, no user account.
void main() {
  test(
    'ESJ real search, list continuation, detail, catalog and public chapter',
    () async {
      const proxy = String.fromEnvironment('ESJ_QA_PROXY');
      if (proxy.isNotEmpty) {
        expect(proxy, matches(r'^127\.0\.0\.1:[0-9]{1,5}$'));
        final previous = HttpOverrides.current;
        HttpOverrides.global = _QaProxy(proxy);
        addTearDown(() => HttpOverrides.global = previous);
      }
      final source = EsjSource();
      final report = <String, Object>{
        'at': DateTime.now().toUtc().toIso8601String(),
        'live': true,
        'network': proxy.isEmpty ? 'direct' : 'explicit-host-QA-proxy',
      };
      Future<T> measure<T>(String name, Future<T> Function() read) async {
        final clock = Stopwatch()..start();
        try {
          return await read();
        } finally {
          report['${name}Ms'] = clock.elapsedMilliseconds;
        }
      }

      final first = await measure('list', () => source.list());
      final next = await measure('next', () => source.list(page: 2));
      expect(first.records, isNotEmpty);
      expect(
        next.records.any((n) => !first.records.any((a) => a.aid == n.aid)),
        isTrue,
      );
      final search = await measure(
        'search',
        () => source.search('雨狐', 'articlename', 1),
      );
      final match = search.records.firstWhere((b) => b.aid == 'esj:1788983302');
      final detail = await measure('detail', () => source.detail(match.aid));
      final chapters = detail.volumes.expand((v) => v.chapters).toList();
      expect(chapters.length, greaterThan(40));
      final body = await measure(
        'chapter',
        () => source.chapter(match.aid, chapters.first.cid),
      );
      expect(body.content.length, greaterThan(1000));
      report.addAll({
        'listCount': first.records.length,
        'nextCount': next.records.length,
        'searchMatch': match.aid,
        'chapterCount': chapters.length,
        'chapterChars': body.content.length,
        'coverPresent': detail.info.imgUrl.isNotEmpty,
        'account': false,
        'passed': true,
      });
      final file = File(
        'build/qa/android-material-2026-10-25/sources/esj-live-acceptance.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    },
    skip: !const bool.fromEnvironment('ESJ_LIVE'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
