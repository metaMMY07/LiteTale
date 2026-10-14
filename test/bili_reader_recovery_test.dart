import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/html_reader_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/novel_info_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';

const book = NovelInfo(
  title: 'SeaBed',
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
    id: 'bili:1:v:1',
    title: '卷',
    chapters: [Chapter(title: '甲', url: '', aid: 'bili:1', cid: 'bili:1:2')],
  ),
];
typedef Read =
    Future<SourceChapter> Function({required String aid, required String cid});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSource = activeSource.value,
      originalRevision = sourceRevision.value;
  setUp(() {
    activeSource.value = SourceId.bili;
    sourceRevision.value = 900;
  });
  tearDown(() {
    activeSource.value = originalSource;
    sourceRevision.value = originalRevision;
  });

  BiliSiteVerificationRequired challenge() => BiliSiteVerificationRequired(
    target: Uri.parse('https://www.linovelib.com/novel/1/2.html'),
    kind: BiliProbeKind.chapter,
    revision: 900,
    desktopSite: true,
  );
  dynamic reader(bool paginated, Read read, ReadingProgressQueue progress) =>
      paginated
          ? ReaderCubit(
            novelInfo: book,
            initialAid: 'bili:1',
            initialCid: 'bili:1:2',
            initialVolumes: volumes,
            fontSizeCubit: FontSizeCubit(),
            paragraphSpacingCubit: ParagraphSpacingCubit(),
            lineHeightCubit: LineHeightCubit(),
            topBarHeightCubit: TopBarHeightCubit(),
            bottomBarHeightCubit: BottomBarHeightCubit(),
            leftPaddingCubit: LeftPaddingCubit(),
            rightPaddingCubit: RightPaddingCubit(),
            fontSettingsCubit: FontSettingsCubit(),
            read: read,
            progress: progress,
            sessionGeneration: (_) => 0,
          )
          : HtmlReaderCubit(
            novelInfo: book,
            initialAid: 'bili:1',
            initialCid: 'bili:1:2',
            initialVolumes: volumes,
            read: read,
            progress: progress,
            sessionGeneration: (_) => 0,
          );

  for (final paginated in [true, false]) {
    final kind = paginated ? 'paginated' : 'scroll';
    test(
      '$kind keeps typed cause and retries the same requested chapter',
      () async {
        final error = challenge();
        final requests = <String>[];
        final progress = ReadingProgressQueue(write: (_) async {});
        final cubit = reader(paginated, ({required aid, required cid}) async {
          requests.add('$aid/$cid');
          if (requests.length == 1) throw error;
          return const SourceChapter('已验证正文');
        }, progress);
        addTearDown(() => cubit.close());
        await cubit.loadChapter();
        expect(cubit.state.cause, same(error));
        await cubit.loadChapter();
        expect(requests, ['bili:1/bili:1:2', 'bili:1/bili:1:2']);
        expect(
          cubit.state,
          paginated ? isA<ReaderLoaded>() : isA<HtmlReaderLoaded>(),
        );
      },
    );
    for (final change in ['source', 'revision']) {
      for (final failed in [false, true]) {
        test(
          '$kind discards old ${failed ? 'failure' : 'success'} after $change changes',
          () async {
            final response = Completer<SourceChapter>();
            final saved = <ReadingProgress>[];
            final progress = ReadingProgressQueue(
              write: (p) async => saved.add(p),
            );
            final cubit = reader(
              paginated,
              ({required aid, required cid}) => response.future,
              progress,
            );
            addTearDown(() => cubit.close());
            final pending = cubit.loadChapter();
            final loading = cubit.state;
            if (change == 'source') {
              activeSource.value = SourceId.wenku8;
            } else {
              sourceRevision.value++;
            }
            if (failed) {
              response.completeError(challenge());
            } else {
              response.complete(const SourceChapter('旧响应'));
            }
            await pending;
            expect(cubit.state, same(loading));
            await progress.flush();
            expect(saved, isEmpty);
          },
        );
      }
    }
  }
  for (final change in ['source', 'revision']) {
    for (final failed in [false, true]) {
      test(
        'detail discards old ${failed ? 'failure' : 'success'} after $change changes',
        () async {
          final response = Completer<NovelInfo>();
          var followUps = 0;
          final cubit = NovelInfoCubit(
            'bili:1',
            loadInfo: ({required aid}) => response.future,
            loadVolumes: ({required aid}) async {
              followUps++;
              return volumes;
            },
            loadHistory: ({required novelId}) async {
              followUps++;
              return null;
            },
          );
          addTearDown(cubit.close);
          final pending = cubit.load();
          final loading = cubit.state;
          if (change == 'source') {
            activeSource.value = SourceId.wenku8;
          } else {
            sourceRevision.value++;
          }
          if (failed) {
            response.completeError(challenge());
          } else {
            response.complete(book);
          }
          await pending;
          expect(cubit.state, same(loading));
          expect(followUps, 0);
        },
      );
    }
  }
}
