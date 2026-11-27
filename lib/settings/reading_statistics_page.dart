import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/settings/reading_statistics.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_solid_surface.dart';
import 'package:wild/widgets/ios_top_bar_backdrop.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/widgets/platform_controls.dart';

class _SourceFilterChoice {
  const _SourceFilterChoice(this.source);
  final SourceId? source;

  @override
  bool operator ==(Object other) =>
      other is _SourceFilterChoice && other.source == source;

  @override
  int get hashCode => source.hashCode;
}

class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  SourceId? _source;
  late final ValueNotifier<DateTime> _selectedDate = ValueNotifier<DateTime>(
    _dateOnly(context.read<ReadingStatisticsCubit>().currentTime),
  );

  List<ReadingStatisticsEvent>? _cachedEvents;
  SourceId? _cachedSource;
  bool _hasCachedSnapshot = false;
  late ReadingStatisticsSnapshot _cachedSnapshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ReadingStatisticsCubit>().initialize();
    });
  }

  @override
  void dispose() {
    _selectedDate.dispose();
    super.dispose();
  }

  ReadingStatisticsSnapshot _snapshotFor(
    ReadingStatisticsCubit cubit,
    ReadingStatisticsState state,
  ) {
    if (!_hasCachedSnapshot ||
        !identical(_cachedEvents, state.events) ||
        _cachedSource != _source) {
      _cachedSnapshot = cubit.snapshot(source: _source);
      _cachedEvents = state.events;
      _cachedSource = _source;
      _hasCachedSnapshot = true;
    }
    return _cachedSnapshot;
  }

  Widget _buildSourceFilterAction(BuildContext context) {
    final menuButton = Semantics(
      label: '选择统计书源',
      button: true,
      child: AppPopupMenuButton<_SourceFilterChoice>(
        key: const ValueKey('statistics-source-filter'),
        tooltip: '选择统计书源',
        icon: const Icon(Icons.filter_list_rounded),
        onSelected: (choice) {
          if (_source != choice.source) {
            setState(() => _source = choice.source);
          }
        },
        itemBuilder:
            (context) => [
              CheckedPopupMenuItem(
                value: const _SourceFilterChoice(null),
                checked: _source == null,
                child: const Text('全部书源'),
              ),
              for (final source in SourceId.values)
                CheckedPopupMenuItem(
                  value: _SourceFilterChoice(source),
                  checked: _source == source,
                  child: Text(source.label),
                ),
            ],
      ),
    );
    if (!usesAppleGlass) return menuButton;
    // Mirror settingsAppBar's 60dp leading slot (16dp start + 44dp circle)
    // so the title stays centered and the trailing glass menu keeps a 16dp margin.
    return SizedBox(
      width: 60,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 16),
        child: Center(child: SizedBox.square(dimension: 44, child: menuButton)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ReadingStatisticsCubit, ReadingStatisticsState>(
      builder: (context, state) {
        final cubit = context.read<ReadingStatisticsCubit>();
        final snapshot = _snapshotFor(cubit, state);
        final today = _dateOnly(cubit.currentTime);
        final sourceName = _source?.label ?? '全部书源';
        return IosTopBarScaffold(
          appBar: settingsAppBar(
            context,
            '阅读统计',
            actions: [_buildSourceFilterAction(context)],
          ),
          body:
              state.initialized
                  ? _StatisticsOverview(
                    snapshot: snapshot,
                    today: today,
                    sourceName: sourceName,
                    selectedDate: _selectedDate,
                    onSelectDate: (date) {
                      final normalized = _dateOnly(date);
                      if (_selectedDate.value != normalized) {
                        _selectedDate.value = normalized;
                      }
                    },
                    onOpenDetails:
                        () => openSettingsPage(
                          context,
                          ReadingStatisticsDetailPage(
                            date: _selectedDate.value,
                            source: _source,
                          ),
                        ),
                    warning: state.warning,
                  )
                  : const Center(child: AppLoadingIndicator()),
        );
      },
    );
  }
}

class _StatisticsOverview extends StatelessWidget {
  const _StatisticsOverview({
    required this.snapshot,
    required this.today,
    required this.sourceName,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDetails,
    required this.warning,
  });

  final ReadingStatisticsSnapshot snapshot;
  final DateTime today;
  final String sourceName;
  final ValueListenable<DateTime> selectedDate;
  final ValueChanged<DateTime> onSelectDate;
  final VoidCallback onOpenDetails;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LeftAlignedScrollView(
      topInset: 8,
      bottomInset: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              '统计书源：$sourceName',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          if (warning != null) ...[
            _NoticeCard(message: warning!),
            const SizedBox(height: 12),
          ],
          _SummaryCard(snapshot: snapshot),
          const SizedBox(height: 14),
          _StatisticsActivityAndHourly(
            snapshot: snapshot,
            today: today,
            selectedDate: selectedDate,
            onSelectDate: onSelectDate,
            onOpenDetails: onOpenDetails,
          ),
        ],
      ),
    );
  }
}

class _StatisticsActivityAndHourly extends StatefulWidget {
  const _StatisticsActivityAndHourly({
    required this.snapshot,
    required this.today,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDetails,
  });

  final ReadingStatisticsSnapshot snapshot;
  final DateTime today;
  final ValueListenable<DateTime> selectedDate;
  final ValueChanged<DateTime> onSelectDate;
  final VoidCallback onOpenDetails;

  @override
  State<_StatisticsActivityAndHourly> createState() =>
      _StatisticsActivityAndHourlyState();
}

class _StatisticsActivityAndHourlyState
    extends State<_StatisticsActivityAndHourly> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ValueListenableBuilder<DateTime>(
      valueListenable: widget.selectedDate,
      builder: (context, selectedDate, _) {
        final todaysSeconds = widget.snapshot.secondsForDay(selectedDate);
        final todaysBooks =
            widget.snapshot.secondsByDayAndBook[selectedDate] ??
            const <String, int>{};
        final rankedBooks =
            todaysBooks.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));
        final dayHours = widget.snapshot.hoursForDay(selectedDate);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionCard(
              title: '阅读活动',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ActivityHeatmap(
                    values: widget.snapshot.secondsByDay,
                    today: widget.today,
                    selectedDate: selectedDate,
                    selectedSeconds: todaysSeconds,
                    isEmptySnapshot: widget.snapshot.isEmpty,
                    onSelectDate: widget.onSelectDate,
                  ),
                  const SizedBox(height: 12),
                  Divider(
                    height: 1,
                    color: colors.outlineVariant.withValues(alpha: .55),
                  ),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration:
                        reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 150),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: _SelectedDayDetails(
                      key: ValueKey((
                        selectedDate,
                        todaysSeconds,
                        widget.snapshot,
                      )),
                      date: selectedDate,
                      today: widget.today,
                      totalSeconds: todaysSeconds,
                      rankedBooks: rankedBooks,
                      titlesByBook: widget.snapshot.titlesByBook,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: '阅读时段',
              subtitle: _relativeDayTitle(selectedDate, widget.today),
              child: _HourlyChart(values: dayHours),
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: '按书籍查看趋势',
              subtitle: '选中日期：${_dateLabel(selectedDate)}',
              child:
                  usesAppleGlass
                      ? IosAccentPillButton(
                        buttonKey: const ValueKey('statistics-open-details'),
                        label: '查看详情',
                        icon: CupertinoIcons.chart_bar,
                        fullWidth: true,
                        minHeight: 48,
                        onPressed: widget.onOpenDetails,
                      )
                      : Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppButton.tonalIcon(
                          onPressed: widget.onOpenDetails,
                          icon: const Icon(Icons.bar_chart_rounded),
                          label: const Text('查看详情'),
                        ),
                      ),
            ),
          ],
        );
      },
    );
  }
}

class _SelectedDayDetails extends StatelessWidget {
  const _SelectedDayDetails({
    super.key,
    required this.date,
    required this.today,
    required this.totalSeconds,
    required this.rankedBooks,
    required this.titlesByBook,
  });

  final DateTime date;
  final DateTime today;
  final int totalSeconds;
  final List<MapEntry<String, int>> rankedBooks;
  final Map<String, String> titlesByBook;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final badgeBackground =
        usesAppleGlass
            ? colors.primary.withValues(alpha: .12)
            : colors.primaryContainer;
    final badgeForeground =
        usesAppleGlass ? colors.primary : colors.onPrimaryContainer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _relativeDayTitle(date, today),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: badgeBackground,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _formatDuration(totalSeconds),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: badgeForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (rankedBooks.isEmpty)
          Text(
            '这一天还没有阅读记录。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          )
        else
          ...rankedBooks
              .take(3)
              .map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          titlesByBook[entry.key] ?? entry.key,
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
    );
  }
}

class _ActivityHeatmap extends StatelessWidget {
  const _ActivityHeatmap({
    required this.values,
    required this.today,
    required this.selectedDate,
    required this.selectedSeconds,
    required this.isEmptySnapshot,
    required this.onSelectDate,
  });

  final Map<DateTime, int> values;
  final DateTime today;
  final DateTime selectedDate;
  final int selectedSeconds;
  final bool isEmptySnapshot;
  final ValueChanged<DateTime> onSelectDate;

  static const _days = 365;
  static const _rows = 7;
  static const _gutterWidth = 22.0;
  static const _gutterGap = 6.0;
  static const _topAxisHeight = 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final baseColor =
        usesAppleGlass
            ? CupertinoColors.tertiarySystemFill.resolveFrom(context)
            : Color.alphaBlend(
              colors.onSurface.withValues(alpha: dark ? .14 : .08),
              colors.surfaceContainerLow,
            );
    final activeColor = colors.primary;
    final startDate = _dateOnly(
      today.subtract(const Duration(days: _days - 1)),
    );
    final offset = startDate.weekday - 1;
    final columns = ((offset + _days) / _rows).ceil();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = math.max(
          0.0,
          constraints.maxWidth - _gutterWidth - _gutterGap,
        );
        final metrics = _HeatmapMetrics.compute(
          viewportWidth: viewportWidth,
          columns: columns,
          rows: _rows,
          topAxisHeight: _topAxisHeight,
        );
        final monthMarkers = _monthMarkers(startDate, offset, columns);
        final gridWidget = Semantics(
          label:
              '阅读活动热力图，当前选中 ${_dateLabel(selectedDate)}，阅读 ${_formatDuration(selectedSeconds)}',
          hint: metrics.scrollable ? '点按日期格切换明细，左右滑动查看近一年记录' : '点按日期格切换明细',
          child: SizedBox(
            height: metrics.totalHeight,
            child: SingleChildScrollView(
              key: const ValueKey('statistics-heatmap-scroll'),
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: GestureDetector(
                key: const ValueKey('statistics-heatmap-surface'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final date = _heatmapDateAt(
                    details.localPosition,
                    metrics,
                    startDate,
                    offset,
                    _days,
                  );
                  if (date != null) onSelectDate(date);
                },
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const ValueKey('statistics-heatmap-paint'),
                    size: Size(metrics.canvasWidth, metrics.totalHeight),
                    painter: _HeatmapPainter(
                      values: values,
                      selectedDate: selectedDate,
                      startDate: startDate,
                      offset: offset,
                      days: _days,
                      metrics: metrics,
                      monthMarkers: monthMarkers,
                      base: baseColor,
                      active: activeColor,
                      outline: colors.onSurface,
                      innerRing:
                          usesAppleGlass
                              ? colors.surface
                              : colors.surfaceContainerLow,
                      axisColor: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _gutterWidth,
                  height: metrics.totalHeight,
                  child: _WeekdayGutter(
                    topOffset: metrics.topAxisHeight,
                    cell: metrics.cell,
                    gap: metrics.gap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: _gutterGap),
                Expanded(child: gridWidget),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 6,
              children: [
                Text(
                  isEmptySnapshot ? '开始阅读后，活动格子会逐步点亮' : '近 1 年',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                _HeatmapLegend(
                  baseColor: baseColor,
                  activeColor: activeColor,
                  labelColor: colors.onSurfaceVariant,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _WeekdayGutter extends StatelessWidget {
  const _WeekdayGutter({
    required this.topOffset,
    required this.cell,
    required this.gap,
    required this.color,
  });

  final double topOffset;
  final double cell;
  final double gap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const labels = <int, String>{0: '一', 2: '三', 4: '五', 6: '日'};
    return Stack(
      children: [
        for (final entry in labels.entries)
          Positioned(
            top: topOffset + entry.key * (cell + gap),
            left: 0,
            right: 0,
            height: cell,
            child: Center(
              child: Text(
                entry.value,
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: 10, height: 1, color: color),
              ),
            ),
          ),
      ],
    );
  }
}

class _HeatmapLegend extends StatelessWidget {
  const _HeatmapLegend({
    required this.baseColor,
    required this.activeColor,
    required this.labelColor,
  });

  final Color baseColor;
  final Color activeColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    const levels = [0.0, .30, .52, .76, 1.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '少',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: labelColor),
        ),
        const SizedBox(width: 6),
        for (var i = 0; i < levels.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: Color.lerp(baseColor, activeColor, levels[i]),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text(
          '多',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: labelColor),
        ),
      ],
    );
  }
}

class _HeatmapMetrics {
  const _HeatmapMetrics({
    required this.cell,
    required this.gap,
    required this.columns,
    required this.rows,
    required this.topAxisHeight,
    required this.canvasWidth,
    required this.scrollable,
  });

  final double cell;
  final double gap;
  final int columns;
  final int rows;
  final double topAxisHeight;
  final double canvasWidth;
  final bool scrollable;

  double get totalHeight => topAxisHeight + rows * cell + (rows - 1) * gap;

  factory _HeatmapMetrics.compute({
    required double viewportWidth,
    required int columns,
    required int rows,
    required double topAxisHeight,
  }) {
    final gap = viewportWidth >= 700 ? 3.0 : 4.0;
    final fitCell =
        columns > 0 ? (viewportWidth - (columns - 1) * gap) / columns : 15.0;
    final fitsAll = fitCell >= 13.5;
    final cell =
        fitsAll
            ? fitCell.clamp(13.5, 18.0).toDouble()
            : (viewportWidth < 300 ? 14.0 : 15.0);
    final rawWidth = columns * cell + math.max(0, columns - 1) * gap;
    final canvasWidth = math.max(viewportWidth, rawWidth);
    return _HeatmapMetrics(
      cell: cell,
      gap: gap,
      columns: columns,
      rows: rows,
      topAxisHeight: topAxisHeight,
      canvasWidth: canvasWidth,
      scrollable: !fitsAll && rawWidth > viewportWidth + 1,
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

  List<ReadingStatisticsEvent>? _cachedEvents;
  SourceId? _cachedSource;
  bool _hasCachedSnapshot = false;
  late ReadingStatisticsSnapshot _cachedSnapshot;

  ReadingStatisticsSnapshot? _bucketsSnapshot;
  DateTime? _bucketsDate;
  _StatisticsPeriod? _bucketsPeriod;
  List<_StackBucket> _cachedBuckets = const [];

  ReadingStatisticsSnapshot _snapshotFor(
    ReadingStatisticsCubit cubit,
    ReadingStatisticsState state,
  ) {
    if (!_hasCachedSnapshot ||
        !identical(_cachedEvents, state.events) ||
        _cachedSource != widget.source) {
      _cachedSnapshot = cubit.snapshot(source: widget.source);
      _cachedEvents = state.events;
      _cachedSource = widget.source;
      _hasCachedSnapshot = true;
    }
    return _cachedSnapshot;
  }

  List<_StackBucket> _bucketsFor(ReadingStatisticsSnapshot snapshot) {
    final normalized = _dateOnly(widget.date);
    if (!identical(_bucketsSnapshot, snapshot) ||
        _bucketsDate != normalized ||
        _bucketsPeriod != _period) {
      _cachedBuckets = _makeBuckets(snapshot, normalized, _period);
      _bucketsSnapshot = snapshot;
      _bucketsDate = normalized;
      _bucketsPeriod = _period;
    }
    return _cachedBuckets;
  }

  @override
  Widget build(BuildContext context) {
    final sourceLabel = widget.source?.label ?? '全部书源';
    final colors = Theme.of(context).colorScheme;
    return BlocBuilder<ReadingStatisticsCubit, ReadingStatisticsState>(
      builder: (context, state) {
        final snapshot = _snapshotFor(
          context.read<ReadingStatisticsCubit>(),
          state,
        );
        final buckets = _bucketsFor(snapshot);
        final dayHours = snapshot.hoursForDay(widget.date);
        final periodLabel = switch (_period) {
          _StatisticsPeriod.days => '近 7 天',
          _StatisticsPeriod.weeks => '本月各周',
          _StatisticsPeriod.months => '本年各月',
        };
        return IosTopBarScaffold(
          appBar: settingsAppBar(context, '阅读趋势'),
          body: LeftAlignedScrollView(
            topInset: 8,
            bottomInset: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    '统计书源：$sourceLabel',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Center(
                  child: AppSegmentedButton<_StatisticsPeriod>(
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
                  child: _HourlyChart(values: dayHours),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  title: '统计摘要',
                  subtitle: '$sourceLabel · 本地累积',
                  child: LayoutBuilder(
                    builder:
                        (context, constraints) => _MetricsGrid(
                          constraints: constraints,
                          totalValue: _formatDuration(snapshot.totalSeconds),
                          sessionValue: '${snapshot.sessionCount} 次',
                          daysValue: '${snapshot.activeDays} 天',
                          totalLabel: '阅读时长',
                          sessionLabel: '阅读会话',
                          daysLabel: '活跃天数',
                          color: colors.onSurface,
                          mutedColor: colors.onSurfaceVariant,
                        ),
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
    final valueColor =
        usesAppleGlass ? colors.onSurface : colors.onSecondaryContainer;
    final labelColor =
        usesAppleGlass ? colors.onSurfaceVariant : colors.onSecondaryContainer;
    return SettingsCard(
      color: usesAppleGlass ? null : colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder:
              (context, constraints) => _MetricsGrid(
                constraints: constraints,
                totalValue:
                    empty ? '—' : _formatDuration(snapshot.totalSeconds),
                sessionValue: empty ? '—' : '${snapshot.sessionCount} 次',
                daysValue: empty ? '—' : '${snapshot.activeDays} 天',
                totalLabel: '累计阅读',
                sessionLabel: '阅读会话',
                daysLabel: '阅读天数',
                color: valueColor,
                mutedColor: labelColor,
              ),
        ),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({
    required this.constraints,
    required this.totalValue,
    required this.sessionValue,
    required this.daysValue,
    required this.totalLabel,
    required this.sessionLabel,
    required this.daysLabel,
    required this.color,
    required this.mutedColor,
  });

  final BoxConstraints constraints;
  final String totalValue;
  final String sessionValue;
  final String daysValue;
  final String totalLabel;
  final String sessionLabel;
  final String daysLabel;
  final Color color;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    final wide = constraints.maxWidth >= 520;
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Metric(
              label: totalLabel,
              value: totalValue,
              emphasize: true,
              valueColor: color,
              labelColor: mutedColor,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: _Metric(
              label: sessionLabel,
              value: sessionValue,
              valueColor: color,
              labelColor: mutedColor,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: _Metric(
              label: daysLabel,
              value: daysValue,
              valueColor: color,
              labelColor: mutedColor,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Metric(
          label: totalLabel,
          value: totalValue,
          emphasize: true,
          valueColor: color,
          labelColor: mutedColor,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Metric(
                label: sessionLabel,
                value: sessionValue,
                valueColor: color,
                labelColor: mutedColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _Metric(
                label: daysLabel,
                value: daysValue,
                valueColor: color,
                labelColor: mutedColor,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.valueColor,
    this.labelColor,
  });
  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: labelColor ?? colors.onSecondaryContainer,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            style: (emphasize
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.titleLarge)
                ?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? colors.onSecondaryContainer,
                ),
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    this.subtitle,
    required this.child,
  });
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final subtitleText = subtitle;
    return SettingsCard(
      color:
          usesAppleGlass
              ? null
              : settingsSurfaceLayer(colors, colors.surfaceContainerLow, .04),
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
            if (subtitleText != null && subtitleText.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                subtitleText,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
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
    return SettingsCard(
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
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _HourlyPainter(
            values: values,
            bar: colors.primary,
            selected: colors.tertiary,
            grid: colors.outlineVariant,
            label: colors.onSurfaceVariant,
          ),
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
  late List<String> _books;
  late List<String> _displayedBooks;

  @override
  void initState() {
    super.initState();
    _recomputeLegend();
  }

  @override
  void didUpdateWidget(covariant _StackedBookChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.buckets, widget.buckets)) {
      _selected = -1;
      _recomputeLegend();
    }
  }

  void _recomputeLegend() {
    _books =
        <String>{
            for (final bucket in widget.buckets) ...bucket.secondsByBook.keys,
          }.toList()
          ..sort((a, b) => _sumForBook(b).compareTo(_sumForBook(a)));
    _displayedBooks = _books.take(5).toList();
    if (_books.length > 5) _displayedBooks.add('__other__');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
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
                  onTapUp: (details) {
                    final index = (details.localPosition.dx /
                            (width / widget.buckets.length))
                        .floor()
                        .clamp(0, widget.buckets.length - 1);
                    setState(() => _selected = index);
                  },
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size(width, 188),
                      painter: _StackedPainter(
                        buckets: widget.buckets,
                        bookIds: _displayedBooks,
                        colors: palette,
                        labels: colors.onSurfaceVariant,
                        grid: colors.outlineVariant,
                        selectedIndex: _selected,
                      ),
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
            for (var i = 0; i < _displayedBooks.length; i++)
              _LegendItem(
                color: palette[i],
                label:
                    _displayedBooks[i] == '__other__'
                        ? '其他书籍'
                        : (widget.titles[_displayedBooks[i]] ??
                            _displayedBooks[i]),
              ),
          ],
        ),
        if (_books.isEmpty) const _EmptyChart(message: '没有书籍阅读时长。'),
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

class _MonthMarker {
  const _MonthMarker(this.column, this.label);
  final int column;
  final String label;
}

List<_MonthMarker> _monthMarkers(DateTime start, int offset, int columns) {
  final markers = <_MonthMarker>[];
  var lastMonth = -1;
  var lastCol = -4;
  for (var col = 0; col < columns; col++) {
    for (var row = 0; row < 7; row++) {
      final index = col * 7 + row - offset;
      if (index < 0 || index >= 365) continue;
      final date = start.add(Duration(days: index));
      if (date.month != lastMonth && (date.day <= 7 || col == 0)) {
        lastMonth = date.month;
        if (col - lastCol >= 3) {
          markers.add(_MonthMarker(col, '${date.month}月'));
          lastCol = col;
        }
        break;
      }
    }
  }
  return markers;
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.values,
    required this.selectedDate,
    required this.startDate,
    required this.offset,
    required this.days,
    required this.metrics,
    required this.monthMarkers,
    required this.base,
    required this.active,
    required this.outline,
    required this.innerRing,
    required this.axisColor,
  });

  final Map<DateTime, int> values;
  final DateTime selectedDate;
  final DateTime startDate;
  final int offset;
  final int days;
  final _HeatmapMetrics metrics;
  final List<_MonthMarker> monthMarkers;
  final Color base;
  final Color active;
  final Color outline;
  final Color innerRing;
  final Color axisColor;

  @override
  void paint(Canvas canvas, Size size) {
    final start = _dateOnly(startDate);
    final selected = _dateOnly(selectedDate);
    final pitch = metrics.cell + metrics.gap;
    final cell = metrics.cell;
    final radius = Radius.circular(math.min(4.0, cell * .24));

    for (final marker in monthMarkers) {
      final x = marker.column * pitch;
      if (x + 24 > size.width) continue;
      _drawText(canvas, marker.label, Offset(x, 1), axisColor, fontSize: 10);
    }

    final fillPaint = Paint()..style = PaintingStyle.fill;
    RRect? selectedRect;

    for (var index = 0; index < days; index++) {
      final date = start.add(Duration(days: index));
      final col = (offset + index) ~/ metrics.rows;
      final row = (offset + index) % metrics.rows;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          col * pitch,
          metrics.topAxisHeight + row * pitch,
          cell,
          cell,
        ),
        radius,
      );
      final level = _level(values[date] ?? 0);
      fillPaint.color = level == 0 ? base : Color.lerp(base, active, level)!;
      canvas.drawRRect(rect, fillPaint);
      if (date == selected) selectedRect = rect;
    }

    if (selectedRect != null) {
      final innerPaint =
          Paint()
            ..color = innerRing
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6;
      canvas.drawRRect(selectedRect.deflate(1.0), innerPaint);
      final outerPaint =
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8;
      canvas.drawRRect(selectedRect, outerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) =>
      old.values != values ||
      old.selectedDate != selectedDate ||
      old.startDate != startDate ||
      old.offset != offset ||
      old.days != days ||
      old.metrics.cell != metrics.cell ||
      old.metrics.gap != metrics.gap ||
      old.metrics.canvasWidth != metrics.canvasWidth ||
      old.base != base ||
      old.active != active ||
      old.outline != outline ||
      old.innerRing != innerRing ||
      old.axisColor != axisColor;
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

DateTime? _heatmapDateAt(
  Offset position,
  _HeatmapMetrics metrics,
  DateTime startDate,
  int offset,
  int days,
) {
  if (position.dy < metrics.topAxisHeight) return null;
  final pitch = metrics.cell + metrics.gap;
  if (pitch <= 0) return null;
  final col = (position.dx / pitch).floor();
  final row = ((position.dy - metrics.topAxisHeight) / pitch).floor();
  final index = col * metrics.rows + row - offset;
  if (col < 0 ||
      col >= metrics.columns ||
      row < 0 ||
      row >= metrics.rows ||
      index < 0 ||
      index >= days) {
    return null;
  }
  return _dateOnly(startDate).add(Duration(days: index));
}

double _level(int seconds) {
  if (seconds <= 0) return 0;
  if (seconds < 600) return .30;
  if (seconds < 1800) return .52;
  if (seconds < 3600) return .76;
  return 1.0;
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

String _relativeDayTitle(DateTime date, DateTime today) {
  final normalized = _dateOnly(date);
  final normalizedToday = _dateOnly(today);
  if (normalized == normalizedToday) {
    return '今天 · ${normalized.month}月${normalized.day}日';
  }
  if (normalized == normalizedToday.subtract(const Duration(days: 1))) {
    return '昨天 · ${normalized.month}月${normalized.day}日';
  }
  return _dateLabel(normalized);
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分钟';
  if (hours > 0) return '$hours 小时';
  if (minutes > 0) return '$minutes 分钟';
  return '$seconds 秒';
}
