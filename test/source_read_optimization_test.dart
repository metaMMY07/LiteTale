import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/novel/novel_info_cubit.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/read_result_cache.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/rule_book_source.dart' show ruleBookId;
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';
import 'bounded_detail_cache_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry
      in {
        SourceId.huanmeng: 'hm:991081',
        SourceId.bili: 'bili:991082',
        SourceId.lnovel: 'lnv:991083',
        SourceId.lightNovelShelf: 'lns:991084',
        SourceId.wenku8: '991085',
        SourceId.esj: 'esj:991086',
        SourceId.rule('perf_fixture'): ruleBookId(
          'perf_fixture',
          'https://example.com/book/991087',
        ),
        SourceId.localEpub: 'epub:${'a' * 64}',
      }.entries) {
    test(
      '${entry.key.name}: complete detail is handed to the page once',
      () async {
        final selected = activeSource.value;
        activeSource.value = entry.key;
        addTearDown(() => activeSource.value = selected);
        final original = api.bookSources[entry.key];
        final fake = _Source(
          entry.key,
          fixtures.detail(intro: '字' * (3 * 1024 * 1024)),
        );
        api.bookSources[entry.key] = fake;
        addTearDown(() {
          if (original == null) {
            api.bookSources.remove(entry.key);
          } else {
            api.bookSources[entry.key] = original;
          }
        });
        final cubit = NovelInfoCubit(
          entry.value,
          loadHistory: ({required novelId}) async => null,
        );
        addTearDown(cubit.close);
        await cubit.load();
        expect(cubit.state, isA<NovelInfoLoaded>());
        expect(
          (cubit.state as NovelInfoLoaded).volumes,
          same(fake.value.volumes),
        );
        expect(fake.details, 1);
      },
    );
  }

  test(
    'online chapter reuse keeps font and source revision together',
    () async {
      final original = api.bookSources[SourceId.bili]!;
      final revision = sourceRevision.value;
      final fake = _Source(SourceId.bili, fixtures.detail());
      api.bookSources[SourceId.bili] = fake;
      addTearDown(() {
        api.bookSources[SourceId.bili] = original;
        sourceRevision.value = revision;
      });
      const aid = 'bili:991088', cid = 'bili:991088:11';
      final first = await api.readerChapter(aid: aid, cid: cid);
      expect((await api.readerChapter(aid: aid, cid: cid)), same(first));
      expect(first.fontFamily, 'paired-source-font');
      expect(fake.chapters, 1);
      sourceRevision.value++;
      await api.readerChapter(aid: aid, cid: cid);
      expect(fake.chapters, 2);
    },
  );

  test(
    'abandoned chapter does not poison a new read of the same chapter',
    () async {
      final original = api.bookSources[SourceId.huanmeng]!;
      final fake = _Source(SourceId.huanmeng, fixtures.detail());
      fake.gate = Completer<SourceChapter>();
      api.bookSources[SourceId.huanmeng] = fake;
      addTearDown(() => api.bookSources[SourceId.huanmeng] = original);
      final request = ReadRequest();
      const aid = 'hm:991089', cid = 'hm:991089:11';
      final old = ReadRequest.run(
        request,
        () => api.readerChapter(aid: aid, cid: cid),
      );
      final checked = expectLater(old, throwsA(isA<ReadCancelled>()));
      await Future<void>.delayed(Duration.zero);
      request.cancel();
      await checked;
      final oldGate = fake.gate!;
      fake.gate = null;
      final newer = await api.readerChapter(aid: aid, cid: cid);
      expect(newer.content, '完整正文');
      oldGate.complete(const SourceChapter('旧正文'));
      await Future<void>.delayed(Duration.zero);
      expect((await api.readerChapter(aid: aid, cid: cid)).content, '完整正文');
      expect(fake.chapters, 2);
    },
  );

  test(
    'single-key invalidation detaches stale load without clearing other books',
    () async {
      final cache = ReadResultCache<String, String>(
        maxEntries: 3,
        maxWeight: 1000,
        ttl: const Duration(minutes: 1),
        weightOf: (v) => v.length,
      );
      await cache.getOrLoad('other', () async => 'kept');
      final gate = Completer<String>();
      final old = cache.getOrLoad('key', () => gate.future);
      await Future<void>.delayed(Duration.zero);
      cache.invalidate('key');
      expect(await cache.getOrLoad('key', () async => 'new'), 'new');
      gate.complete('old');
      expect(await old, 'old');
      expect(cache.peek('key'), 'new');
      expect(cache.peek('other'), 'kept');
    },
  );
}

class _Source implements BookSource {
  _Source(this.id, this.value);
  @override
  final SourceId id;
  final SourceBookDetail value;
  int details = 0, chapters = 0;
  Completer<SourceChapter>? gate;
  @override
  Future<SourceBookDetail> detail(String bookId) async {
    details++;
    return value;
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    chapters++;
    if (gate != null) return gate!.future;
    return const SourceChapter('完整正文', fontFamily: 'paired-source-font');
  }

  @override
  Future<List<HomeBlock>> discover() => throw UnimplementedError();
  @override
  Future<PageStatsNovelCover> search(String keyword, String type, int page) =>
      throw UnimplementedError();
}
