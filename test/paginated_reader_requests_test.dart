import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/services/reader_position.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const info = NovelInfo(
  title: '书',
  author: '',
  status: '',
  finUpdate: '',
  imgUrl: '',
  introduce: '',
  tags: [],
  heat: '',
  trending: '',
  isAnimated: false,
);
const volumes = [
  Volume(
    id: 'v',
    title: '卷',
    chapters: [
      Chapter(title: '甲', url: '', aid: 'lns:1', cid: 'a'),
      Chapter(title: '乙', url: '', aid: 'lns:1', cid: 'b'),
    ],
  ),
];

ReaderCubit reader(
  Future<SourceChapter> Function({required String aid, required String cid})
  read,
  ReadingProgressQueue queue, {
  int Function(String)? session,
  Future<ReaderPosition?> Function(String, String)? loadPosition,
  String bookId = 'lns:1',
  List<Volume> chapterVolumes = volumes,
}) => ReaderCubit(
  novelInfo: info,
  initialAid: bookId,
  initialCid: 'a',
  initialVolumes: chapterVolumes,
  fontSizeCubit: FontSizeCubit(),
  paragraphSpacingCubit: ParagraphSpacingCubit(),
  lineHeightCubit: LineHeightCubit(),
  topBarHeightCubit: TopBarHeightCubit(),
  bottomBarHeightCubit: BottomBarHeightCubit(),
  leftPaddingCubit: LeftPaddingCubit(),
  rightPaddingCubit: RightPaddingCubit(),
  fontSettingsCubit: FontSettingsCubit(),
  read: read,
  progress: queue,
  sessionGeneration: session ?? (_) => 0,
  loadPosition: loadPosition,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('paginated body appears without waiting for progress storage', () async {
    final gate = Completer<void>();
    final queue = ReadingProgressQueue(write: (_) => gate.future);
    final cubit = reader(
      ({required aid, required cid}) async => const SourceChapter('正文'),
      queue,
    );
    await cubit.loadChapter();
    expect(cubit.state, isA<ReaderLoaded>());
    gate.complete();
    await cubit.close();
  });

  test(
    'late paginated response cannot overwrite chapter or paired font',
    () async {
      final old = Completer<SourceChapter>();
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      final cubit = reader(
        ({required aid, required cid}) =>
            cid == 'a'
                ? old.future
                : Future.value(
                  const SourceChapter('最新正文', fontFamily: 'source-B'),
                ),
        queue,
      );
      final pending = cubit.loadChapter();
      await cubit.loadChapter(cid: 'b');
      old.complete(const SourceChapter('旧正文', fontFamily: 'source-A'));
      await pending;
      expect((cubit.state as ReaderLoaded).cid, 'b');
      expect((cubit.state as ReaderLoaded).fontFamily, 'source-B');
      await queue.flush();
      expect(saved.map((p) => p.chapterId), ['b']);
      await cubit.close();
    },
  );

  test(
    'account replacement masks late failure and saves no old position',
    () async {
      var generation = 0;
      final old = Completer<SourceChapter>();
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(write: (p) async => saved.add(p));
      final cubit = reader(
        ({required aid, required cid}) => old.future,
        queue,
        session: (_) => generation,
      );
      final pending = cubit.loadChapter();
      generation++;
      old.completeError(StateError('old account timeout'));
      await pending;
      expect((cubit.state as ReaderError).error, contains('账号已变化'));
      expect(
        (cubit.state as ReaderError).error,
        isNot(contains('old account')),
      );
      await queue.flush();
      expect(saved, isEmpty);
      await cubit.close();
    },
  );
}
