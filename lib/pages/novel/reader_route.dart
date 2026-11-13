import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/apple_books_open_page.dart';
import 'package:wild/services/reading_progress.dart';
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
import 'reader_type_cubit.dart';
import 'theme_cubit.dart';
import 'top_bar_height_cubit.dart';

const novelReaderRouteName = '/novel/reader';

({SourceId active, int revision, int session}) bookNavigationScope(
  String aid,
) => (
  active: activeSource.value,
  revision: sourceRevision.value,
  session: readerSessionGeneration(aid),
);

PageRoute<void> novelReaderRoute(RouteSettings settings) {
  return HorizontalCoverPageRoute<void>(
    settings: settings,
    builder: (context) {
      final args = settings.arguments as Map<String, dynamic>;
      final aid = args['novelId'] as String;
      if (Platform.isIOS && sourceOf(aid) == SourceId.localEpub) {
        return AppleBooksOpenPage(bookId: aid);
      }

      final cid = args['chapterId'] as String;
      final volumes = (args['volumes'] as List).cast<Volume>();
      final info = args['novelInfo'] as NovelInfo;
      final initialPage = args['initialPage'] as int?;
      final initialTextOffset = args['initialTextOffset'] as int?;
      final fromScroll = initialPage == scrollReaderProgressPage;
      if (context.read<ReaderTypeCubit>().state == ReaderType.html) {
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
