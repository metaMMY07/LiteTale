import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';

class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  SourceId _source = activeSource.value;
  DateTime _selectedDate = _dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ReadingStatisticsCubit>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ReadingStatisticsCubit, ReadingStatisticsState>(
      builder: (context, state) {
        final cubit = context.read<ReadingStatisticsCubit>();
        final snapshot = cubit.snapshot(source: _source);
        return Scaffold(
          appBar: AppBar(
            title: const Text('阅读统计'),
            actions: [
              PopupMenuButton<SourceId>(
                tooltip: '选择统计书源',
                icon: const Icon(Icons.filter_list_rounded),
                onSelected: (value) => setState(() => _source = value),
                itemBuilder:
                    (context) => [
                      for (final source in SourceId.values)
                        CheckedPopupMenuItem(
                          value: source,
                          checked: source == _source,
                          child: Text(source.label),
                        ),
                    ],
              ),
            ],
          ),
          body:
              state.initialized
                  ? _StatisticsOverview(
                    snapshot: snapshot,
                    sourceName: _source.label,
                    selectedDate: _selectedDate,
                    onSelectDate:
                        (date) => setState(() => _selectedDate = date),
                    onOpenDetails:
                        () => Navigator.of(context).push<void>(
                          HorizontalCoverPageRoute<void>(
                            builder:
                                (_) => ReadingStatisticsDetailPage(
                                  date: _selectedDate,
                                  source: _source,
                                ),
                          ),
                        ),
                    warning: state.warning,
                  )
                  : const Center(child: ExpressiveLoadingIndicator()),
        );
      },
    );
  }
}

class _StatisticsOverview extends StatelessWidget {
  const _StatisticsOverview({
    required this.snapshot,
    required this.sourceName,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDetails,
    required this.warning,
  });

  final ReadingStatisticsSnapshot snapshot;
  final String sourceName;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onSelectDate;
  final VoidCallback onOpenDetails;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final todaysSeconds = snapshot.secondsForDay(selectedDate);
    final todaysBooks =
        snapshot.secondsByDayAndBook[selectedDate] ?? const <String, int>{};
    final rankedBooks =
        todaysBooks.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return LeftAlignedScrollView(
      topInset: 8,
      bottomInset: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text('统计书源：$sourceName'),
          ),
          if (warning != null) ...[
            _NoticeCard(message: warning!),
            const SizedBox(height: 12),
          ],
          _SummaryCard(snapshot: snapshot),
          const SizedBox(height: 14),
          _SectionCard(
            title: '阅读活动',
            subtitle: '本地记录 · 只统计阅读器实际开启的时间',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        final date = _heatmapDateAt(
                          details.localPosition,
                          Size(constraints.maxWidth, 80),
                          DateTime.now().subtract(const Duration(days: 364)),
                        );
                        if (date != null) onSelectDate(date);
                      },
                      child: CustomPaint(
                        size: Size(constraints.maxWidth, 80),
                        painter: _HeatmapPainter(
                          values: snapshot.secondsByDay,
                          selectedDate: selectedDate,
                          startDate: _dateOnly(
                            DateTime.now().subtract(const Duration(days: 364)),
                          ),
                          base: settingsSurfaceLayer(
                            colors,
                            colors.surfaceContainerHighest,
                            .14,
                          ),
                          active: colors.primary,
                          outline: colors.onSurface,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    Text(
                      _dateLabel(selectedDate),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      _formatDuration(todaysSeconds),
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (rankedBooks.isEmpty)
                  Text(
                    '这一天还没有阅读记录。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  )
                else
                  ...rankedBooks
                      .take(3)
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  snapshot.titlesByBook[entry.key] ?? entry.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _formatDuration(entry.value),
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: '阅读时段',
            subtitle: '按一天中的本地时间统计',
            child: _HourlyChart(values: _hoursForDate(snapshot, selectedDate)),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: '按书籍查看趋势',
            subtitle: '点击日期可切换统计范围',
            child: Wrap(
              spacing: 16,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('每日、每周与每月阅读时长'),
                FilledButton.tonalIcon(
                  onPressed: onOpenDetails,
                  icon: const Icon(Icons.bar_chart_rounded),
                  label: const Text('查看详情'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '统计数据只保存在这台设备；没有历史阅读数据时会从今天开始记录。',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class ReadingStatisticsDetailPage extends StatefulWidget {
  const ReadingStatisticsDetailPage({
    super.key,
    required this.date,
    this.source,
  });

  final DateTime date;
  final SourceId? source;

  @override
  State<ReadingStatisticsDetailPage> createState() =>
      _ReadingStatisticsDetailPageState();
}

enum _StatisticsPeriod { days, weeks, months }

class _ReadingStatisticsDetailPageState
    extends State<ReadingStatisticsDetailPage> {
  _StatisticsPeriod _period = _StatisticsPeriod.days;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ReadingStatisticsCubit, ReadingStatisticsState>(
      builder: (context, state) {
        final snapshot = context.read<ReadingStatisticsCubit>().snapshot(
          source: widget.source,
        );
        final buckets = _makeBuckets(snapshot, widget.date, _period);
        final periodLabel = switch (_period) {
          _StatisticsPeriod.days => '近 7 天',
          _StatisticsPeriod.weeks => '本月各周',
          _StatisticsPeriod.months => '本年各月',
        };
        return Scaffold(
          appBar: AppBar(title: const Text('阅读趋势')),
          body: LeftAlignedScrollView(
            topInset: 8,
            bottomInset: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SegmentedButton<_StatisticsPeriod>(
                    segments: const [
                      ButtonSegment(
                        value: _StatisticsPeriod.days,
                        label: Text('日'),
                      ),
                      ButtonSegment(
                        value: _StatisticsPeriod.weeks,
                        label: Text('周'),
                      ),
                      ButtonSegment(
                        value: _StatisticsPeriod.months,
                        label: Text('月'),
                      ),
                    ],
                    selected: {_period},
                    onSelectionChanged:
                        (selection) =>
                            setState(() => _period = selection.first),
                  ),
                ),
                const SizedBox(height: 18),
                _SectionCard(
                  title: '按书籍堆叠的阅读时长',
                  subtitle: '$periodLabel · ${_dateLabel(widget.date)}',
                  child:
                      buckets.every((bucket) => bucket.secondsByBook.isEmpty)
                          ? const _EmptyChart(
                            message: '这段时间没有阅读记录。开始阅读后，图表会按书籍累积。',
                          )
                          : _StackedBookChart(
                            buckets: buckets,
                            titles: snapshot.titlesByBook,
                          ),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  title: '时间分布',
                  subtitle: '选中日期 · ${_dateLabel(widget.date)}',
                  child: _HourlyChart(
                    values: _hoursForDate(snapshot, widget.date),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  title: '统计摘要',
                  subtitle: '本地累积',
                  child: Wrap(
                    spacing: 18,
                    runSpacing: 12,
                    children: [
                      _Metric(
                        label: '阅读时长',
                        value: _formatDuration(snapshot.totalSeconds),
                      ),
                      _Metric(
                        label: '阅读会话',
                        value: '${snapshot.sessionCount} 次',
                      ),
                      _Metric(label: '活跃天数', value: '${snapshot.activeDays} 天'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.snapshot});
  final ReadingStatisticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final empty = snapshot.isEmpty;
    return Card(
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 520;
            final metricWidth =
                wide
                    ? (constraints.maxWidth - 36) / 3
                    : (constraints.maxWidth - 16) / 2;
            return Wrap(
              spacing: 18,
              runSpacing: 18,
              children: [
                SizedBox(
                  width: metricWidth,
                  child: _Metric(
                    label: '累计阅读',
                    value: empty ? '—' : _formatDuration(snapshot.totalSeconds),
                    emphasize: true,
                  ),
                ),
                SizedBox(
                  width: metricWidth,
                  child: _Metric(
                    label: '阅读会话',
                    value: empty ? '—' : '${snapshot.sessionCount} 次',
                  ),
                ),
                SizedBox(
                  width: metricWidth,
                  child: _Metric(
                    label: '阅读天数',
                    value: empty ? '—' : '${snapshot.activeDays} 天',
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

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.emphasize = false,
  });
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: colors.onSecondaryContainer),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: (emphasize
                  ? Theme.of(context).textTheme.headlineSmall
                  : Theme.of(context).textTheme.titleLarge)
              ?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.onSecondaryContainer,
              ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: settingsSurfaceLayer(colors, colors.surfaceContainerLow, .04),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: colors.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_graph_rounded, color: colors.primary, size: 30),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _HourlyChart extends StatelessWidget {
  const _HourlyChart({required this.values});
  final Map<int, int> values;

  @override
  Widget build(BuildContext context) {
    if (values.values.every((value) => value == 0)) {
      return const _EmptyChart(message: '这一天还没有阅读时段。');
    }
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 126,
      width: double.infinity,
      child: CustomPaint(
        painter: _HourlyPainter(
          values: values,
          bar: colors.primary,
          selected: colors.tertiary,
          grid: colors.outlineVariant,
          label: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _StackBucket {
  const _StackBucket(this.label, this.secondsByBook);
  final String label;
  final Map<String, int> secondsByBook;
}

class _StackedBookChart extends StatefulWidget {
  const _StackedBookChart({required this.buckets, required this.titles});
  final List<_StackBucket> buckets;
  final Map<String, String> titles;

  @override
  State<_StackedBookChart> createState() => _StackedBookChartState();
}

class _StackedBookChartState extends State<_StackedBookChart> {
  int _selected = -1;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final books =
        <String>{
            for (final bucket in widget.buckets) ...bucket.secondsByBook.keys,
          }.toList()
          ..sort((a, b) => _sumForBook(b).compareTo(_sumForBook(a)));
    final displayedBooks = books.take(5).toList();
    if (books.length > 5) displayedBooks.add('__other__');
    final palette = [
      colors.primary,
      colors.tertiary,
      colors.secondary,
      colors.primaryContainer,
      colors.tertiaryContainer,
      colors.secondaryContainer,
    ];
    final selectedBucket =
        _selected >= 0 && _selected < widget.buckets.length
            ? widget.buckets[_selected]
            : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedBucket != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${selectedBucket.label} · ${_formatDuration(selectedBucket.secondsByBook.values.fold<int>(0, (sum, value) => sum + value))}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        SizedBox(
          height: 188,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = math.max(
                constraints.maxWidth,
                widget.buckets.length * 54.0,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    final index = (details.localPosition.dx /
                            (width / widget.buckets.length))
                        .floor()
                        .clamp(0, widget.buckets.length - 1);
                    setState(() => _selected = index);
                  },
                  child: CustomPaint(
                    size: Size(width, 188),
                    painter: _StackedPainter(
                      buckets: widget.buckets,
                      bookIds: displayedBooks,
                      colors: palette,
                      labels: colors.onSurfaceVariant,
                      grid: colors.outlineVariant,
                      selectedIndex: _selected,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          children: [
            for (var i = 0; i < displayedBooks.length; i++)
              _LegendItem(
                color: palette[i],
                label:
                    displayedBooks[i] == '__other__'
                        ? '其他书籍'
                        : (widget.titles[displayedBooks[i]] ??
                            displayedBooks[i]),
              ),
          ],
        ),
        if (books.isEmpty) const _EmptyChart(message: '没有书籍阅读时长。'),
      ],
    );
  }

  int _sumForBook(String bookId) => widget.buckets.fold<int>(
    0,
    (sum, bucket) => sum + (bucket.secondsByBook[bookId] ?? 0),
  );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ],
  );
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.values,
    required this.selectedDate,
    required this.startDate,
    required this.base,
    required this.active,
    required this.outline,
  });
  final Map<DateTime, int> values;
  final DateTime selectedDate;
  final DateTime startDate;
  final Color base;
  final Color active;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    const rows = 7;
    const gap = 2.0;
    const days = 365;
    final start = _dateOnly(startDate);
    final offset = start.weekday - 1;
    final columns = ((offset + days) / rows).ceil();
    final cell = math.min(
      (size.width - (columns - 1) * gap) / columns,
      (size.height - (rows - 1) * gap) / rows,
    );
    final paint = Paint();
    for (var index = 0; index < days; index++) {
      final date = start.add(Duration(days: index));
      final col = (offset + index) ~/ rows;
      final row = (offset + index) % rows;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(col * (cell + gap), row * (cell + gap), cell, cell),
        const Radius.circular(2),
      );
      final level = _level(values[_dateOnly(date)] ?? 0);
      paint.color = Color.lerp(base, active, level)!;
      canvas.drawRRect(rect, paint);
      if (_dateOnly(date) == _dateOnly(selectedDate)) {
        paint.color = outline;
        paint.style = PaintingStyle.stroke;
        paint.strokeWidth = 1.2;
        canvas.drawRRect(rect, paint);
        paint.style = PaintingStyle.fill;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) =>
      old.values != values ||
      old.selectedDate != selectedDate ||
      old.startDate != startDate ||
      old.base != base ||
      old.active != active ||
      old.outline != outline;
}

class _HourlyPainter extends CustomPainter {
  _HourlyPainter({
    required this.values,
    required this.bar,
    required this.selected,
    required this.grid,
    required this.label,
  });
  final Map<int, int> values;
  final Color bar;
  final Color selected;
  final Color grid;
  final Color label;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 6.0;
    const right = 6.0;
    const top = 10.0;
    const bottom = 22.0;
    final chartHeight = size.height - top - bottom;
    final maxSeconds = values.values.fold<int>(0, math.max);
    if (maxSeconds <= 0) return;
    final slot = (size.width - left - right) / 24;
    final barWidth = slot * .58;
    final paint = Paint();
    for (var line = 0; line < 3; line++) {
      final y = top + chartHeight * line / 2;
      paint.color = grid.withValues(alpha: .5);
      paint.strokeWidth = 1;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), paint);
    }
    for (var hour = 0; hour < 24; hour++) {
      final seconds = values[hour] ?? 0;
      final height = chartHeight * seconds / maxSeconds;
      final x = left + hour * slot + (slot - barWidth) / 2;
      paint.color = seconds == 0 ? grid.withValues(alpha: .35) : bar;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x,
            top + chartHeight - height,
            barWidth,
            math.max(2, height),
          ),
          const Radius.circular(3),
        ),
        paint,
      );
      if (hour % 4 == 0) {
        _drawText(
          canvas,
          '$hour',
          Offset(left + hour * slot + slot / 2, size.height - bottom + 5),
          label,
          fontSize: 10,
          centered: true,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HourlyPainter old) =>
      old.values != values ||
      old.bar != bar ||
      old.selected != selected ||
      old.grid != grid ||
      old.label != label;
}

class _StackedPainter extends CustomPainter {
  _StackedPainter({
    required this.buckets,
    required this.bookIds,
    required this.colors,
    required this.labels,
    required this.grid,
    required this.selectedIndex,
  });
  final List<_StackBucket> buckets;
  final List<String> bookIds;
  final List<Color> colors;
  final Color labels;
  final Color grid;
  final int selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 4.0;
    const right = 4.0;
    const top = 12.0;
    const bottom = 28.0;
    final chartHeight = size.height - top - bottom;
    final slot = (size.width - left - right) / buckets.length;
    final barWidth = math.min(30.0, slot * .62);
    final maxTotal = buckets.fold<int>(
      0,
      (highest, bucket) => math.max(highest, _bucketTotal(bucket, bookIds)),
    );
    if (maxTotal <= 0) return;
    final paint = Paint();
    for (var line = 0; line <= 2; line++) {
      final y = top + chartHeight * line / 2;
      paint.color = grid.withValues(alpha: .5);
      paint.strokeWidth = 1;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), paint);
    }
    for (var index = 0; index < buckets.length; index++) {
      final bucket = buckets[index];
      final x = left + index * slot + (slot - barWidth) / 2;
      var stackHeight = 0.0;
      for (var bookIndex = 0; bookIndex < bookIds.length; bookIndex++) {
        final seconds =
            bookIds[bookIndex] == '__other__'
                ? _otherSeconds(bucket, bookIds)
                : bucket.secondsByBook[bookIds[bookIndex]] ?? 0;
        if (seconds == 0) continue;
        final height = chartHeight * seconds / maxTotal;
        paint.color = colors[bookIndex % colors.length];
        canvas.drawRect(
          Rect.fromLTWH(
            x,
            top + chartHeight - stackHeight - height,
            barWidth,
            height,
          ),
          paint,
        );
        stackHeight += height;
      }
      if (index == selectedIndex) {
        paint.color = labels;
        paint.style = PaintingStyle.stroke;
        paint.strokeWidth = 1.2;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              x - 2,
              top + chartHeight - stackHeight - 2,
              barWidth + 4,
              stackHeight + 4,
            ),
            const Radius.circular(4),
          ),
          paint,
        );
        paint.style = PaintingStyle.fill;
      }
      _drawText(
        canvas,
        bucket.label,
        Offset(x + barWidth / 2, size.height - bottom + 6),
        labels,
        fontSize: 10,
        centered: true,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StackedPainter old) =>
      old.buckets != buckets ||
      old.bookIds != bookIds ||
      old.colors != colors ||
      old.labels != labels ||
      old.grid != grid ||
      old.selectedIndex != selectedIndex;
}

List<_StackBucket> _makeBuckets(
  ReadingStatisticsSnapshot snapshot,
  DateTime date,
  _StatisticsPeriod period,
) {
  final selected = _dateOnly(date);
  final days = <DateTime>[];
  if (period == _StatisticsPeriod.days) {
    days.addAll(
      List.generate(7, (index) => selected.subtract(Duration(days: 6 - index))),
    );
  } else if (period == _StatisticsPeriod.weeks) {
    final first = DateTime(selected.year, selected.month, 1);
    final last = DateTime(selected.year, selected.month + 1, 0);
    for (
      var day = first;
      !day.isAfter(last);
      day = day.add(const Duration(days: 1))
    ) {
      days.add(day);
    }
  } else {
    for (var month = 1; month <= 12; month++) {
      days.add(DateTime(selected.year, month, 1));
    }
  }
  if (period == _StatisticsPeriod.days) {
    return [
      for (final day in days)
        _StackBucket(
          '${day.month}/${day.day}',
          snapshot.secondsByDayAndBook[day] ?? const {},
        ),
    ];
  }
  if (period == _StatisticsPeriod.weeks) {
    final grouped = <DateTime, Map<String, int>>{};
    for (final day in days) {
      final weekStart = day.subtract(Duration(days: day.weekday - 1));
      final bucket = grouped.putIfAbsent(weekStart, () => <String, int>{});
      for (final entry
          in snapshot.secondsByDayAndBook[day]?.entries ??
              const Iterable<MapEntry<String, int>>.empty()) {
        bucket.update(
          entry.key,
          (value) => value + entry.value,
          ifAbsent: () => entry.value,
        );
      }
    }
    return [
      for (final entry in grouped.entries)
        _StackBucket('${entry.key.month}/${entry.key.day}', entry.value),
    ];
  }
  final grouped = <int, Map<String, int>>{
    for (var month = 1; month <= 12; month++) month: <String, int>{},
  };
  for (final entry in snapshot.secondsByDayAndBook.entries) {
    if (entry.key.year != selected.year) continue;
    final bucket = grouped[entry.key.month]!;
    for (final book in entry.value.entries) {
      bucket.update(
        book.key,
        (value) => value + book.value,
        ifAbsent: () => book.value,
      );
    }
  }
  const monthLabels = [
    '1月',
    '2月',
    '3月',
    '4月',
    '5月',
    '6月',
    '7月',
    '8月',
    '9月',
    '10月',
    '11月',
    '12月',
  ];
  return [
    for (var month = 1; month <= 12; month++)
      _StackBucket(monthLabels[month - 1], grouped[month]!),
  ];
}

Map<int, int> _hoursForDate(ReadingStatisticsSnapshot snapshot, DateTime date) {
  final hours = <int, int>{};
  final day = _dateOnly(date);
  for (final event in snapshot.events) {
    if (event.kind == ReadingStatisticsEventKind.duration &&
        _dateOnly(event.occurredAt) == day) {
      hours.update(
        event.occurredAt.hour,
        (value) => value + event.seconds,
        ifAbsent: () => event.seconds,
      );
    }
  }
  return hours;
}

int _bucketTotal(_StackBucket bucket, List<String> bookIds) =>
    bookIds.fold<int>(
      0,
      (sum, id) =>
          sum +
          (id == '__other__'
              ? _otherSeconds(bucket, bookIds)
              : (bucket.secondsByBook[id] ?? 0)),
    );

int _otherSeconds(_StackBucket bucket, List<String> bookIds) {
  final visible = bookIds.where((id) => id != '__other__').toSet();
  return bucket.secondsByBook.entries
      .where((entry) => !visible.contains(entry.key))
      .fold<int>(0, (sum, entry) => sum + entry.value);
}

DateTime? _heatmapDateAt(Offset position, Size size, DateTime startDate) {
  const rows = 7;
  const gap = 2.0;
  const days = 365;
  final start = _dateOnly(startDate);
  final offset = start.weekday - 1;
  final columns = ((offset + days) / rows).ceil();
  final cell = math.min(
    (size.width - (columns - 1) * gap) / columns,
    (size.height - (rows - 1) * gap) / rows,
  );
  if (cell <= 0) return null;
  final col = (position.dx / (cell + gap)).floor();
  final row = (position.dy / (cell + gap)).floor();
  final index = col * rows + row - offset;
  if (col < 0 ||
      col >= columns ||
      row < 0 ||
      row >= rows ||
      index < 0 ||
      index >= days) {
    return null;
  }
  return start.add(Duration(days: index));
}

double _level(int seconds) {
  if (seconds <= 0) return 0;
  if (seconds < 600) return .25;
  if (seconds < 1800) return .45;
  if (seconds < 3600) return .68;
  return .92;
}

void _drawText(
  Canvas canvas,
  String text,
  Offset origin,
  Color color, {
  required double fontSize,
  bool centered = false,
}) {
  final paragraph = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: fontSize),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  paragraph.paint(
    canvas,
    centered ? Offset(origin.dx - paragraph.width / 2, origin.dy) : origin,
  );
}

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';

String _formatDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分钟';
  if (hours > 0) return '$hours 小时';
  if (minutes > 0) return '$minutes 分钟';
  return '$seconds 秒';
}
