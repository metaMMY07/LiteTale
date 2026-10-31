import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/bounded_detail_cache.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

SourceBookDetail detail({String intro = '', String title = '书名'}) =>
    SourceBookDetail(
      NovelInfo(
        title: title,
        author: '作者',
        status: '',
        finUpdate: '',
        imgUrl: '',
        introduce: intro,
        tags: const [],
        heat: '',
        trending: '',
        isAnimated: false,
      ),
      [
        Volume(
          id: 'v',
          title: '卷',
          chapters: [Chapter(aid: 'hm:1', cid: 'hm:1:1', title: '正文', url: '')],
        ),
      ],
    );

void main() {
  test('consumption promotes LRU; cover peek does not', () {
    final cache = BoundedDetailCache<String>(maxEntries: 2);
    cache['a'] = detail();
    cache['b'] = detail();
    expect(cache['a'], isNotNull);
    cache['c'] = detail();
    expect(cache.peek('b'), isNull);
    expect(cache.peek('a'), isNotNull);
    cache['d'] = detail();
    expect(cache.peek('a'), isNull);
  });
  test('oversized results remain usable without displacing the small book', () {
    final small = detail();
    final cache = BoundedDetailCache<String>(
      maxWeight: detailEstimatedWeight(small) * 4,
    );
    cache['small'] = small;
    final large = detail(intro: '长简介' * 10000);
    cache['large'] = large;
    expect(cache.peek('large'), isNull);
    expect(cache.peek('small'), same(small));
    expect(large.volumes.single.chapters, hasLength(1));
  });
  test(
    'weight, removal, scope invalidation and disabled storage stay bounded',
    () {
      final value = detail();
      final weight = detailEstimatedWeight(value);
      final cache = BoundedDetailCache<int>(maxWeight: weight * 2);
      for (var i = 0; i < 30; i++) {
        cache[i] = value;
      }
      expect(cache.length, 2);
      expect(cache.estimatedWeight, weight * 2);
      cache.removeWhere((key, _) => key.isEven);
      expect(cache.estimatedWeight, weight);
      cache.clear();
      expect(cache.estimatedWeight, 0);
      final disabled = BoundedDetailCache<int>(maxEntries: 0);
      disabled[1] = value;
      expect(disabled.length, 0);
    },
  );
}
