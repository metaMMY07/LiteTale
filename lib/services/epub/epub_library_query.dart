import 'epub_models.dart';
import 'local_epub_organization.dart';

List<LocalEpubBook> queryLocalEpubs(
  Iterable<LocalEpubBook> books,
  LocalEpubOrganizationStore organization, {
  String query = '',
  String? collectionId,
}) {
  final text = query.trim().toLowerCase();
  final collection = collectionId ?? organization.selectedCollection;
  final result =
      books
          .where(
            (book) =>
                (!organization.isReady ||
                    organization.matches(collection, book.id)) &&
                (text.isEmpty ||
                    '${book.title}\n${book.author}'.toLowerCase().contains(
                      text,
                    )),
          )
          .toList();
  result.sort((a, b) {
    final order = switch (organization.sort) {
      EpubLibrarySort.imported => b.importedAtMs.compareTo(a.importedAtMs),
      EpubLibrarySort.title => compareEpubTitles(a.title, b.title),
      EpubLibrarySort.author => compareEpubTitles(a.author, b.author),
      EpubLibrarySort.recent => organization
          .lastOpened(b.id)
          .compareTo(organization.lastOpened(a.id)),
    };
    if (order != 0) return order;
    final title = compareEpubTitles(a.title, b.title);
    return title != 0 ? title : a.id.compareTo(b.id);
  });
  return result;
}

/// Numeric runs compare by magnitude without int overflow (volume 2 before 10).
int compareEpubTitles(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = pattern.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  final number = RegExp(r'^\d+$');
  for (var i = 0; i < left.length && i < right.length; i++) {
    var x = left[i], y = right[i];
    int order;
    if (number.hasMatch(x) && number.hasMatch(y)) {
      x = x.replaceFirst(RegExp(r'^0+'), '');
      y = y.replaceFirst(RegExp(r'^0+'), '');
      order = x.length.compareTo(y.length);
      if (order == 0) order = x.compareTo(y);
    } else {
      order = x.compareTo(y);
    }
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}
