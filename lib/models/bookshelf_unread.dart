import 'package:wild/src/rust/wenku8/models.dart';

/// Counts chapters after the current reading position in a known catalog.
/// A missing or ambiguous position cannot establish a count.
int? unreadChapters(List<Volume> volumes, String bookId, String? chapterId) {
  final chapterIds = <String>{};
  int? currentIndex;
  for (final volume in volumes) {
    for (final chapter in volume.chapters) {
      if (chapter.aid != bookId ||
          chapter.cid.isEmpty ||
          !chapterIds.add(chapter.cid)) {
        return null;
      }
      if (chapter.cid == chapterId) currentIndex = chapterIds.length - 1;
    }
  }
  if (chapterIds.isEmpty) return null;
  if (chapterId == null) return chapterIds.length;
  if (currentIndex == null) return null;
  return chapterIds.length - currentIndex - 1;
}
