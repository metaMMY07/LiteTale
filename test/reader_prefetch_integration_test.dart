import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/html_reader_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const _info = NovelInfo(
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
const _volumes = [
  Volume(
    id: 'v',
    title: '卷',
    chapters: [
      Chapter(title: '第一章', url: '', aid: '1', cid: '1'),
      Chapter(title: '第二章', url: '', aid: '1', cid: '2'),
    ],
  ),
];

void main() {
  testWidgets(
    'paginated reader displays first; prefetch never changes progress or chapter',
    (tester) async {
      final prefetched = <String>[];
      final saved = <ReadingProgress>[];
      final queue = ReadingProgressQueue(
        write: (p) async {
          saved.add(p);
        },
      );
      final reader = ReaderCubit(
        novelInfo: _info,
        initialAid: '1',
        initialCid: '1',
        initialVolumes: _volumes,
        fontSizeCubit: FontSizeCubit(),
        paragraphSpacingCubit: ParagraphSpacingCubit(),
        lineHeightCubit: LineHeightCubit(),
        topBarHeightCubit: TopBarHeightCubit(),
        bottomBarHeightCubit: BottomBarHeightCubit(),
        leftPaddingCubit: LeftPaddingCubit(),
        rightPaddingCubit: RightPaddingCubit(),
        fontSettingsCubit: FontSettingsCubit(),
        read:
            ({required aid, required cid}) async =>
                const SourceChapter('当前章正文'),
        sessionGeneration: (_) => 0,
        progress: queue,
        prefetch: ({required aid, required cid, required isCurrent}) async {
          prefetched.add(cid);
        },
      );
      await reader.loadChapter();
      expect(reader.state, isA<ReaderLoaded>());
      expect(prefetched, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(prefetched, ['2']);
      expect((reader.state as ReaderLoaded).cid, '1');
      await queue.flush();
      expect(saved.every((p) => p.chapterId == '1'), true);
      await reader.close();
    },
  );

  testWidgets('scroll reader prefetch is silent and stops on close', (
    tester,
  ) async {
    var calls = 0;
    final queue = ReadingProgressQueue(write: (_) async {});
    final reader = HtmlReaderCubit(
      novelInfo: _info,
      initialAid: '1',
      initialCid: '1',
      initialVolumes: _volumes,
      read:
          ({required aid, required cid}) async => const SourceChapter('当前章正文'),
      sessionGeneration: (_) => 0,
      progress: queue,
      prefetch: ({required aid, required cid, required isCurrent}) async {
        calls++;
        throw StateError('HTTP 502');
      },
    );
    await reader.loadChapter();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    expect(reader.state, isA<HtmlReaderLoaded>());
    await reader.loadChapter();
    await reader.close();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
  });
}
