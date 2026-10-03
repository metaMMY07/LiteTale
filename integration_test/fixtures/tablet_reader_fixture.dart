import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/theme/imported_font_theme.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_page.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/src/rust/api/system.dart' as system;
import 'package:wild/methods.dart' show dataRoot;
import 'package:wild/src/rust/wenku8/models.dart';

const _aid = 'lnv:tablet-qa';
const _info = NovelInfo(
  title: '双页阅读测试',
  author: '本地测试',
  status: '',
  finUpdate: '',
  imgUrl: '',
  introduce: '',
  tags: [],
  heat: '',
  trending: '',
  isAnimated: false,
);
final _volumes = [
  Volume(
    id: _aid,
    title: '第一卷',
    chapters: [Chapter(aid: _aid, cid: '1', title: '第一章「潮味未至」①', url: '')],
  ),
];

class _TabletSource implements BookSource {
  @override
  SourceId get id => SourceId.lnovel;
  @override
  Future<List<HomeBlock>> discover() async => [];
  @override
  Future<api.PageStatsNovelCover> search(
    String key,
    String type,
    int page,
  ) async =>
      const api.PageStatsNovelCover(currentPage: 1, maxPage: 1, records: []);
  @override
  Future<SourceBookDetail> detail(String bookId) async =>
      SourceBookDetail(_info, _volumes);
  @override
  Future<SourceChapter> chapter(
    String bookId,
    String chapterId,
  ) async => SourceChapter(
    List.generate(
      70,
      (i) =>
          '　　第$i段。川凛每天晚上出去溜达，从今往后我就得继续陪她。要陪她做的事，倒也不算出格。${i % 3 == 0 ? '兽耳无力地下垂。耳朵下面的脸孔也挂着痛苦的表情唉声叹气。' : ''}\n'
          '　　这项运动还算简单，但碰上艳阳天就会汗涔涔。我用手帕擦了擦发际，心想，去教室前还是先检查一下妆花没花吧。\n'
          '　　「但这种还挺不错的啊！」\n　　「嗯。是挺不错」${i % 4 == 0 ? '\n　　「您抱着断气的苏菲亚来到地下神殿，为了让苏菲亚死而复生成为第一个《女武神》。 」' : ''}',
    ).join('\n'),
  );
}

Future<Widget> createTabletReaderFixture({FontSettingsCubit? fonts}) async {
  await RustLib.init();
  await system.init(root: await dataRoot());
  api.bookSources[SourceId.lnovel] = _TabletSource();
  // Start with visible system bars: production ReaderSystemUiScope must hide
  // them, rather than letting the fixture mask an immersive-mode regression.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  final curl = ReaderCurlCubit(read: () async => 'true', write: (_) async {});
  await curl.setEnabled(true);
  final theme = ThemeCubit();
  await theme.setThemeMode(ReaderThemeMode.dark);
  return MultiBlocProvider(
    providers: [
      if (fonts == null)
        BlocProvider(create: (_) => FontSettingsCubit())
      else
        BlocProvider.value(value: fonts),
      BlocProvider(create: (_) => FontSizeCubit()),
      BlocProvider(create: (_) => ParagraphSpacingCubit()),
      BlocProvider(create: (_) => LineHeightCubit()),
      BlocProvider(create: (_) => TopBarHeightCubit()),
      BlocProvider(create: (_) => BottomBarHeightCubit()),
      BlocProvider(create: (_) => LeftPaddingCubit()),
      BlocProvider(create: (_) => RightPaddingCubit()),
      BlocProvider(create: (_) => ReaderTypeCubit()),
      BlocProvider(create: (_) => ReaderBackgroundCubit()),
      BlocProvider(create: (_) => VolumeControlCubit()),
      BlocProvider.value(value: curl),
      BlocProvider.value(value: theme),
    ],
    child: Builder(
      builder:
          (context) => MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: applyImportedAppFont(
              materialYouTheme(Brightness.dark),
              context.select(
                (FontSettingsCubit cubit) => cubit.state.appFamily,
              ),
            ),
            debugShowCheckedModeBanner: false,
            home: ReaderPage(
              key: const ValueKey('tablet-reader'),
              aid: _aid,
              cid: '1',
              initialTitle: '双页阅读测试',
              volumes: _volumes,
              novelInfo: _info,
              initialPage: 2,
            ),
          ),
    ),
  );
}
