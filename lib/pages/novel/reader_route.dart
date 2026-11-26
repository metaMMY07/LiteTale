import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/services/reader_listening_chapter.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

import 'bottom_bar_height_cubit.dart';
import 'font_size_cubit.dart';
import 'html_reader_page.dart';
import 'line_height_cubit.dart';
import 'paragraph_spacing_cubit.dart';
import 'reader_page.dart';
import 'reader_listening_page.dart';
import 'reader_type_cubit.dart';
import 'theme_cubit.dart';
import 'top_bar_height_cubit.dart';

const novelReaderRouteName = '/novel/reader';
const novelListeningRouteName = '/novel/listening';

({SourceId active, int revision, int session}) bookNavigationScope(
  String aid,
) => (
  active: activeSource.value,
  revision: sourceRevision.value,
  session: readerSessionGeneration(aid),
);

PageRoute<ReaderListeningRequest> novelReaderRoute(RouteSettings settings) {
  return HorizontalCoverPageRoute<ReaderListeningRequest>(
    settings: settings,
    builder: (context) {
      final args = settings.arguments as Map<String, dynamic>;
      final aid = args['novelId'] as String;
      if (!supportsLocalEpub && aid.startsWith('epub:')) {
        return Scaffold(
          appBar: AppBar(title: const Text('阅读')),
          body: const Center(child: Text('此设备无法打开本地 EPUB')),
        );
      }

      final cid = args['chapterId'] as String;
      final volumes = (args['volumes'] as List).cast<Volume>();
      final info = args['novelInfo'] as NovelInfo;
      final initialPage = args['initialPage'] as int?;
      final initialTextOffset = args['initialTextOffset'] as int?;
      final fromScroll = initialPage == scrollReaderProgressPage;
      if (args['forcePaged'] != true &&
          context.read<ReaderTypeCubit>().state == ReaderType.html) {
        return HtmlReaderPage(
          novelInfo: info,
          initialAid: aid,
          initialCid: cid,
          volumes: volumes,
          initialTextOffset: fromScroll ? initialTextOffset : null,
        );
      }
      return MultiBlocProvider(
        providers: [
          BlocProvider.value(value: context.read<FontSizeCubit>()),
          BlocProvider.value(value: context.read<ParagraphSpacingCubit>()),
          BlocProvider.value(value: context.read<LineHeightCubit>()),
          BlocProvider.value(value: context.read<ThemeCubit>()),
          BlocProvider.value(value: context.read<TopBarHeightCubit>()),
          BlocProvider.value(value: context.read<BottomBarHeightCubit>()),
        ],
        child: ReaderPage(
          aid: aid,
          cid: cid,
          initialTitle: args['title'] as String,
          volumes: volumes,
          novelInfo: info,
          initialPage: fromScroll ? null : initialPage,
          initialTextOffset: fromScroll ? null : initialTextOffset,
          initialSourceOffset: fromScroll ? initialTextOffset : null,
        ),
      );
    },
  );
}

Future<void> pushNovelReader(
  BuildContext context,
  RouteSettings settings, {
  bool fromDetail = true,
  ValueChanged<ReadingProgress>? onListeningPosition,
}) async {
  final aid = (settings.arguments as Map)['novelId'] as String;
  final scope = bookNavigationScope(aid);
  final listening = await pushAndWaitForPageExit(
    context,
    novelReaderRoute(settings),
  );
  if (listening == null ||
      !context.mounted ||
      ModalRoute.of(context)?.isCurrent == false ||
      scope != bookNavigationScope(aid)) {
    return;
  }
  if (fromDetail) {
    await openReaderListening(
      context,
      listening,
      onPosition: onListeningPosition,
    );
  } else {
    await Navigator.of(context).pushNamed<void>(
      '/novel/info',
      arguments: {'novelId': aid, 'listening': listening},
    );
  }
}

Future<void> openReaderListening(
  BuildContext context,
  ReaderListeningRequest request, {
  ValueChanged<ReadingProgress>? onPosition,
}) async {
  await pushAndWaitForPageExit(
    context,
    HorizontalCoverPageRoute<void>(
      settings: const RouteSettings(name: novelListeningRouteName),
      builder:
          (_) => ReaderListeningPage(request: request, onPosition: onPosition),
    ),
  );
  await ReadingProgressQueue.instance.flushBounded();
}
