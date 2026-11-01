import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/source_comment.dart';
import 'package:wild/pages/novel/reviews_page.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

const first = SourceComment(
  id: '1',
  author: '读者甲',
  content: '第一页评论',
  time: '2026-11-01',
);
const second = SourceComment(id: '2', author: '读者乙', content: '第二页评论');

Future<void> show(
  WidgetTester tester,
  ReviewsLoader loader, {
  String book = 'bili:88',
  List<CommentFeed> feeds = const [CommentFeed.comments],
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
      home: ReviewsPage(
        aid: book,
        title: '测试轻小说',
        loader: loader,
        feeds: feeds,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'page 2 failure preserves page 1 and retries only on explicit action',
    (tester) async {
      final pages = <int>[];
      var failed = true;
      await show(tester, (
        book, {
        int page = 1,
        CommentFeed feed = CommentFeed.comments,
        String? threadId,
        bool refresh = false,
      }) async {
        expect(book, 'bili:88');
        pages.add(page);
        if (page == 2 && failed) throw const SourceCommentException('原站限流');
        return SourceCommentPage(
          page: page,
          items: page == 1 ? [first] : [first, second],
          hasMore: page == 1,
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('第一页评论'), findsOneWidget);
      await tester.tap(find.text('加载更多评论'));
      await tester.pumpAndSettle();
      expect(find.text('第一页评论'), findsOneWidget);
      expect(find.text('原站限流'), findsOneWidget);
      final calls = pages.length;
      await tester.pump(const Duration(seconds: 2));
      expect(pages.length, calls);
      failed = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(pages, [1, 2, 2]);
      expect(find.text('第一页评论'), findsOneWidget);
      expect(find.text('第二页评论'), findsOneWidget);
      expect(find.text('加载更多评论'), findsNothing);
    },
  );
  testWidgets('refresh failure retries page 1, never the next old page', (
    tester,
  ) async {
    final pages = <(int, bool)>[];
    var fail = false;
    await show(tester, (
      _, {
      int page = 1,
      CommentFeed feed = CommentFeed.comments,
      String? threadId,
      bool refresh = false,
    }) async {
      pages.add((page, refresh));
      if (fail) throw const SourceCommentException('刷新失败');
      return SourceCommentPage(
        page: page,
        items: page == 1 ? [first] : [second],
        hasMore: page == 1,
      );
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多评论'));
    await tester.pumpAndSettle();
    fail = true;
    final refresh = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    await refresh.onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('第一页评论'), findsOneWidget);
    fail = false;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(pages, [(1, false), (2, false), (1, true), (1, true)]);
    expect(find.text('第二页评论'), findsNothing);
  });
  testWidgets('popping cancels waiting and ignores a late provider failure', (
    tester,
  ) async {
    final gate = Completer<SourceCommentPage>();
    ReadRequest? scope;
    await show(tester, (
      _, {
      int page = 1,
      CommentFeed feed = CommentFeed.comments,
      String? threadId,
      bool refresh = false,
    }) {
      scope = ReadRequest.current;
      return gate.future;
    });
    expect(scope, isNotNull);
    await tester.pumpWidget(const MaterialApp(home: Text('已返回')));
    expect(scope!.isCancelled, true);
    gate.completeError(StateError('late upstream error'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('changing books discards late output from the previous book', (
    tester,
  ) async {
    final gate = Completer<SourceCommentPage>();
    Future<SourceCommentPage> loader(
      String book, {
      int page = 1,
      CommentFeed feed = CommentFeed.comments,
      String? threadId,
      bool refresh = false,
    }) async {
      return book == 'bili:88'
          ? gate.future
          : SourceCommentPage(page: 1, items: [second]);
    }

    await show(tester, loader);
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewsPage(
          aid: 'bili:99',
          title: '另一本',
          loader: loader,
          feeds: const [CommentFeed.comments],
        ),
      ),
    );
    await tester.pumpAndSettle();
    gate.complete(const SourceCommentPage(page: 1, items: [first]));
    await tester.pump();
    expect(find.text('第二页评论'), findsOneWidget);
    expect(find.text('第一页评论'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'spoilers remain hidden until tapped; inline replies expand in Flutter',
    (tester) async {
      await show(
        tester,
        (
          _, {
          int page = 1,
          CommentFeed feed = CommentFeed.comments,
          String? threadId,
          bool refresh = false,
        }) async => const SourceCommentPage(
          page: 1,
          items: [
            SourceComment(
              id: '1',
              author: '甲',
              content: '剧透正文',
              spoiler: true,
              replies: [SourceComment(id: '2', author: '乙', content: '回复正文')],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('剧透正文'), findsNothing);
      expect(find.text('回复正文'), findsNothing);
      await tester.tap(find.text('含剧透，点击查看'));
      await tester.pumpAndSettle();
      expect(find.text('剧透正文'), findsOneWidget);
      await tester.tap(find.text('查看回复 / 引用（1）'));
      await tester.pumpAndSettle();
      expect(find.text('回复正文'), findsOneWidget);
    },
  );
  testWidgets('SF maintenance stays visible instead of showing no comments', (
    tester,
  ) async {
    await show(
      tester,
      (
        _, {
        int page = 1,
        CommentFeed feed = CommentFeed.comments,
        String? threadId,
        bool refresh = false,
      }) async =>
          const SourceCommentPage(page: 1, items: [], notice: '评论系统维护中,请耐心等待哦'),
    );
    await tester.pumpAndSettle();
    expect(find.text('评论系统维护中,请耐心等待哦'), findsOneWidget);
    expect(find.text('暂无评论'), findsNothing);
  });
  testWidgets(
    'SF short/long feeds and reply pagination keep the original book',
    (tester) async {
      final calls = <(String, CommentFeed, String?)>[];
      await show(tester, (
        book, {
        int page = 1,
        CommentFeed feed = CommentFeed.comments,
        String? threadId,
        bool refresh = false,
      }) async {
        calls.add((book, feed, threadId));
        return SourceCommentPage(
          page: page,
          items:
              threadId != null
                  ? [second]
                  : [
                    SourceComment(
                      id: '42',
                      author: '甲',
                      content: feed.name,
                      replyCount: 1,
                      canOpenThread: true,
                    ),
                  ],
        );
      }, feeds: const [CommentFeed.comments, CommentFeed.reviews]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('书评'));
      await tester.pumpAndSettle();
      expect(calls.last, ('bili:88', CommentFeed.reviews, null));
      await tester.tap(find.text('查看回复（1）'));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'bili:88');
      expect(calls.last.$3, '42');
      expect(find.text('第二页评论'), findsOneWidget);
      expect(find.text('评论回复'), findsOneWidget);
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final size in [const Size(320, 640), const Size(1024, 700)]) {
      testWidgets(
        '$platform comments fill the row and tolerate 2x text at $size',
        (tester) async {
          await show(
            tester,
            (
              _, {
              int page = 1,
              CommentFeed feed = CommentFeed.comments,
              String? threadId,
              bool refresh = false,
            }) async => SourceCommentPage(
              page: 1,
              items: [
                SourceComment(
                  id: '1',
                  author: '很长的读者昵称' * 8,
                  content: '正文与段落\n' * 50,
                ),
              ],
            ),
            size: size,
            scale: 2,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final card = tester.getRect(find.byType(AppleGlassCard));
          expect(card.width, size.width - 32);
          expect(card.left, 16);
          if (platform == TargetPlatform.iOS) {
            expect(find.byType(AppleGlassSurface), findsOneWidget);
          }
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
