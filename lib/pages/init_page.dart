import 'dart:io';
import 'package:wild/cubits/app_accent_cubit.dart';
import 'package:wild/sources/source_api.dart' show loadSourceSelection;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wild/theme/material_you.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/pages/novel/reader_type_cubit.dart';
import 'package:wild/src/rust/api/system.dart';
import 'package:wild/pages/novel/top_bar_height_cubit.dart';
import 'package:wild/pages/novel/bottom_bar_height_cubit.dart';
import 'package:wild/cubits/reader_background_cubit.dart';
import 'package:wild/cubits/volume_control_cubit.dart';

import '../methods.dart';

class InitPage extends StatefulWidget {
  const InitPage({super.key});

  @override
  State<StatefulWidget> createState() => _InitPageState();
}

class _InitPageState extends State<InitPage> {
  Future<void> _initializeCubits() async {
    String root;
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      root = await desktopRoot();
    } else {
      root = await dataRoot();
    }
    if (kDebugMode) {
      print('root: $root');
    }
    await init(root: root);
    if (!mounted) return;

    // 初始化所有 Cubit
    await loadSourceSelection();
    if (!mounted) return;
    final fontSizeCubit = context.read<FontSizeCubit>();
    final paragraphSpacingCubit = context.read<ParagraphSpacingCubit>();
    final lineHeightCubit = context.read<LineHeightCubit>();
    final themeCubit = context.read<ThemeCubit>();
    final authCubit = context.read<AuthCubit>();
    final topBarHeightCubit = context.read<TopBarHeightCubit>();
    final bottomBarHeightCubit = context.read<BottomBarHeightCubit>();
    final readerTypeCubit = context.read<ReaderTypeCubit>();
    final readerBackgroundCubit = context.read<ReaderBackgroundCubit>();
    final volumeControlCubit = context.read<VolumeControlCubit>();

    // 等待所有 Cubit 初始化完成
    await Future.wait([
      context.read<AppAccentCubit>().load(),
      fontSizeCubit.loadFontSize(),
      paragraphSpacingCubit.loadSpacing(),
      lineHeightCubit.loadLineHeight(),
      themeCubit.loadTheme(),
      authCubit.init(),
      topBarHeightCubit.loadHeight(),
      bottomBarHeightCubit.loadHeight(),
      readerTypeCubit.loadType(),
      readerBackgroundCubit.init(root),
      volumeControlCubit.init(),
    ]);
    if (!mounted) return;

    Navigator.pushReplacementNamed(context, '/home');
  }

  @override
  void initState() {
    super.initState();
    _initializeCubits();
  }

  @override
  Widget build(BuildContext context) {
    if (usesMaterialYou) {
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 48,
                backgroundColor: colors.primaryContainer,
                child: Icon(
                  Icons.auto_stories_rounded,
                  size: 48,
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text('LiteTale', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 32),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: ConstrainedBox(
        constraints: const BoxConstraints.expand(),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            var width = 1080;
            var height = 1920;
            var min =
                constraints.maxWidth > constraints.maxHeight
                    ? constraints.maxHeight
                    : constraints.maxWidth;
            var newHeight = min;
            var newWidth = min * (width / height);

            return Stack(
              children: [
                Center(
                  child: ShaderMask(
                    shaderCallback: (Rect bounds) {
                      return const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black,
                          Colors.black,
                          Colors.transparent,
                        ],
                        stops: [0.0, 0.95, 1.0],
                      ).createShader(bounds);
                    },
                    blendMode: BlendMode.dstIn,
                    child: Image.asset(
                      'lib/assets/startup.png',
                      width: newWidth,
                      height: newHeight,
                    ),
                  ),
                ),
                // 加载指示器
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 48,
                  child: Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
