import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/widgets/apple_reader_panel.dart';
import 'package:wild/widgets/book_details_view.dart';
import 'package:wild/widgets/reader_chapter_sheet.dart';
import 'package:wild/widgets/reader_settings_binding.dart';
import 'package:wild/widgets/reader_settings_panel.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/sources/book_source.dart';
import 'reader_controls_test.dart' show providers;
import 'book_cover_details_test.dart' show info, volumes;

class _Size extends FontSizeCubit {
  final values = <double>[];
  Completer<void>? wait;
  @override
  Future<void> updateFontSize(double value) async {
    values.add(value);
    await wait?.future;
    emit(value);
  }
}

void main() {
  for (final directory in [true, false]) {
    testWidgets(
      'Android ${directory ? 'directory' : 'settings'} has only one drag handle',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await tester.pumpWidget(
          providers(
            MaterialApp(
              theme: materialYouTheme(Brightness.dark),
              home: Scaffold(
                body: Builder(
                  builder:
                      (context) => TextButton(
                        onPressed: () {
                          if (directory) {
                            showReaderChapterSheet(
                              context,
                              volumes: [
                                ...volumes,
                                Volume(
                                  id: 'long',
                                  title: '后续章节',
                                  chapters: List.generate(
                                    100,
                                    (i) => Chapter(
                                      aid: 'bili:1',
                                      cid: 'next-$i',
                                      title: '后续第$i章',
                                      url: '',
                                    ),
                                  ),
                                ),
                              ],
                              currentAid: 'bili:1',
                              currentCid: 'two',
                            );
                          } else {
                            showReaderSettingsPanel(context);
                          }
                        },
                        child: const Text('open'),
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        // The Material You theme enables its own handle. These draggable panels
        // already draw one, so the route must not add another outside the panel.
        expect(
          tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
          false,
        );
        expect(
          find.byKey(
            ValueKey(
              directory
                  ? 'reader-chapter-drag-handle'
                  : 'reader-settings-drag-handle',
            ),
          ),
          findsOneWidget,
        );
        if (directory) {
          expect(find.byType(StretchingOverscrollIndicator), findsNothing);
          final tile = find.widgetWithText(ListTile, '第二章');
          final material = tester.widget<Material>(
            find.ancestor(of: tile, matching: find.byType(Material)).first,
          );
          expect(material.clipBehavior, isNot(Clip.none));
          expect(
            tester
                .getRect(
                  find
                      .ancestor(of: tile, matching: find.byType(Material))
                      .first,
                )
                .height,
            lessThan(80),
          );
          // The current chapter's highlight is row-local, not a coloured ink
          // feature on the outer modal that can leak into the heading on scroll.
          final before = tester.getSize(find.byType(ReaderChapterPanel)).height;
          await tester.drag(
            find.byKey(const ValueKey('reader-chapter-drag-handle')),
            const Offset(0, -180),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byType(ReaderChapterPanel)).height,
            greaterThan(before + 100),
          );
          await tester.drag(find.byType(ListView), const Offset(0, -250));
          await tester.pumpAndSettle();
        }
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await tester.pumpAndSettle();
        expect(find.text('open'), findsOneWidget);
        expect(tester.takeException(), null);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('every native setting has its own label and validated identity', (
    tester,
  ) async {
    late ReaderSettingsBinding binding;
    final size = _Size();
    var layouts = 0;
    await tester.pumpWidget(
      providers(
        MaterialApp(
          home: BlocProvider<FontSizeCubit>.value(
            value: size,
            child: Builder(
              builder: (context) {
                binding = ReaderSettingsBinding(
                  context,
                  onLayoutChanged: () async {
                    layouts++;
                  },
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    final rows =
        (binding.snapshot()['sections'] as List)
            .cast<Map>()
            .expand((s) => s['rows'] as List)
            .cast<Map>()
            .toList();
    expect(
      rows.map((r) => r['title']),
      containsAll(['字号', '行高', '段间距', '左侧留白', '右侧留白', '上边距', '下边距']),
    );
    expect(rows.map((r) => r['id']).toSet().length, rows.length);
    expect(rows.every((r) => (r['description'] as String).isNotEmpty), true);
    for (final event in [
      {'id': 'size', 'value': double.nan},
      {'id': 'size', 'value': '24'},
      {'id': 'mode', 'value': 'unsupported'},
      {'id': 'volume', 'value': 1},
      {'id': 'lightBackground', 'value': -1},
      {'id': 'missing', 'value': 24},
    ]) {
      expect(await binding.change(event), isEmpty);
    }
    expect(size.values, isEmpty);
    expect(layouts, 0);
    final reply = await binding.change({'id': 'size', 'value': 100});
    expect(size.values, [40]);
    expect(reply['configuration'], isA<Map>());
    expect(layouts, 1);
    size.wait = Completer<void>();
    final pending = binding.change({'id': 'size', 'value': 23.2});
    expect(await binding.change({'id': 'size', 'value': 30}), isEmpty);
    size.wait!.complete();
    await pending;
    expect(size.values, [40, 23]);
    expect(layouts, 2);
  });

  testWidgets(
    'native modal back removes only its route and isolates stale events',
    (tester) async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppleReaderPanel.channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(AppleReaderPanel.channel, null),
      );
      late BuildContext reader;
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              reader = context;
              return const Scaffold(body: Text('reader remains'));
            },
          ),
        ),
      );
      final future = AppleReaderPanel.show(
        reader,
        configuration: () => {'title': '排版'},
        onChange: (_) async {
          changes++;
          return {};
        },
      );
      await tester.pumpAndSettle();
      expect(ModalRoute.of(reader)!.isCurrent, false);
      final firstId =
          (calls.singleWhere((c) => c.method == 'present').arguments
              as Map)['session'];
      Navigator.of(reader).pop();
      await tester.pumpAndSettle();
      expect(await future, null);
      expect(ModalRoute.of(reader)!.isCurrent, true);
      expect(calls.last.method, 'dismiss');
      final second = AppleReaderPanel.show(
        reader,
        configuration: () => {'title': '目录'},
      );
      await tester.pumpAndSettle();
      await messenger.handlePlatformMessage(
        'litetale/reader_panel',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('dismissed', {'session': firstId}),
        ),
        (_) {},
      );
      await tester.pump();
      expect(ModalRoute.of(reader)!.isCurrent, false);
      expect(changes, 0);
      final secondId =
          (calls.lastWhere((c) => c.method == 'present').arguments
              as Map)['session'];
      await messenger.handlePlatformMessage(
        'litetale/reader_panel',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('dismissed', {
            'session': secondId,
            'selection': {'id': '1:0'},
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(await second, {'id': '1:0'});
      expect(ModalRoute.of(reader)!.isCurrent, true);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('bookmark contents stay in the centre of its glass frame', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookDetailsView(
            info: info,
            volumes: volumes,
            source: SourceId.wenku8,
            inShelf: true,
            onBookmark: () async {},
            onComments: () {},
            onRead: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final frame = tester.getRect(find.byKey(const ValueKey('detail-bookmark')));
    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('detail-bookmark')),
        matching: find.byType(Icon),
      ),
    );
    expect((frame.center - icon.center).distance, lessThan(.01));
    expect(frame.size, const Size(56, 56));
    expect(find.text('书评'), findsNothing);
    expect(tester.takeException(), null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'directory list shares its sheet scroll controller and selection is explicit',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var selected = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderChapterPanel(
              volumes: volumes,
              currentAid: 'bili:1',
              currentCid: 'two',
              scrollController: controller,
              onSelect: (c) => selected = c.cid,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(controller),
      );
      expect(selected, '');
      await tester.tap(find.text('第一章'));
      expect(selected, 'one');
      expect(tester.takeException(), null);
    },
  );
}
