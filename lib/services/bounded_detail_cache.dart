import 'package:wild/sources/book_source.dart';

/// Successful, complete detail values only. Callers still own the returned
/// result when it is too large to retain. Published catalogues are read-only.
class BoundedDetailCache<K> {
  BoundedDetailCache({this.maxEntries = 32, this.maxWeight = 8 * 1024 * 1024})
    : assert(maxEntries >= 0),
      assert(maxWeight >= 0);
  final int maxEntries, maxWeight;
  final _entries = <K, (SourceBookDetail, int)>{};
  int _weight = 0;
  int get length => _entries.length;
  int get estimatedWeight => _weight;

  SourceBookDetail? peek(K key) => _entries[key]?.$1;
  SourceBookDetail? operator [](K key) {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry?.$1;
  }

  void operator []=(K key, SourceBookDetail value) {
    remove(key);
    final weight = detailEstimatedWeight(value);
    if (maxEntries == 0 || weight > maxWeight ~/ 2) return;
    _entries[key] = (value, weight);
    _weight += weight;
    while (_entries.length > maxEntries || _weight > maxWeight) {
      remove(_entries.keys.first);
    }
  }

  void remove(K key) {
    final removed = _entries.remove(key);
    if (removed != null) _weight -= removed.$2;
  }

  void removeWhere(bool Function(K, SourceBookDetail) predicate) {
    for (final key in _entries.keys.toList()) {
      if (predicate(key, _entries[key]!.$1)) remove(key);
    }
  }

  void clear() {
    _entries.clear();
    _weight = 0;
  }
}

/// Conservative UTF-16 payload + structural allowance, not actual heap bytes.
/// Compute once on admission; do not serialize/copy the directory to size it.
int detailEstimatedWeight(SourceBookDetail detail) {
  final info = detail.info;
  var weight = 256;
  for (final text in [
    info.title,
    info.author,
    info.status,
    info.finUpdate,
    info.imgUrl,
    info.introduce,
    info.heat,
    info.trending,
    ...info.tags,
  ]) {
    weight += 32 + text.length * 2;
  }
  for (final volume in detail.volumes) {
    weight += 128 + (volume.id.length + volume.title.length) * 2;
    for (final chapter in volume.chapters) {
      weight +=
          192 +
          (chapter.title.length +
                  chapter.aid.length +
                  chapter.cid.length +
                  chapter.url.length) *
              2;
    }
  }
  return weight;
}
