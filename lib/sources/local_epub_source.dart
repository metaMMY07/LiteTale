import 'dart:convert';

import 'package:wild/services/epub/epub_models.dart';
import 'package:wild/services/epub/local_epub_library.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

import 'book_source.dart';

/// A private library adapter; never selected as an online discovery source.
class LocalEpubSource implements BookSource {
  LocalEpubSource({LocalEpubLibrary? library})
    : library = library ?? LocalEpubLibrary.instance;

  final LocalEpubLibrary library;
  @override
  SourceId get id => SourceId.localEpub;

  @override
  Future<List<HomeBlock>> discover() async => const [];

  @override
  Future<PageStatsNovelCover> search(String keyword, String type, int page) =>
      Future.error(const EpubImportException('请在本地书籍中查找已导入的 EPUB'));

  @override
  Future<SourceBookDetail> detail(String bookId) async {
    final book = library.book(bookId);
    if (book == null) throw const EpubImportException('这本 EPUB 已移除，请重新导入');
    final imported = DateTime.fromMillisecondsSinceEpoch(book.importedAtMs);
    return SourceBookDetail(
      NovelInfo(
        title: book.title,
        author: book.author,
        status: '本地书籍 · 已离线保存',
        finUpdate:
            '${imported.year}-${imported.month.toString().padLeft(2, '0')}-${imported.day.toString().padLeft(2, '0')}',
        imgUrl: book.coverUrl,
        introduce: const HtmlEscape()
            .convert(book.description)
            .replaceAll('\n', '<br>'),
        tags: ['EPUB', ...book.subjects],
        heat: '',
        trending: '',
        isAnimated: false,
      ),
      [
        Volume(
          id: 'epub:${book.digest}:contents',
          title: '目录',
          chapters: [
            for (var i = 0; i < book.chapters.length; i++)
              Chapter(
                title: book.chapters[i].title,
                url: '',
                cid: book.chapterId(i),
                aid: book.id,
              ),
          ],
        ),
      ],
    );
  }

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async =>
      SourceChapter(await library.chapter(bookId, chapterId));
}
