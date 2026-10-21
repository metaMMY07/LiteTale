import 'dart:convert';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/src/rust/wenku8/models.dart';

class Wenku8BookshelfSnapshot {
  const Wenku8BookshelfSnapshot(this.caseId, this.bookcases, this.content);
  final String caseId;
  final List<Bookcase> bookcases;
  final BookcaseDto content;
}

/// Only shelf rows and group labels leave the browser; no account controls.
String wenku8BookshelfScript(String host, String caseId) => '''
(function(host, caseId) {
  var result={url:location.href,caseId:caseId,groups:[],items:[],tip:''};
  if(location.origin!==host || location.pathname!=='/modules/article/bookcase.php' ||
     location.search!=='?classid='+caseId || location.hash) return null;
  var select=document.querySelector('select[name="classlist"]');
  if(!select) return null;
  result.groups=Array.from(select.options).slice(0,101).map(function(o){
    return {id:o.value,title:(o.textContent || '').trim().slice(0,160)};
  });
  var rows=Array.from(document.querySelectorAll('td.odd>input[type="checkbox"]'));
  if(rows.length>500) return null;
  function link(node, name) {
    if(!node) return '';
    try {
      var url=new URL(node.getAttribute('href') || '',location.href);
      if(url.origin!==host || url.username || url.password || url.hash) return '';
      if(['aid','bid'].includes(name) && !['/modules/article/readbookcase.php','/modules/article/articleinfo.php'].includes(url.pathname)) return '';
      if(name==='cid' && !['/modules/article/readbookcase.php','/modules/article/reader.php'].includes(url.pathname)) return '';
      return url.searchParams.get(name) || '';
    } catch(_) {return '';}
  }
  rows.forEach(function(input){
    var row=input.closest('tr'), cells=row ? row.querySelectorAll('td') : [];
    if(cells.length<4) return;
    var book=cells[1].querySelector('a'), chapter=cells[3].querySelector('a');
    result.items.push({aid:link(book,'aid'),bid:link(book,'bid') || input.value,
      title:(book ? book.textContent : '').trim().slice(0,300),
      author:(cells[2].textContent || '').trim().slice(0,160),
      cid:link(chapter,'cid'),chapterName:(chapter ? chapter.textContent : '').trim().slice(0,300)});
  });
  var tip=document.querySelector('caption');
  result.tip=(tip ? tip.textContent : '').trim().slice(0,1024);
  return JSON.stringify(result);
})(${jsonEncode(host)},${jsonEncode(caseId)})
''';

Wenku8BookshelfSnapshot parseWenku8Bookshelf(
  Object? raw,
  String host,
  String caseId,
) {
  if (raw is String && raw.length <= 512 * 1024) raw = jsonDecode(raw);
  final expected =
      '${normalizeWenku8Host(host)}/modules/article/bookcase.php?classid=$caseId';
  if (raw is! Map ||
      raw['url'] != expected ||
      raw['caseId'] != caseId ||
      raw['groups'] is! List ||
      raw['items'] is! List) {
    throw const FormatException('文库8书架格式已变化，请重试。');
  }
  String field(Map value, String name, int max, {bool digits = false}) {
    final text = value[name];
    if (text is! String ||
        text.length > max ||
        (digits && !RegExp(r'^\d{1,12}$').hasMatch(text))) {
      throw const FormatException('文库8书架字段无效。');
    }
    return text;
  }

  final groups = raw['groups'] as List, items = raw['items'] as List;
  if (groups.isEmpty || groups.length > 100 || items.length > 500) {
    throw const FormatException('文库8书架数据超出限制。');
  }
  final bookcases = groups
      .map((g) {
        if (g is! Map) throw const FormatException('文库8书架分组无效。');
        return Bookcase(
          id: field(g, 'id', 12, digits: true),
          title: field(g, 'title', 160),
        );
      })
      .toList(growable: false);
  if (!bookcases.any((b) => b.id == caseId) ||
      bookcases.map((b) => b.id).toSet().length != bookcases.length) {
    throw const FormatException('文库8书架分组不匹配。');
  }
  return Wenku8BookshelfSnapshot(
    caseId,
    List.unmodifiable(bookcases),
    BookcaseDto(
      tip: field(raw, 'tip', 1024),
      items: List.unmodifiable(
        items.map((item) {
          if (item is! Map) throw const FormatException('文库8书架书籍无效。');
          final cid = field(item, 'cid', 12);
          if (cid.isNotEmpty && !RegExp(r'^\d{1,12}$').hasMatch(cid)) {
            throw const FormatException('文库8书架章节无效。');
          }
          return BookcaseItem(
            aid: field(item, 'aid', 12, digits: true),
            bid: field(item, 'bid', 12, digits: true),
            title: field(item, 'title', 300),
            author: field(item, 'author', 160),
            cid: cid,
            chapterName: field(item, 'chapterName', 300),
          );
        }),
      ),
    ),
  );
}
