import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/source_comment.dart';
import 'package:wild/services/light_novel_shelf_service.dart';
import 'package:wild/services/shelf_device_id.dart';
import 'package:wild/sources/light_novel_shelf_source.dart';
import 'package:wild/sources/lnovel_source.dart';
import 'package:wild/sources/bili_site_source.dart';
import 'package:wild/sources/sfacg_comments.dart';
import 'package:wild/sources/rules/scoped_rule_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('LITETALE_COMMENTS_LIVE');
  final report = <String, Object?>{};
  final directory = Directory('build/qa/source-comments-2026-11-01');

  Future<void> record(
    String source,
    Future<SourceCommentPage> Function() load,
  ) async {
    final original = HttpOverrides.current;
    HttpOverrides.global = null;
    final clock = Stopwatch()..start();
    try {
      final page = await load();
      report[source] = {
        'ok': true,
        'items': page.items.length,
        'hasMore': page.hasMore,
        'notice': page.notice,
        'milliseconds': clock.elapsedMilliseconds,
      };
    } catch (error) {
      report[source] = {
        'ok': false,
        'error': '$error',
        'milliseconds': clock.elapsedMilliseconds,
      };
      rethrow;
    } finally {
      HttpOverrides.global = original;
      await directory.create(recursive: true);
      await File(
        '${directory.path}/live-results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    }
  }

  test(
    'live LNovel public book comments',
    () => record('lnovel', () async {
      final result = await LNovelSource().comments('lnv:3638');
      expect(result.items.length, greaterThan(10));
      expect(
        result.items.every((e) => e.author.isNotEmpty && e.content.isNotEmpty),
        true,
      );
      expect(result.items.any((e) => e.replies.isNotEmpty), true);
      return result;
    }),
    skip: !live,
  );

  test(
    'live Bili public comments and advertised pagination',
    () => record('bili', () async {
      final source = BiliSiteSource(
        searcher: (_, __) async => throw StateError('unused'),
        chapterLoader: (_, __) async => throw StateError('unused'),
      );
      final first = await source.comments('bili:88');
      expect(first.items, isNotEmpty);
      // Some guest responses deliberately comment out the entire pager.
      // Do not promote disabled HTML into an advertised next-page action.
      if (first.hasMore) {
        final second = await source.comments('bili:88', page: 2);
        expect(second.items, isNotEmpty);
        expect(first.items.first.id, isNot(second.items.first.id));
      }
      return first;
    }),
    skip: !live,
    timeout: const Timeout(Duration(seconds: 55)),
  );

  test(
    'live SF public short and long review endpoint',
    () => record('sfacg', () async {
      final adapter = SfacgComments(
        ScopedRuleSourceTransport(
          origin: Uri.parse('https://book.sfacg.com'),
          userAgent: 'Mozilla/5.0',
          diagnosticSource: 'sfacg-comments-qa',
        ),
      );
      final page = await adapter.load('775264');
      final long = await adapter.load('775264', feed: CommentFeed.reviews);
      expect(long.page, 1);
      return page;
    }),
    skip: !live,
  );

  test(
    'live Shelf anonymous GetComments with a persisted QA identity',
    () => record('lightNovelShelf', () async {
      // A separate QA installation identity. Persist before sending; never read
      // the app's real account, secure storage, device ID, or tokens.
      await directory.create(recursive: true);
      final file = File('${directory.path}/shelf-qa-installation.txt');
      final identity = ShelfDeviceId(
        readValue: () async => await file.exists() ? file.readAsString() : null,
        writeValue: (value) async {
          await file.writeAsString(value, flush: true);
        },
      );
      final service = LightNovelShelfService(
        deviceId: identity.value,
        attemptTimeout: const Duration(seconds: 12),
      );
      final books = await service.fetchLatestBooks();
      expect(books, isNotEmpty);
      final source = LightNovelShelfSource(
        invoke:
            (method, args) async =>
                shelfPayload(await service.invoke(method, args)),
      );
      final result = await source.comments('lns:${books.first.id}');
      expect(result.page, 1);
      return result;
    }),
    skip: !live,
    timeout: const Timeout(Duration(seconds: 55)),
  );
}
