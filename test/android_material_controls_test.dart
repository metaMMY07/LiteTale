import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/category_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/api/wenku8.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/fluid_navigation_bar.dart';
import 'package:wild/widgets/material_choice_controls.dart';
import 'package:wild/widgets/material_source_picker.dart';
import 'package:wild/widgets/platform_controls.dart';

void androidTest(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);

Widget app(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: materialYouTheme(brightness, seedColor: Colors.orange),
      home: Scaffold(body: child),
    );

void main() {
  androidTest('filled choices preserve selection, disabled and empty rules', (
    tester,
  ) async {
    var selected = <int>{0};
    var changes = 0;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return AppSegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('更新')),
                ButtonSegment(value: 1, label: Text('热门')),
                ButtonSegment(value: 2, label: Text('不可用'), enabled: false),
              ],
              selected: selected,
              onSelectionChanged:
                  (next) => setState(() {
                    selected = next;
                    changes++;
                  }),
            );
          },
        ),
      ),
    );
    expect(find.byType(MaterialChoiceBar<int>), findsOneWidget);
    await tester.tap(find.text('更新'));
    await tester.tap(find.text('不可用'));
    expect(changes, 0);
    await tester.tap(find.text('热门'));
    await tester.pumpAndSettle();
    expect(selected, {1});
    expect(changes, 1);
    expect(tester.takeException(), isNull);
  });

  androidTest('multiple choices allow removal and optional empty selection', (
    tester,
  ) async {
    var selected = <int>{0};
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return AppSegmentedButton<int>(
              multiSelectionEnabled: true,
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(value: 0, label: Text('一')),
                ButtonSegment(value: 1, label: Text('二')),
              ],
              selected: selected,
              onSelectionChanged: (next) => setState(() => selected = next),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('二'));
    await tester.pump();
    expect(selected, {0, 1});
    await tester.tap(find.text('一'));
    await tester.pump();
    await tester.tap(find.text('二'));
    await tester.pump();
    expect(selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 640), const Size(1280, 900)]) {
    androidTest('source cards fill available width and scroll at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final sources = [
        SourceId.wenku8,
        ...List.generate(
          20,
          (i) => SourceId.rule('fixture-$i', label: '测试书源 $i'),
        ),
        SourceId.esj,
      ];
      final changes = <SourceId>[];
      await tester.pumpWidget(
        app(
          Padding(
            padding: const EdgeInsets.all(16),
            child: MaterialSourcePicker(
              value: SourceId.wenku8,
              sources: sources,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('source-picker-button')));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      final first = tester.getRect(
        find.byKey(const ValueKey('source-option-wenku8')),
      );
      expect(first.left, 16);
      expect(first.width, size.width - 32);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('source-option-esj')),
        300,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-option-esj')));
      await tester.pumpAndSettle();
      expect(changes, [SourceId.esj]);
      expect(find.text('选择书源'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  androidTest('closing source cards never changes the provider', (
    tester,
  ) async {
    final changes = <SourceId>[];
    await tester.pumpWidget(
      app(
        MaterialSourcePicker(
          value: SourceId.wenku8,
          sources: const [SourceId.wenku8, SourceId.esj],
          onChanged: changes.add,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('source-picker-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
  });

  for (final brightness in Brightness.values) {
    androidTest('bottom bar retains glass and 78dp actions in $brightness', (
      tester,
    ) async {
      var index = 0;
      const destinations = [
        FluidNavigationDestination(
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore,
          label: '发现',
        ),
        FluidNavigationDestination(
          icon: Icons.book_outlined,
          selectedIcon: Icons.book,
          label: '书架',
        ),
        FluidNavigationDestination(
          icon: Icons.history_outlined,
          selectedIcon: Icons.history,
          label: '历史',
        ),
        FluidNavigationDestination(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: '我的',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: materialYouTheme(brightness),
          home: StatefulBuilder(
            builder:
                (context, setState) => Scaffold(
                  body: const ColoredBox(color: Colors.red),
                  bottomNavigationBar: FluidNavigationBar(
                    destinations: destinations,
                    selectedIndex: index,
                    onDestinationSelected:
                        (next) => setState(() => index = next),
                  ),
                ),
          ),
        ),
      );
      final bar = find.byType(FluidNavigationBar);
      expect(
        find.descendant(of: bar, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final surface = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: bar,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration as BoxDecoration).color != null,
              ),
            )
            .first,
      );
      final opacity = (surface.decoration as BoxDecoration).color!.a;
      expect(opacity, greaterThan(0));
      expect(opacity, lessThan(1));
      for (final label in ['发现', '书架', '历史', '我的']) {
        final action = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        expect(tester.getSize(action).height, 78);
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(index, 3);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 1280.0]) {
    androidTest('category popup is wide, scrolls and selects at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      String? loadedTag;
      await tester.pumpWidget(
        app(
          CategoryPage(
            tagsLoader:
                () async => [
                  TagGroup(
                    title: '日常',
                    tags: List.generate(30, (i) => '分类 $i'),
                  ),
                ],
            pageLoader: ({
              required tag,
              required v,
              required pageNumber,
            }) async {
              loadedTag = tag;
              return const PageStatsNovelCover(
                currentPage: 1,
                maxPage: 1,
                records: [],
              );
            },
            preferenceLoader: (_) async => '',
            preferenceSaver: (_, __) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('分类'));
      await tester.pumpAndSettle();
      final item = tester.getRect(
        find.byWidgetPredicate(
          (widget) => widget is PopupMenuItem<String> && widget.value == '分类 0',
        ),
      );
      expect(item.width, closeTo(width < 352 ? width - 32 : 320, 1));
      await tester.scrollUntilVisible(
        find.text('分类 29'),
        350,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('分类 29'));
      await tester.pumpAndSettle();
      expect(loadedTag, '分类 29');
      expect(tester.takeException(), isNull);
    });
  }

  androidTest('filled choices also fit an unconstrained horizontal row', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Row(
          children: [
            AppSegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('一')),
                ButtonSegment(value: 1, label: Text('二')),
              ],
              selected: const {0},
              onSelectionChanged: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  androidTest(
    'large text and long categories remain operable on a narrow phone',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);
      var mode = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: materialYouTheme(Brightness.dark),
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              ),
          home: Scaffold(
            body: CategoryPage(
              initialTag: '超长的分类标签名称',
              tagsLoader:
                  () async => const [
                    TagGroup(title: '分类', tags: ['超长的分类标签名称']),
                  ],
              pageLoader: ({
                required tag,
                required v,
                required pageNumber,
              }) async {
                mode = v;
                return const PageStatsNovelCover(
                  currentPage: 1,
                  maxPage: 1,
                  records: [],
                );
              },
              preferenceLoader: (_) async => '',
              preferenceSaver: (_, __) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('完结'));
      await tester.tap(find.text('完结'));
      await tester.pumpAndSettle();
      expect(mode, '2');
      expect(tester.takeException(), isNull);
    },
  );
}
