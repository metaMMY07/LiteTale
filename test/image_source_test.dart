import 'package:flutter_test/flutter_test.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/cached_image.dart';

void main() {
  test('image cache keys preserve book source across source switches', () {
    const url = 'https://pic.777743.xyz/3/3492/144956/178126.jpg';
    final wenku = CachedImageProvider(url, source: sourceOf('3492'));
    final shelf = CachedImageProvider(url, source: sourceOf('lns:3492'));
    final original = activeSource.value;
    addTearDown(() => activeSource.value = original);
    activeSource.value = SourceId.lightNovelShelf;
    expect(wenku.source, SourceId.wenku8);
    expect(wenku, isNot(shelf));
    expect(wenku, CachedImageProvider(url, source: SourceId.wenku8));
  });
}
