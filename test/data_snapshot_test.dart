import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/settings/data_snapshot.dart';

late Uint8List _fontBytes;
late Uint8List _paperBytes;
late String _fontDigest;

void main() {
  setUpAll(() async {
    _fontBytes =
        await File('lib/assets/fonts/LXGWNeoZhiSongPlus.ttf').readAsBytes();
    _fontDigest = sha256.convert(_fontBytes).toString();
    _paperBytes = await File('lib/assets/startup.png').readAsBytes();
  });

  test('build obeys selected domains and reads only requested data', () async {
    final calls = <(bool, bool, bool)>[];
    final service = DataSnapshotService(
      root: Directory.systemTemp.path,
      read: (bookshelves, reading, settings) async {
        calls.add((bookshelves, reading, settings));
        final snapshot = _baseSnapshot(includeSettings: false);
        if (!bookshelves) snapshot.remove('bookshelves');
        if (!reading) snapshot.remove('reading');
        return jsonEncode(snapshot);
      },
      inspect: (_) async => '{}',
    );

    final document = await service.build(
      bookshelves: false,
      reading: true,
      settings: false,
    );

    expect(calls, [(false, true, false)]);
    expect(document.hasBookshelves, isFalse);
    expect(document.hasReading, isTrue);
    expect(document.hasSettings, isFalse);
    expect(document.historyCount, 1);
    expect(document.eventCount, 1);
  });

  test(
    'settings export carries selected font and paper bytes portably',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'litetale_snapshot_source_',
      );
      final fonts = Directory('${root.path}/imported_fonts');
      await fonts.create(recursive: true);
      await File('${fonts.path}/$_fontDigest.ttf').writeAsBytes(_fontBytes);
      await File(
        '${root.path}/light_reader_background.png',
      ).writeAsBytes(_paperBytes);

      final service = DataSnapshotService(
        root: root.path,
        read: (bookshelves, reading, settings) async {
          final snapshot = _baseSnapshot();
          if (!bookshelves) snapshot.remove('bookshelves');
          if (!reading) snapshot.remove('reading');
          if (!settings) snapshot.remove('settings');
          return jsonEncode(snapshot);
        },
        inspect: (_) async => '{}',
      );

      final document = await service.build(
        bookshelves: false,
        reading: false,
        settings: true,
      );
      final media = document.data['settings']['media']['files'] as Map;
      final parsed = await service.parse(document.json);

      expect(document.hasBookshelves, isFalse);
      expect(document.hasReading, isFalse);
      expect(document.hasSettings, isTrue);
      expect(media['$_fontDigest.ttf'], base64Encode(_fontBytes));
      expect(media['light_reader_background.png'], base64Encode(_paperBytes));
      expect(parsed.data['settings']['properties']['font_size'], '22');
      expect(document.warnings, isEmpty);
    },
  );

  test(
    'missing selected font is reported and does not enter the snapshot',
    () async {
      final service = DataSnapshotService(
        root: Directory.systemTemp.path,
        read: (_, _, _) async => jsonEncode(_baseSnapshot()),
        inspect: (_) async => '{}',
      );

      final document = await service.build(
        bookshelves: false,
        reading: false,
        settings: true,
      );

      final props = document.data['settings']['properties'] as Map;
      final fontSettings =
          jsonDecode(props['litetale.font_settings_v1']) as Map;
      expect(fontSettings['app'], isNull);
      expect(document.warnings, contains(contains('缺失')));
    },
  );

  test(
    'restore writes digest paths first and forwards merge/overwrite choice',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'litetale_snapshot_restore_',
      );
      final oldPaper = Uint8List.fromList([1, 2, 3, 4]);
      await File(
        '${root.path}/light_reader_background.png',
      ).writeAsBytes(oldPaper);
      final fonts = Directory('${root.path}/imported_fonts');
      await fonts.create(recursive: true);
      final oldFontName = '${String.fromCharCodes(List.filled(64, 97))}.otf';
      final oldFont = File('${fonts.path}/$oldFontName');
      await oldFont.writeAsBytes([9, 8, 7]);
      final calls = <(String, bool)>[];
      final service = DataSnapshotService(
        root: root.path,
        write: (json, overwrite) async {
          calls.add((json, overwrite));
          return '{"ok":true}';
        },
        inspect: (_) async => '{}',
      );
      final raw = jsonEncode(_baseSnapshot());
      final document = await service.parse(raw);

      await service.restore(document, overwrite: false);
      await service.restore(document, overwrite: true);

      expect(calls.map((call) => call.$2), [false, true]);
      expect(
        await File('${fonts.path}/$_fontDigest.ttf').readAsBytes(),
        _fontBytes,
      );
      expect(await oldFont.readAsBytes(), [9, 8, 7]);
      expect(
        await File('${root.path}/light_reader_background.png').readAsBytes(),
        oldPaper,
      );
      final importedPaperPath = 'snapshot_${sha256.convert(_paperBytes)}.png';
      expect(
        await File('${root.path}/$importedPaperPath').readAsBytes(),
        _paperBytes,
      );
      final firstImport = jsonDecode(calls.first.$1) as Map;
      final paper =
          jsonDecode(
                firstImport['settings']['properties']['reader_background_v1'],
              )
              as Map;
      expect(paper['lightFile'], importedPaperPath);
      final lastImport = jsonDecode(calls.last.$1) as Map;
      expect(
        jsonDecode(
          lastImport['settings']['properties']['reader_background_v1'],
        ),
        paper,
      );
    },
  );

  test(
    'bad schema, credential keys, base64, digest and image dimensions fail before write',
    () async {
      var writes = 0;
      final service = DataSnapshotService(
        root: Directory.systemTemp.path,
        write: (_, _) async {
          writes++;
          return '{}';
        },
        inspect: (_) async => '{}',
      );

      final wrongFormat = _baseSnapshot()..['format'] = 'lnr';
      await expectLater(
        service.parse(jsonEncode(wrongFormat)),
        throwsA(isA<FormatException>()),
      );
      final credential = _baseSnapshot();
      credential['settings']['properties']['token'] = 'must-not-import';
      await expectLater(
        service.parse(jsonEncode(credential)),
        throwsA(isA<FormatException>()),
      );
      final badBase64 = _baseSnapshot();
      badBase64['settings']['media']['files']['light_reader_background.png'] =
          '%%%';
      await expectLater(
        service.parse(jsonEncode(badBase64)),
        throwsA(isA<FormatException>()),
      );
      final badDigest = _baseSnapshot();
      final files = badDigest['settings']['media']['files'] as Map;
      files.remove('$_fontDigest.ttf');
      files['${'0' * 64}.ttf'] = base64Encode(_fontBytes);
      final fontSettings =
          jsonDecode(
                badDigest['settings']['properties']['litetale.font_settings_v1'],
              )
              as Map;
      fontSettings['app']['digest'] = '0' * 64;
      badDigest['settings']['properties']['litetale.font_settings_v1'] =
          jsonEncode(fontSettings);
      await expectLater(
        service.parse(jsonEncode(badDigest)),
        throwsA(isA<FormatException>()),
      );
      final oversizedImage = _baseSnapshot();
      oversizedImage['settings']['media']['files']['light_reader_background.png'] =
          base64Encode(_paperWithDimensions(6000, 5000));
      await expectLater(
        service.parse(jsonEncode(oversizedImage)),
        throwsA(isA<FormatException>()),
      );
      expect(writes, 0);
    },
  );

  test('paper references require matching snapshot media', () async {
    final service = DataSnapshotService(
      root: Directory.systemTemp.path,
      inspect: (_) async => '{}',
    );

    final missingPaper = _baseSnapshot();
    (missingPaper['settings']['media']['files'] as Map)
        .remove('light_reader_background.png');
    await expectLater(
      service.parse(jsonEncode(missingPaper)),
      throwsA(isA<FormatException>()),
    );

    final wrongPaperDigest = _baseSnapshot();
    final paper = jsonDecode(
      wrongPaperDigest['settings']['properties']['reader_background_v1'],
    ) as Map;
    paper['lightFile'] = 'snapshot_${'0' * 64}.png';
    wrongPaperDigest['settings']['properties']['reader_background_v1'] =
        jsonEncode(paper);
    await expectLater(
      service.parse(jsonEncode(wrongPaperDigest)),
      throwsA(isA<FormatException>()),
    );
  });

  test('paper with valid PNG header but truncated image data is rejected', () async {
    final service = DataSnapshotService(
      root: Directory.systemTemp.path,
      inspect: (_) async => '{}',
    );
    final corrupt = _baseSnapshot();
    corrupt['settings']['media']['files']['light_reader_background.png'] =
        base64Encode(_paperWithDimensions(1, 1));

    await expectLater(
      service.parse(jsonEncode(corrupt)),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'a failed reinspection leaves current paper/font files and DB selection intact',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'litetale_snapshot_reject_',
      );
      final oldPaper = Uint8List.fromList([6, 5, 4, 3]);
      await File(
        '${root.path}/light_reader_background.png',
      ).writeAsBytes(oldPaper);
      final fonts = Directory('${root.path}/imported_fonts');
      await fonts.create(recursive: true);
      final oldFontName = '${String.fromCharCodes(List.filled(64, 98))}.ttf';
      final oldFont = File('${fonts.path}/$oldFontName');
      await oldFont.writeAsBytes([3, 4, 5]);
      var inspectCount = 0;
      var writes = 0;
      final service = DataSnapshotService(
        root: root.path,
        write: (_, _) async {
          writes++;
          return '{}';
        },
        inspect: (_) async {
          inspectCount++;
          if (inspectCount > 1) {
            throw const FormatException('forced inspect failure');
          }
          return '{}';
        },
      );
      final document = await service.parse(jsonEncode(_baseSnapshot()));

      await expectLater(
        service.restore(document, overwrite: true),
        throwsA(isA<FormatException>()),
      );

      expect(writes, 0);
      expect(
        await File('${root.path}/light_reader_background.png').readAsBytes(),
        oldPaper,
      );
      expect(await oldFont.readAsBytes(), [3, 4, 5]);
      expect(await File('${fonts.path}/$_fontDigest.ttf').exists(), isFalse);
      expect(
        await File(
          '${root.path}/snapshot_${sha256.convert(_paperBytes)}.png',
        ).exists(),
        isFalse,
      );
    },
  );
}

Map<String, dynamic> _baseSnapshot({bool includeSettings = true}) {
  final result = <String, dynamic>{
    'format': 'litetale',
    'version': 1,
    'createdAt': '2026-10-02T12:00:00+08:00',
    'bookshelves': {
      'properties': {
        'litetale.lns.local_shelf': '[]',
        'litetale.lns.search_history': '[]',
        'litetale.lnovel.local_shelf': '[]',
        'litetale.lnovel.search_history': '[]',
      },
    },
    'reading': {
      'history': [
        {
          'novel_id': '42',
          'novel_name': '测试书',
          'volume_id': '1',
          'volume_name': '第一卷',
          'chapter_id': '3',
          'chapter_title': '第三章',
          'last_read_at': 1790900000000,
          'progress': 120,
          'progress_page': 5,
          'cover': '',
          'author': '作者',
        },
      ],
      'statistics': {
        'version': 1,
        'events': [
          {
            'id': 'session-1:session',
            'sessionId': 'session-1',
            'bookId': '42',
            'source': 'wenku8',
            'title': '测试书',
            'kind': 'session',
            'occurredAt': '2026-10-02T12:00:00.000',
            'seconds': 0,
          },
        ],
      },
    },
  };
  if (includeSettings) {
    result['settings'] = {
      'properties': {
        'font_size': '22',
        'litetale.font_settings_v1': jsonEncode({
          'version': 1,
          'app': {
            'name': 'snapshot-test.ttf',
            'digest': _fontDigest,
            'extension': 'ttf',
          },
          'reader': null,
        }),
        'litetale.settings_v1': jsonEncode({
          'version': 1,
          'autoUpdate': true,
          'updateChannel': 'stable',
          'hanVariant': 'system',
          'logLevel': 'error',
          'blackTheme': false,
          'tapToTurn': true,
          'boundaryChapters': true,
          'preventBack': false,
        }),
        'reader_background_v1': jsonEncode({
          'version': 1,
          'enabled': true,
          'opacity': 0.4,
          'builtin': false,
          'lightFile': 'light_reader_background.png',
          'darkFile': '',
        }),
      },
      'media': {
        'files': {
          '$_fontDigest.ttf': base64Encode(_fontBytes),
          'light_reader_background.png': base64Encode(_paperBytes),
        },
      },
    };
  }
  return result;
}

Uint8List _paperWithDimensions(int width, int height) {
  final bytes = Uint8List(24);
  bytes.setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width);
  data.setUint32(20, height);
  return bytes;
}
