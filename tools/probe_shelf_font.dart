import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:wild/services/light_novel_shelf_service.dart';

// Read-only font diagnosis. Authorized login stays in memory; only a short
// glyph sample is saved locally, never account details or a full chapter.
Future<void> main(List<String> args) async {
  final api = LightNovelShelfService.instance;
  final listChapters = args.contains('--list-chapters');
  String? token;
  if (args.contains('--login-stdin')) {
    // Input is never echoed, logged, or stored. Credentials are used only in
    // the official login protocol, and the access token stays in memory.
    if (stdin.hasTerminal) stdin.echoMode = false;
    stderr.writeln('Waiting for authorized QA login on stdin.');
    final input = jsonDecode(stdin.readLineSync()!) as Map;
    if (stdin.hasTerminal) stdin.echoMode = true;
    final login = await http.post(
      Uri.parse('https://api.lightnovel.life/api/user/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': input['email'],
        'password':
            sha256.convert(utf8.encode(input['password'] as String)).toString(),
      }),
    );
    final data = jsonDecode(login.body) as Map;
    if ((data['success'] ?? data['Success']) != true) {
      throw StateError('QA login failed');
    }
    final response = (data['response'] ?? data['Response']) as Map;
    final refresh = response['RefreshToken'] ?? response['refreshToken'];
    final access = await http.post(
      Uri.parse('https://api.lightnovel.life/api/user/refresh_token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'token': refresh}),
    );
    final exchanged = jsonDecode(access.body);
    token =
        exchanged is String
            ? exchanged
            : (exchanged['response'] ?? exchanged['Response']) as String;
  }
  args = args.where((arg) => !arg.startsWith('--')).toList();
  final bookId =
      args.isEmpty
          ? (await api.fetchLatestBooks()).first.id
          : int.parse(args.first);
  if (listChapters) {
    Object? info = await api.invoke('GetBookInfo', {
      'Id': bookId,
    }, token: token);
    if (info is Map) info = info['Response'] ?? info['response'];
    final book = info is Map ? info['Book'] ?? info['book'] : null;
    if (book is Map) {
      final chapters = book['Chapter'] ?? book['chapter'] ?? book['Chapters'];
      stdout.writeln('QA book title: ${book['Title'] ?? book['title']}');
      if (chapters is List) {
        for (var i = 0; i < chapters.length && i < 25; i++) {
          final chapter = chapters[i];
          if (chapter is Map) {
            stdout.writeln('${i + 1}: ${chapter['Title'] ?? chapter['title']}');
          }
        }
      }
    }
  }
  Object? payload = await api.invoke('GetNovelContent', {
    'Bid': bookId,
    'SortNum': args.length > 1 ? int.parse(args[1]) : 1,
  }, token: token);
  for (var i = 0; i < 3 && payload is Map; i++) {
    if (payload.containsKey('Chapter') || payload.containsKey('chapter')) break;
    final next =
        payload['response'] ??
        payload['Response'] ??
        payload['data'] ??
        payload['Data'];
    if (next == null) break;
    payload = next;
  }
  if (payload is! Map) {
    stdout.writeln('No chapter payload: ${payload.runtimeType}');
    return;
  }
  final chapter = payload['Chapter'] ?? payload['chapter'];
  if (chapter is! Map) {
    stdout.writeln('No chapter: keys=${payload.keys.toList()}');
    return;
  }
  final font = chapter['Font'] ?? chapter['font'];
  final content = chapter['Content'] ?? chapter['content'];
  stdout.writeln(
    jsonEncode({
      'book': bookId,
      'font': font,
      'characters': content is String ? content.length : 0,
    }),
  );
  if (font is! String || font.isEmpty) return;
  final url = Uri.parse('https://api.lightnovel.life/').resolve(font);
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    request.headers.set('Referer', 'https://www.lightnovel.app/');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('font HTTP ${response.statusCode}');
    }
    final bytes = await response.fold<List<int>>(
      [],
      (result, next) => result..addAll(next),
    );
    final folder = Directory('build/font-diagnosis')
      ..createSync(recursive: true);
    await File('${folder.path}/shelf-$bookId.woff2').writeAsBytes(bytes);
    // Skip cover markup so the small sample actually contains encoded glyphs.
    // Keep only 80 text characters, never save the full chapter.
    if (content is String) {
      final sample = StringBuffer();
      void collect(dom.Node node) {
        if (node is dom.Text) sample.write(node.text);
        for (final child in node.nodes) {
          collect(child);
        }
      }

      collect(html.parseFragment(content));
      final text = sample.toString().trim();
      await File('${folder.path}/shelf-$bookId-sample.json').writeAsString(
        jsonEncode(text.substring(0, text.length < 80 ? text.length : 80)),
      );
    }
    stdout.writeln('saved font: ${bytes.length} bytes');
  } finally {
    client.close(force: true);
  }
}
