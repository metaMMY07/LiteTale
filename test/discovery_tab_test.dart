import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/widgets/discovery_tab.dart';

void main() {
  testWidgets('all four visited tabs retain loaded data, filters and scroll', (
    tester,
  ) async {
    final loads = <String, int>{};
    final source = ValueNotifier('a');
    await tester.pumpWidget(_host(loads, source));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选0:0'));
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('list:a:0')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    final state = tester.state<_FeedState>(find.byType(_Feed).first);
    final saved = state.controller.offset;
    expect(saved, greaterThan(0));
    for (final tab in ['分类', '排行', '全部', '分类', '推荐', '全部', '推荐']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
    for (var i = 0; i < 4; i++) {
      expect(loads['a:$i'], 1);
    }
    final returned = tester.state<_FeedState>(find.byType(_Feed).first);
    expect(returned.filter, 1);
    expect(returned.controller.offset, closeTo(saved, 1));
    await tester.pumpWidget(const SizedBox());
    source.dispose();
  });

  testWidgets('explicit refresh reloads; source change creates isolated tabs', (
    tester,
  ) async {
    final loads = <String, int>{};
    final source = ValueNotifier('a');
    await tester.pumpWidget(_host(loads, source));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新0'));
    await tester.pump();
    expect(loads['a:0'], 2);
    source.value = 'b';
    await tester.pumpAndSettle();
    expect(loads['b:0'], 1);
    expect(find.text('b:0/1'), findsOneWidget);
    expect(find.text('a:0/1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    source.dispose();
  });
}

Widget _host(Map<String, int> loads, ValueNotifier<String> source) =>
    MaterialApp(
      home: DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            bottom: const TabBar(
              tabs: [
                Tab(text: '推荐'),
                Tab(text: '分类'),
                Tab(text: '排行'),
                Tab(text: '全部'),
              ],
            ),
          ),
          body: ValueListenableBuilder<String>(
            valueListenable: source,
            builder:
                (context, value, _) => TabBarView(
                  key: ValueKey(value),
                  children: [
                    for (var i = 0; i < 4; i++)
                      DiscoveryTab(child: _Feed(value, i, loads)),
                  ],
                ),
          ),
        ),
      ),
    );

class _Feed extends StatefulWidget {
  const _Feed(this.source, this.index, this.loads);
  final String source;
  final int index;
  final Map<String, int> loads;
  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  final controller = ScrollController();
  int filter = 0;
  void load() => widget.loads.update(
    '${widget.source}:${widget.index}',
    (v) => v + 1,
    ifAbsent: () => 1,
  );
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: ValueKey('list:${widget.source}:${widget.index}'),
    controller: controller,
    itemCount: 80,
    itemExtent: 60,
    itemBuilder:
        (context, i) =>
            i == 0
                ? Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() => filter++),
                      child: Text('筛选${widget.index}:$filter'),
                    ),
                    TextButton(
                      onPressed: () => setState(load),
                      child: Text('刷新${widget.index}'),
                    ),
                  ],
                )
                : Text('${widget.source}:${widget.index}/$i'),
  );
}
