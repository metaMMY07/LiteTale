import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/reader_cubit.dart';
import 'package:wild/pages/novel/reader_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/reader_cover_view.dart';

import 'paginated_reader_requests_test.dart' show info;
import 'reader_controls_test.dart' show providers;

class _ReaderTapSource implements BookSource {
  @override
  SourceId get id => SourceId.lnovel;

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async =>
      SourceChapter(List.filled(100, '这是阅读点击区的离线测试内容。' * 10).join('\n'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'iOS portrait reader turns forward from the upper right',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = api.bookSources[SourceId.lnovel]!;
      api.bookSources[SourceId.lnovel] = _ReaderTapSource();
      addTearDown(() => api.bookSources[SourceId.lnovel] = old);

      const aid = 'lnv:tap-zones-fixture';
      const cid = 'a';
      await tester.pumpWidget(
        providers(
          BlocProvider(
            create: (_) => FontSettingsCubit(),
            child: MaterialApp(
              home: ReaderPage(
                aid: aid,
                cid: cid,
                initialTitle: '正文',
                initialPage: 1,
                novelInfo: info,
                volumes: const [
                  Volume(
                    id: 'v',
                    title: '卷',
                    chapters: [
                      Chapter(aid: aid, cid: cid, title: '正文', url: ''),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cubit =
          tester.element(find.byType(ReaderCoverView)).read<ReaderCubit>();
      ReaderLoaded loaded() => cubit.state as ReaderLoaded;
      expect(loaded().currentPageIndex, 1);

      await tester.tapAt(const Offset(350, 120));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, 2);

      await tester.tapAt(const Offset(40, 120));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, 1);

      await tester.tapAt(const Offset(240, 120));
      await tester.pumpAndSettle();
      expect(loaded().currentPageIndex, 1);
      expect(loaded().showControls, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
