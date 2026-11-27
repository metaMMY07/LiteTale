import 'package:wild/services/reading_progress.dart';
import 'package:wild/src/rust/wenku8/models.dart';

/// The reader hands over the chapter text it has already loaded.
class ReaderListeningChapter {
  const ReaderListeningChapter({
    required this.aid,
    required this.cid,
    required this.title,
    required this.text,
    this.encoded = false,
  });

  final String aid, cid, title, text;
  final bool encoded;
}

class ReaderListeningRequest {
  const ReaderListeningRequest({
    required this.chapter,
    required this.volumes,
    required this.info,
    required this.offset,
  });

  final ReaderListeningChapter chapter;
  final List<Volume> volumes;
  final NovelInfo info;
  final int offset;

  ReadingProgress progress(ReaderListeningChapter chapter, int offset) {
    final volume =
        volumes
            .where(
              (volume) => volume.chapters.any(
                (entry) => entry.aid == chapter.aid && entry.cid == chapter.cid,
              ),
            )
            .firstOrNull;
    return ReadingProgress(
      bookId: chapter.aid,
      title: info.title,
      volumeId: volume?.id ?? '',
      volumeTitle: volume?.title ?? '',
      chapterId: chapter.cid,
      chapterTitle: chapter.title,
      characters: offset,
      page: scrollReaderProgressPage,
      cover: info.imgUrl,
      author: info.author,
    );
  }
}
