import 'package:wild/theme/ios_system_colors.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wild/widgets/bili_browser_host.dart';
import 'package:wild/widgets/huanmeng_browser_host.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/cubits/reader_curl_cubit.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/init_page.dart';
import 'package:wild/pages/login_page.dart';
import 'package:wild/pages/home_page.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/novel_info_page.dart';
import 'package:wild/pages/novel/novel_downloading_page.dart';
import 'package:wild/pages/novel/reader_route.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/home/category_page.dart';
import 'package:wild/pages/home/index_page.dart' show ArticlelistPage;
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
import 'package:wild/widgets/theme_reveal_host.dart';
import 'package:wild/widgets/wenku8_browser_host.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/theme/imported_font_theme.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/settings/settings_theme.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_app_dock.dart';

final lightTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
  fontFamily: appFontFamily,
  useMaterial3: true,
  pageTransitionsTheme: horizontalPageTransitionsTheme,
);
final darkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.dark,
  ),
  fontFamily: appFontFamily,
  useMaterial3: true,
  pageTransitionsTheme: horizontalPageTransitionsTheme,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'foliate-js',
    ], await rootBundle.loadString('lib/assets/epub_foliate_LICENSE.txt'));
  });
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
        BlocProvider(create: (_) => FontSettingsCubit()),
        BlocProvider(create: (_) => SettingsPreferencesCubit()),
        BlocProvider(create: (_) => ReadingStatisticsCubit()),
        BlocProvider(create: (_) => AppAccentCubit()),
        BlocProvider(create: (_) => ReaderCurlCubit()),
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
  final _iosDock =
      usesAppleGlass
          ? IosDockController(fullscreenRoutes: const {novelReaderRouteName})
          : null;

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
    _iosDock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appFont = context.select(
      (FontSettingsCubit cubit) => cubit.state.appFamily,
    );
    final settings = context.watch<SettingsPreferencesCubit>().state;
    return BlocBuilder<ThemeCubit, ReaderTheme>(
      builder: (context, theme) {
        return BlocBuilder<AppAccentCubit, String>(
          builder:
              (context, accent) => DynamicColorBuilder(
                key: _dynamicColorKey,
                builder:
                    (dynamicLight, dynamicDark) => MaterialApp(
                      title: 'LiteTale',
                      debugShowCheckedModeBanner: false,
                      themeAnimationDuration: Duration.zero,
                      themeAnimationCurve: Curves.easeInOutCubic,
                      navigatorObservers: [if (_iosDock case final dock?) dock],
                      builder: (context, child) {
                        final dock = _iosDock;
                        final app = ThemeRevealHost(
                          child:
                              dock == null
                                  ? child!
                                  // These routes have no Hero flights. Avoid
                                  // their hidden destination measurement.
                                  : HeroControllerScope.none(
                                    child: IosAppDockHost(
                                      controller: dock,
                                      child: child!,
                                    ),
                                  ),
                        );
                        return Wenku8BrowserHost(
                          child: BiliBrowserHost(
                            child:
                                Platform.isIOS
                                    ? HuanmengBrowserHost(child: app)
                                    : app,
                          ),
                        );
                      },
                      themeMode: switch (theme.themeMode) {
                        ReaderThemeMode.auto => ThemeMode.system,
                        ReaderThemeMode.light => ThemeMode.light,
                        ReaderThemeMode.dark => ThemeMode.dark,
                      },
                      theme: applySettingsTheme(
                        applyImportedAppFont(
                          usesMaterialYou
                              ? materialYouTheme(
                                Brightness.light,
                                dynamicScheme: dynamicLight,
                                seedColor: appAccentSeed(accent),
                              )
                              : usesAppleGlass
                              ? iosGlassTheme(
                                Brightness.light,
                                accent: IosSystemColors.accent(
                                  accent,
                                  Brightness.light,
                                ),
                              )
                              : lightTheme,
                          appFont,
                        ),
                        settings,
                      ),
                      darkTheme: applySettingsTheme(
                        applyImportedAppFont(
                          usesMaterialYou
                              ? materialYouTheme(
                                Brightness.dark,
                                dynamicScheme: dynamicDark,
                                seedColor: appAccentSeed(accent),
                              )
                              : usesAppleGlass
                              ? iosGlassTheme(
                                Brightness.dark,
                                accent: IosSystemColors.accent(
                                  accent,
                                  Brightness.dark,
                                ),
                              )
                              : darkTheme,
                          appFont,
                        ),
                        settings,
                      ),
                      initialRoute: '/init',
                      supportedLocales: const [Locale('zh', 'CN')],
                      localizationsDelegates:
                          GlobalMaterialLocalizations.delegates,
                      onGenerateRoute: (settings) {
                        if (settings.name == novelInfoRouteName) {
                          return novelInfoRoute(settings);
                        }
                        if (settings.name == novelReaderRouteName) {
                          return novelReaderRoute(settings);
                        }
                        final routes = <String, WidgetBuilder>{
                          '/init': (context) => const InitPage(),
                          '/login':
                              (context) =>
                                  const UpdateChecker(child: LoginPage()),
                          IosDockController.homeRouteName:
                              (context) => UpdateChecker(
                                child: HomePage(
                                  tabSelection: _iosDock?.selection,
                                ),
                              ),
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
                          '/articlelist':
                              (context) => Scaffold(
                                appBar: AppBar(title: const Text('完结')),
                                body: const ArticlelistPage(),
                              ),
                          '/recommend': (context) => const RecommendPage(),
                          '/more': (context) => const MorePage(),
                          '/search': (context) {
                            final args =
                                ModalRoute.of(context)!.settings.arguments;
                            if (args is Map<String, dynamic>) {
                              return SearchPage(
                                initialSearchType:
                                    args['searchType'] as String?,
                                initialSearchKey: args['searchKey'] as String?,
                              );
                            }
                            return const SearchPage();
                          },
                          '/about': (context) => const AboutPage(),
                        };
                        final builder = routes[settings.name];
                        if (builder == null) return null;
                        return HorizontalCoverPageRoute<void>(
                          builder: builder,
                          settings: settings,
                          animateEntrance:
                              !usesAppleGlass ||
                              settings.name != IosDockController.homeRouteName,
                          cachePageDuringTransition: settings.name == '/about',
                        );
                      },
                    ),
              ),
        );
      },
    );
  }
}
