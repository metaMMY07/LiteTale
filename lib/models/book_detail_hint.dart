import 'package:wild/sources/book_source.dart';

class BookDetailHint {
  const BookDetailHint({required this.title, required this.coverUrl});
  final String title, coverUrl;
  static final _items = <String, BookDetailHint>{};
  static String _key(String id) => '${sourceRevision.value}:$id';
  static BookDetailHint? lookup(String id) => _items[_key(id)];
  static void remember(String id, String title, String coverUrl) {
    final key = _key(id);
    _items.remove(key);
    _items[key] = BookDetailHint(title: title, coverUrl: coverUrl);
    while (_items.length > 256) {
      _items.remove(_items.keys.first);
    }
  }
}
