import 'package:flutter/foundation.dart';
import 'package:wild/models/reader_document.dart';
import 'package:wild/src/rust/api/wenku8.dart' show PageStatsNovelCover;
import 'package:wild/src/rust/wenku8/models.dart';

class SourceId {
  const SourceId._(this.name, this._label);
  static const wenku8 = SourceId._('wenku8', '文库8');
  static const lightNovelShelf = SourceId._('lightNovelShelf', '轻书架');
  static const lnovel = SourceId._('lnovel', '轻小说百科');
  static const bili = SourceId._('bili', '哔哩轻小说');
  static const localEpub = SourceId._('localEpub', '本地 EPUB');
  static final _rules = <String, SourceId>{};
  final String name;
  final String _label;
  String get label => _rules[name]?._label ?? _label;
  bool get isRule => name.startsWith('rule:');
  String get ruleId => isRule ? name.substring(5) : '';
  static List<SourceId> get values => [
    wenku8,
    lightNovelShelf,
    lnovel,
    bili,
    localEpub,
    ..._rules.values,
  ];
  static SourceId rule(String id, {String? label}) =>
      SourceId._('rule:$id', label ?? '未安装书源（$id）');
  static void registerRules(Iterable<SourceId> sources) {
    _rules.clear();
    for (final source in sources) {
      _rules[source.name] = source;
    }
  }

  @override
  bool operator ==(Object other) => other is SourceId && other.name == name;
  @override
  int get hashCode => name.hashCode;
  @override
  String toString() => name;
}

/// Existing Wenku8 ids stay unchanged so installed shelves/history still work.
SourceId sourceOf(String id) {
  if (id.startsWith('epub:')) {
    if (!RegExp(r'^epub:[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('本地书籍编号无效');
    }
    return SourceId.localEpub;
  }
  if (id.startsWith('lns:')) return SourceId.lightNovelShelf;
  if (id.startsWith('lnv:')) return SourceId.lnovel;
  if (id.startsWith('bili:')) return SourceId.bili;
  if (id.startsWith('src:')) {
    final parts = id.split(':');
    if (parts.length != 3 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(parts[1]) ||
        parts[2].isEmpty) {
      throw const FormatException('书源书籍编号无效');
    }
    return SourceId.rule(parts[1]);
  }
  if (id.contains(':')) throw const FormatException('此书源尚未安装或编号无效');
  return SourceId.wenku8;
}

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
  const SourceChapter(this.content, {this.fontFamily, this.document});
  final String content;
  final String? fontFamily;
  final ReaderDocument? document;
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
