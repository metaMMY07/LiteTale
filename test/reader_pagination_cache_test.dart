import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_pagination_cache.dart';
import 'package:wild/settings/settings_preferences.dart' show readerHanLocale;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalHanLocale = readerHanLocale;

  setUp(() => readerHanLocale = null);
  tearDown(() => readerHanLocale = originalHanLocale);

  test('exact hit skips compute, returns the same immutable list', () {
    var computes = 0;
    final cache = ReaderPaginationCache(
      compute: (input) {
        computes++;
        return [ReaderPage(content: input.content, isImage: false)];
      },
    );

    final first = _paginate(cache);
    final second = _paginate(cache);

    expect(computes, 1);
    expect(identical(first, second), isTrue);
    expect(
      () => first.add(const ReaderPage(content: 'x', isImage: false)),
      throwsUnsupportedError,
    );
  });

  test(
    'source, chapter, content, typography, viewport and locale invalidate',
    () {
      var computes = 0;
      final cache = ReaderPaginationCache(
        maxEntries: 64,
        compute: (input) {
          computes++;
          return [ReaderPage(content: input.content, isImage: false)];
        },
      );

      _paginate(cache);
      _paginate(cache, sourceId: 'lnovel');
      _paginate(cache, bookId: 'other-book');
      _paginate(cache, chapterId: 'chapter-2');
      _paginate(cache, sessionGeneration: 1);
      _paginate(cache, content: 'different text');
      _paginate(cache, fontFamily: 'ImportedFont:sha256-a');
      _paginate(cache, fontSize: 20);
      _paginate(cache, paragraphSpacing: 12);
      _paginate(cache, lineHeight: 1.8);
      _paginate(cache, canvasWidth: 301);
      _paginate(cache, canvasHeight: 501);
      // Rotation changes both effective dimensions and must miss.
      _paginate(cache, canvasWidth: 500, canvasHeight: 300);
      _paginate(cache, boldText: true);
      _paginate(cache, algorithmVersion: readerPaginationAlgorithmVersion + 1);
      readerHanLocale = const Locale('zh', 'CN');
      _paginate(cache);
      readerHanLocale = const Locale('zh', 'TW');
      _paginate(cache);

      expect(computes, 17);
    },
  );

  test('TextScaler identity/value is keyed without sampling scale(1)', () {
    var computes = 0;
    final cache = ReaderPaginationCache(
      compute: (input) {
        computes++;
        return [ReaderPage(content: input.content, isImage: false)];
      },
    );
    const firstCurve = _ThresholdScaler(0.2);
    const secondCurve = _ThresholdScaler(0.5);
    expect(firstCurve.scale(1), secondCurve.scale(1));
    expect(firstCurve.scale(20), isNot(secondCurve.scale(20)));

    _paginate(cache, textScaler: firstCurve);
    _paginate(cache, textScaler: firstCurve);
    _paginate(cache, textScaler: secondCurve);

    expect(computes, 2);
  });

  test(
    'LRU evicts least-recently-used entry within aggregate code-unit cap',
    () {
      var computes = 0;
      final cache = ReaderPaginationCache(
        maxEntries: 3,
        maxRetainedCodeUnits: 6,
        compute: (input) {
          computes++;
          return [ReaderPage(content: input.content, isImage: false)];
        },
      );

      _paginate(cache, chapterId: 'a', content: 'a');
      _paginate(cache, chapterId: 'b', content: 'b');
      _paginate(cache, chapterId: 'a', content: 'a'); // promote a
      _paginate(cache, chapterId: 'c', content: 'c');
      expect(cache.retainedCodeUnits, 6);
      _paginate(cache, chapterId: 'd', content: 'd'); // evict b at the cap
      expect(cache.length, 3);
      expect(cache.retainedCodeUnits, 6);
      _paginate(cache, chapterId: 'b', content: 'b'); // b must be recomputed

      expect(computes, 5);
    },
  );

  test('chapter over the cap is paginated but never retained', () {
    var computes = 0;
    final cache = ReaderPaginationCache(
      maxRetainedCodeUnits: 8,
      compute: (input) {
        computes++;
        return [const ReaderPage(content: '1234', isImage: false)];
      },
    );

    final first = _paginate(cache, content: '12345'); // 5 input + 4 output
    final second = _paginate(cache, content: '12345');

    expect(computes, 2);
    expect(cache.length, 0);
    expect(cache.retainedCodeUnits, 0);
    expect(identical(first, second), isFalse);
    expect(
      () => first.add(const ReaderPage(content: 'x', isImage: false)),
      throwsUnsupportedError,
    );
  });

  test('local long-chapter cold/hot sample reuses pagination result', () {
    final cache = ReaderPaginationCache();
    final content = List<String>.filled(
      240,
      '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。寒来暑往，秋收冬藏。',
    ).join('\n');
    final coldWatch = Stopwatch()..start();
    final cold = _paginate(cache, content: content);
    coldWatch.stop();
    final hotWatch = Stopwatch()..start();
    final hot = _paginate(cache, content: content);
    hotWatch.stop();

    expect(identical(cold, hot), isTrue);
    // Informational local test data only; this is not a device/frame target.
    // ignore: avoid_print
    print(
      'local pagination sample: chars=${content.length}, pages=${cold.length}, '
      'cold=${coldWatch.elapsedMicroseconds}us, hot=${hotWatch.elapsedMicroseconds}us',
    );
  });
}

List<ReaderPage> _paginate(
  ReaderPaginationCache cache, {
  String sourceId = 'wenku8',
  String bookId = 'lns:1',
  String chapterId = 'chapter-1',
  int sessionGeneration = 0,
  String content = '天地玄黄宇宙洪荒',
  double canvasWidth = 300,
  double canvasHeight = 500,
  double fontSize = 18,
  double paragraphSpacing = 8,
  double lineHeight = 1.6,
  String? fontFamily,
  TextScaler textScaler = TextScaler.noScaling,
  bool boldText = false,
  int algorithmVersion = readerPaginationAlgorithmVersion,
}) => cache.paginate(
  sourceId: sourceId,
  bookId: bookId,
  chapterId: chapterId,
  sessionGeneration: sessionGeneration,
  content: content,
  canvasWidth: canvasWidth,
  canvasHeight: canvasHeight,
  fontSize: fontSize,
  paragraphSpacing: paragraphSpacing,
  lineHeight: lineHeight,
  fontFamily: fontFamily,
  textScaler: textScaler,
  boldText: boldText,
  algorithmVersion: algorithmVersion,
);

class _ThresholdScaler extends TextScaler {
  const _ThresholdScaler(this.extraPerPixelAboveThreshold);

  final double extraPerPixelAboveThreshold;

  @override
  double scale(double fontSize) =>
      fontSize +
      (fontSize > 10 ? (fontSize - 10) * extraPerPixelAboveThreshold : 0);

  @override
  double get textScaleFactor => 1;
}
