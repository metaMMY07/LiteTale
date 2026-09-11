import 'package:flutter/foundation.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

enum SourceId {
  wenku8('文库8'),
  lightNovelShelf('轻书架');

  const SourceId(this.label);
  final String label;
}

/// Existing Wenku8 ids stay unchanged so installed shelves/history still work.
SourceId sourceOf(String id) =>
    id.startsWith('lns:') ? SourceId.lightNovelShelf : SourceId.wenku8;
String shelfBookId(Object id) => 'lns:$id';
int remoteShelfId(String id) {
  final match = RegExp(r'^lns:(\d+)$').firstMatch(id);
  if (match == null) throw const FormatException('无效的轻书架书籍编号');
  return int.parse(match.group(1)!);
}

class SourceBookDetail {
  const SourceBookDetail(this.info, this.volumes);
  final NovelInfo info;
  final List<Volume> volumes;
}

class SourceChapter {
  const SourceChapter(this.content, {this.fontFamily});
  final String content;
  final String? fontFamily;
}

abstract class BookSource {
  SourceId get id;
  Future<List<HomeBlock>> discover();
  Future<PageStatsNovelCover> search(String keyword, String type, int page);
  Future<SourceBookDetail> detail(String bookId);
  Future<SourceChapter> chapter(String bookId, String chapterId);
}

/// Source selection changes discovery only. Open books retain their own source.
final activeSource = ValueNotifier<SourceId>(SourceId.wenku8);
final sourceRevision = ValueNotifier<int>(0);
