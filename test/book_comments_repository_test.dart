import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/source_comment.dart';
import 'package:wild/services/book_comments_repository.dart';
import 'package:wild/services/read_request.dart';

SourceCommentPage result(int page, {String content = '正文'}) =>
    SourceCommentPage(
      page: page,
      items: [SourceComment(id: '$page', author: '甲', content: content)],
    );

void main() {
  test(
    'coalesces identical pages, caches success, isolates book/page/feed/thread',
    () async {
      var calls = 0;
      final repository = BookCommentsRepository(
        generation: (_) => 0,
        loader: (
          _, {
          int page = 1,
          CommentFeed feed = CommentFeed.comments,
          String? threadId,
        }) async {
          calls++;
          return result(page);
        },
      );
      expect(calls, 0);
      await Future.wait([repository.load('lns:1'), repository.load('lns:1')]);
      await repository.load('lns:1');
      expect(calls, 1);
      await repository.load('bili:1');
      await repository.load('lns:1', page: 2);
      await repository.load('lns:1', feed: CommentFeed.reviews);
      await repository.load('lns:1', threadId: '2');
      expect(calls, 5);
    },
  );
  test(
    'one departing subscriber does not cancel the remaining reader',
    () async {
      final response = Completer<SourceCommentPage>();
      ReadRequest? physical;
      final repository = BookCommentsRepository(
        generation: (_) => 0,
        loader: (
          _, {
          int page = 1,
          CommentFeed feed = CommentFeed.comments,
          String? threadId,
        }) {
          physical = ReadRequest.current;
          return response.future;
        },
      );
      final one = ReadRequest(), two = ReadRequest();
      final a = ReadRequest.run(one, () => repository.load('lns:1'));
      final aCheck = expectLater(a, throwsA(isA<ReadCancelled>()));
      final b = ReadRequest.run(two, () => repository.load('lns:1'));
      await Future<void>.delayed(Duration.zero);
      one.cancel();
      await aCheck;
      expect(physical!.isCancelled, false);
      response.complete(result(1));
      expect((await b).items.single.content, '正文');
    },
  );
  test(
    'last caller cancellation frees the physical task and never caches late output',
    () async {
      final gates = <Completer<SourceCommentPage>>[];
      ReadRequest? physical;
      final repository = BookCommentsRepository(
        generation: (_) => 0,
        loader: (
          _, {
          int page = 1,
          CommentFeed feed = CommentFeed.comments,
          String? threadId,
        }) {
          physical = ReadRequest.current;
          final gate = Completer<SourceCommentPage>();
          gates.add(gate);
          return gate.future;
        },
      );
      final owner = ReadRequest();
      final pending = ReadRequest.run(owner, () => repository.load('lns:1'));
      final check = expectLater(pending, throwsA(isA<ReadCancelled>()));
      await Future<void>.delayed(Duration.zero);
      owner.cancel();
      await check;
      expect(physical!.isCancelled, true);
      final replacement = repository.load('lns:1');
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2);
      gates[0].complete(result(1, content: '旧'));
      gates[1].complete(result(1, content: '新'));
      expect((await replacement).items.single.content, '新');
      expect((await repository.load('lns:1')).items.single.content, '新');
    },
  );
  test(
    'account generation changes reject old output and skip old cached data',
    () async {
      var generation = 0;
      final gates = <Completer<SourceCommentPage>>[];
      final repository = BookCommentsRepository(
        generation: (_) => generation,
        loader: (
          _, {
          int page = 1,
          CommentFeed feed = CommentFeed.comments,
          String? threadId,
        }) {
          final gate = Completer<SourceCommentPage>();
          gates.add(gate);
          return gate.future;
        },
      );
      final old = repository.load('lns:1');
      final check = expectLater(old, throwsA(isA<SourceCommentException>()));
      await Future<void>.delayed(Duration.zero);
      generation++;
      gates[0].complete(result(1));
      await check;
      final fresh = repository.load('lns:1');
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2);
      gates[1].complete(result(1));
      await fresh;
    },
  );
  test('manual refresh invalidates all previously cached pages', () async {
    var calls = 0;
    final repository = BookCommentsRepository(
      generation: (_) => 0,
      loader: (
        _, {
        int page = 1,
        CommentFeed feed = CommentFeed.comments,
        String? threadId,
      }) async {
        calls++;
        return result(page, content: '$calls');
      },
    );
    await repository.load('lns:1');
    await repository.load('lns:1', page: 2);
    expect(
      (await repository.load('lns:1', refresh: true)).items.single.content,
      '3',
    );
    expect((await repository.load('lns:1', page: 2)).items.single.content, '4');
  });
  test('failure and timeout do not become empty cached successes', () async {
    var calls = 0;
    final repository = BookCommentsRepository(
      generation: (_) => 0,
      timeout: const Duration(milliseconds: 30),
      loader: (
        _, {
        int page = 1,
        CommentFeed feed = CommentFeed.comments,
        String? threadId,
      }) {
        calls++;
        return Completer<SourceCommentPage>().future;
      },
    );
    await expectLater(
      repository.load('lns:1'),
      throwsA(isA<SourceCommentException>()),
    );
    await expectLater(
      repository.load('lns:1'),
      throwsA(isA<SourceCommentException>()),
    );
    expect(calls, 2);
  });
  test('cache eviction and wrong upstream pages are bounded', () async {
    var calls = 0;
    final repository = BookCommentsRepository(
      generation: (_) => 0,
      maxEntries: 1,
      loader: (
        _, {
        int page = 1,
        CommentFeed feed = CommentFeed.comments,
        String? threadId,
      }) async {
        calls++;
        return result(page);
      },
    );
    await repository.load('lns:1');
    await repository.load('lns:2');
    await repository.load('lns:1');
    expect(calls, 3);
    final invalid = BookCommentsRepository(
      generation: (_) => 0,
      loader:
          (
            _, {
            int page = 1,
            CommentFeed feed = CommentFeed.comments,
            String? threadId,
          }) async => result(9),
    );
    await expectLater(
      invalid.load('lns:1'),
      throwsA(isA<SourceCommentException>()),
    );
  });
}
