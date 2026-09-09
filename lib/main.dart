import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/theme/material_you.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/init_page.dart';
import 'package:wild/pages/login_page.dart';
import 'package:wild/pages/home_page.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/novel_info_page.dart';
import 'package:wild/pages/novel/novel_downloading_page.dart';
import 'package:wild/pages/novel/reader_page.dart';
import 'package:wild/pages/novel/html_reader_page.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/home/category_page.dart';
import 'package:wild/pages/articlelist/articlelist_page.dart';
import 'package:wild/pages/recommend/recommend_page.dart';
import 'package:wild/pages/home/more_page.dart';
import 'package:wild/pages/search_page.dart';
import 'package:wild/pages/home/about_page.dart';
import 'package:wild/utils/app_info.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/widgets/update_checker.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/pages/novel/left_padding_cubit.dart';
import 'package:wild/pages/novel/right_padding_cubit.dart';
import 'package:wild/pages/novel/reviews_page.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/cubits/volume_control_cubit.dart';
import 'package:wild/theme/app_fonts.dart';

final lightTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
  fontFamily: appFontFamily,
  useMaterial3: true,
);
final darkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.dark,
  ),
  fontFamily: appFontFamily,
  useMaterial3: true,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppInfo.init();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AppAccentCubit()),
        BlocProvider(create: (context) => AuthCubit()),
        BlocProvider(create: (context) => BookshelfCubit()),
        BlocProvider(create: (context) => ThemeCubit()),
        BlocProvider(create: (context) => FontSizeCubit()),
        BlocProvider(create: (context) => LineHeightCubit()),
        BlocProvider(create: (context) => ParagraphSpacingCubit()),
        BlocProvider(create: (context) => TopBarHeightCubit()),
        BlocProvider(create: (context) => BottomBarHeightCubit()),
        BlocProvider(create: (context) => LeftPaddingCubit()),
        BlocProvider(create: (context) => RightPaddingCubit()),
        BlocProvider(create: (context) => UpdateCubit()),
        BlocProvider(create: (context) => ReaderTypeCubit()..loadType()),
        BlocProvider(create: (context) => ApiHostCubit()),
        BlocProvider(create: (context) => ReaderBackgroundCubit()),
        BlocProvider(create: (context) => VolumeControlCubit()),
      ],
      child: YourApp(),
    );
  }
}

class YourApp extends StatefulWidget {
  const YourApp({super.key});

  @override
  State<YourApp> createState() => _YourAppState();
}

class _YourAppState extends State<YourApp> with WidgetsBindingObserver {
  final _dynamicColorKey = GlobalKey<DynamicColorBuilderState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && usesMaterialYou) {
      _dynamicColorKey.currentState?.initPlatformState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeCubit, ReaderTheme>(
      builder: (context, theme) {
        return BlocBuilder<AppAccentCubit, String>(
          builder:
              (context, accent) => DynamicColorBuilder(
                key: _dynamicColorKey,
                builder:
                    (dynamicLight, dynamicDark) => MaterialApp(
                      title: 'novels',
                      debugShowCheckedModeBanner: false,
                      themeMode: switch (theme.themeMode) {
                        ReaderThemeMode.auto => ThemeMode.system,
                        ReaderThemeMode.light => ThemeMode.light,
                        ReaderThemeMode.dark => ThemeMode.dark,
                      },
                      theme:
                          usesMaterialYou
                              ? materialYouTheme(
                                Brightness.light,
                                dynamicScheme: dynamicLight,
                                seedColor: appAccentColors[accent]?.$2,
                              )
                              : lightTheme,
                      darkTheme:
                          usesMaterialYou
                              ? materialYouTheme(
                                Brightness.dark,
                                dynamicScheme: dynamicDark,
                                seedColor: appAccentColors[accent]?.$2,
                              )
                              : darkTheme,
                      initialRoute: '/init',
                      routes: {
                        '/init': (context) => const InitPage(),
                        '/login':
                            (context) =>
                                const UpdateChecker(child: LoginPage()),
                        '/home':
                            (context) => const UpdateChecker(child: HomePage()),
                        '/novel/info': (context) {
                          final args =
                              ModalRoute.of(context)!.settings.arguments;
                          if (args is Map<String, dynamic>) {
                            return NovelInfoPage(
                              novelId: args['novelId'] as String,
                            );
                          }
                          return NovelInfoPage(novelId: args as String);
                        },
                        '/novel/reviews': (context) {
                          final args =
                              ModalRoute.of(context)!.settings.arguments
                                  as Map<String, dynamic>;
                          return ReviewsPage(
                            aid: args['aid'] as String,
                            title: args['title'] as String,
                          );
                        },
                        '/novel/downloading': (context) {
                          final args =
                              ModalRoute.of(context)!.settings.arguments
                                  as Map<String, dynamic>;
                          return NovelDownloadingPage(
                            novelId: args['novelId'] as String,
                            existsDownload: args['existsDownload'],
                            novelInfo: args['novelInfo'] as NovelInfo,
                            volumes: (args['volumes'] as List).cast<Volume>(),
                          );
                        },
                        '/novel/reader': (context) {
                          final args =
                              ModalRoute.of(context)!.settings.arguments
                                  as Map<String, dynamic>;
                          final readerType =
                              context.read<ReaderTypeCubit>().state;

                          if (readerType == ReaderType.html) {
                            return HtmlReaderPage(
                              novelInfo: args['novelInfo'] as NovelInfo,
                              initialAid: args['novelId'] as String,
                              initialCid: args['chapterId'] as String,
                              volumes: (args['volumes'] as List).cast<Volume>(),
                            );
                          } else {
                            return MultiBlocProvider(
                              providers: [
                                BlocProvider.value(
                                  value: context.read<FontSizeCubit>(),
                                ),
                                BlocProvider.value(
                                  value: context.read<ParagraphSpacingCubit>(),
                                ),
                                BlocProvider.value(
                                  value: context.read<LineHeightCubit>(),
                                ),
                                BlocProvider.value(
                                  value: context.read<ThemeCubit>(),
                                ),
                                BlocProvider.value(
                                  value: context.read<TopBarHeightCubit>(),
                                ),
                                BlocProvider.value(
                                  value: context.read<BottomBarHeightCubit>(),
                                ),
                              ],
                              child: ReaderPage(
                                aid: args['novelId'] as String,
                                cid: args['chapterId'] as String,
                                initialTitle: args['title'] as String,
                                volumes:
                                    (args['volumes'] as List).cast<Volume>(),
                                novelInfo: args['novelInfo'] as NovelInfo,
                                initialPage: args['initialPage'] as int?,
                              ),
                            );
                          }
                        },
                        '/category': (context) {
                          final args =
                              ModalRoute.of(context)!.settings.arguments;
                          if (args is Map<String, dynamic> &&
                              args.containsKey('tag')) {
                            return Scaffold(
                              appBar: AppBar(title: Text("分类")),
                              body: CategoryPage(
                                initialTag: args['tag'] as String,
                              ),
                            );
                          }
                          return const CategoryPage();
                        },
                        '/articlelist': (context) => const ArticlelistPage(),
                        '/recommend': (context) => const RecommendPage(),
                        '/more': (context) => const MorePage(),
                        '/search': (context) {
                          final args =
                              ModalRoute.of(context)!.settings.arguments;
                          if (args is Map<String, dynamic>) {
                            return SearchPage(
                              initialSearchType: args['searchType'] as String?,
                              initialSearchKey: args['searchKey'] as String?,
                            );
                          }
                          return const SearchPage();
                        },
                        '/about': (context) => const AboutPage(),
                      },
                    ),
              ),
        );
      },
    );
  }
}
