import 'dart:math' as math;

import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../errors.dart';
import '../formatters.dart';
import '../mappers/mapper_support.dart';
import '../mappers/to_table.dart';
import '../runner.dart';
import 'chart_internals.dart';

/// A table backed by an analytics query, styled by a `hand_drawn_toolkit`
/// [HandDrawnTable] template.
///
/// Any result shape is renderable as a table (the totality guarantee), so this
/// widget accepts a [SingleQuerySpec] of any single shape and projects it with
/// [resultToTable]. [chart] is the chrome template — pass it with empty
/// `columns`/`rows` (`const []`); the bridge fills both. When the upstream
/// result was truncated (e.g. by `limit`), a footer row reports the hidden
/// count; customize it with [truncatedFooterBuilder].
///
/// ## Resizable columns
///
/// Set [resizable] to let the consumer drag column boundaries. Widths are
/// consumer-owned: pass restored widths via [initialColumnWidths] and persist
/// changes reported through [onColumnWidthsChanged]. When [resizable] is false
/// (the default) the table uses the template's own column sizing and adds no
/// drag layer. The rendering itself is delegated to [HandDrawnTableView]; a
/// spec-driven dashboard reaches the same resizable rendering by returning a
/// [HandDrawnTableView] from an `AnalyticsWidgetBuilders.table` builder.
class HandDrawnAnalyticsTable extends StatelessWidget {
  const HandDrawnAnalyticsTable({
    // Analytics inputs.
    required this.query,
    required this.chart,
    this.runner,
    this.formatters,
    this.dateRangeMode = const NoDateRange(),
    this.pageRange,
    this.earliestDataDate,
    this.today,
    // Bridge knobs.
    this.showTruncationFooter = true,
    this.truncatedFooterBuilder,
    this.resizable = false,
    this.initialColumnWidths,
    this.onColumnWidthsChanged,
    super.key,
  });

  // Analytics inputs.
  final SingleQuerySpec query;
  final HandDrawnTable chart;
  final WidgetQueryRunner? runner;
  final BridgeFormatters? formatters;
  final DateRangeMode dateRangeMode;
  final (DateTime, DateTime)? pageRange;
  final DateTime? earliestDataDate;
  final DateTime? today;

  // Bridge knobs.
  /// Whether to append a footer row noting truncated rows. Defaults to true.
  final bool showTruncationFooter;

  /// Builds the footer label for [truncatedCount] hidden rows. Defaults to
  /// "+N more".
  final String Function(int truncatedCount)? truncatedFooterBuilder;

  /// Whether columns can be resized by dragging their boundaries. Defaults to
  /// false, in which case the table uses the template's column sizing.
  final bool resizable;

  /// Initial column pixel widths, one per data column. Applied when [resizable]
  /// is true and the length matches the rendered column count; otherwise
  /// columns fall back to default sizing.
  final List<double>? initialColumnWidths;

  /// Called with the full width list after a drag settles and whenever widths
  /// reset to defaults (e.g. on a column-count change). The consumer persists
  /// these.
  final void Function(List<double> widths)? onColumnWidthsChanged;

  @override
  Widget build(BuildContext context) {
    final config = resolveChartConfig(
      context,
      runner: runner,
      formatters: formatters,
    );

    return switch (config) {
      Err(error: final e) => _emptyState(e),
      Ok(value: final c) => buildChartHost(
        runner: c.runner,
        payload: query,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: today,
        loading: (_) => chart,
        error: (_, e) => _emptyState(e),
        data: (context, result) => _buildData(c, result),
      ),
    };
  }

  Widget _buildData(ResolvedChartConfig config, BridgeResult result) {
    if (result is! SingleResult) {
      return _emptyState(
        BridgeShapeMismatch(
          expected: ResultShape.table,
          actual: bridgeShapeOf(result),
          suggestion: 'a single (non-paired) query',
        ),
      );
    }

    final mapped = resultToTable(result.result, formatters: config.formatters);
    return switch (mapped) {
      Err(error: final e) => _emptyState(e),
      Ok(value: final mapping) => HandDrawnTableView(
        mapping: mapping,
        chart: chart,
        showTruncationFooter: showTruncationFooter,
        truncatedFooterBuilder: truncatedFooterBuilder,
        resizable: resizable,
        initialColumnWidths: initialColumnWidths,
        onColumnWidthsChanged: onColumnWidthsChanged,
      ),
    };
  }

  Widget _emptyState(BridgeError error) {
    return chart.copyWith(
      columns: const [HandDrawnTableColumn(header: '')],
      rows: const [],
      emptyMessage: error.humanMessage,
    );
  }
}

/// Renders an already-mapped [TableMapping] into a [HandDrawnTable] template,
/// optionally with resizable columns.
///
/// This is the presentational half of the table feature, split from
/// [HandDrawnAnalyticsTable] so the spec-driven path (where the bridge has
/// already mapped the result) can render the same table — including resizing —
/// from an `AnalyticsWidgetBuilders.table` builder, which receives a
/// [TableMapping] rather than a query.
///
/// When [resizable] is false it pours the mapping into [chart] directly. When
/// true it overlays draggable boundary handles and manages live widths:
/// [initialColumnWidths] restores a saved layout (when its length matches the
/// data-column count) and [onColumnWidthsChanged] reports changes for the
/// consumer to persist. A change in column count resets widths to defaults and
/// reports the reset, since saved widths describe one column shape.
class HandDrawnTableView extends StatefulWidget {
  const HandDrawnTableView({
    required this.mapping,
    required this.chart,
    this.showTruncationFooter = true,
    this.truncatedFooterBuilder,
    this.resizable = false,
    this.initialColumnWidths,
    this.onColumnWidthsChanged,
    super.key,
  });

  /// The bridge-mapped table data to render.
  final TableMapping mapping;

  /// The styling template; its `columns`/`rows` are replaced by the mapping.
  final HandDrawnTable chart;

  /// Whether to append a footer row noting truncated rows. Defaults to true.
  final bool showTruncationFooter;

  /// Builds the footer label for the hidden-row count. Defaults to "+N more".
  final String Function(int truncatedCount)? truncatedFooterBuilder;

  /// Whether columns can be resized by dragging their boundaries.
  final bool resizable;

  /// Initial column pixel widths, one per data column. Applied when [resizable]
  /// is true and the length matches the column count.
  final List<double>? initialColumnWidths;

  /// Called with the full width list after a drag settles and on any reset.
  final void Function(List<double> widths)? onColumnWidthsChanged;

  @override
  State<HandDrawnTableView> createState() => _HandDrawnTableViewState();
}

class _HandDrawnTableViewState extends State<HandDrawnTableView> {
  static const _minColumnWidth = 40.0;
  static const _handleWidth = 16.0;

  /// Live column widths, or null until first computed against a known layout
  /// width. Length always tracks the current data-column count.
  List<double>? _widths;

  /// The last width list handed to [HandDrawnTableView.onColumnWidthsChanged].
  /// Suppresses a repeat report of the same effective widths (e.g. when a
  /// parent binds the callback to `setState` and rebuilds).
  List<double>? _lastReported;

  @override
  Widget build(BuildContext context) {
    final mapping = widget.mapping;
    final rows = _rowsWithFooter(mapping);
    if (!widget.resizable) {
      return widget.chart.copyWith(columns: mapping.columns, rows: rows);
    }
    return _resizable(mapping, rows);
  }

  /// The mapped rows plus the truncation footer row when applicable. The footer
  /// is padded to the data-column count so the toolkit's per-row cell-count
  /// check holds.
  List<HandDrawnTableRow> _rowsWithFooter(TableMapping mapping) {
    final rows = [...mapping.rows];
    if (widget.showTruncationFooter && mapping.truncatedCount > 0) {
      final label =
          widget.truncatedFooterBuilder?.call(mapping.truncatedCount) ??
          '+${mapping.truncatedCount} more';
      // Footer spans the first column; remaining cells are blank so the row
      // width matches the column count.
      rows.add(
        HandDrawnTableRow(
          cells: [label, for (var i = 1; i < mapping.columns.length; i++) ''],
        ),
      );
    }
    return rows;
  }

  /// Renders the table inside a [Stack] with one draggable handle per interior
  /// column boundary. Width math keys off the data-column count, so the footer
  /// row never affects boundaries.
  Widget _resizable(TableMapping mapping, List<HandDrawnTableRow> rows) {
    final padding = widget.chart.padding;
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth - padding.horizontal;
        _syncWidths(mapping.columns, contentWidth);
        final widths = _widths!;

        final columns = [
          for (var i = 0; i < mapping.columns.length; i++)
            HandDrawnTableColumn(
              header: mapping.columns[i].header,
              alignment: mapping.columns[i].alignment,
              width: widths[i],
            ),
        ];

        return Stack(
          children: [
            widget.chart.copyWith(columns: columns, rows: rows),
            for (var i = 0; i < widths.length - 1; i++)
              Positioned(
                left:
                    padding.left +
                    widths.take(i + 1).fold(0.0, (sum, w) => sum + w) -
                    _handleWidth / 2,
                top: 0,
                bottom: 0,
                width: _handleWidth,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (d) => _onDrag(i, d.delta.dx),
                    onHorizontalDragEnd: (_) => _reportWidths(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Ensures [_widths] is valid for the current columns and [contentWidth].
  ///
  /// Reuses existing widths when the column count is unchanged (preserving a
  /// layout across a same-shape refresh). On a count change — or the first
  /// build — it seeds defaults from any matching [HandDrawnTableView.
  /// initialColumnWidths], else from column [flex] when present, else equal
  /// distribution; a reset that discards stale widths is reported out so the
  /// consumer's stored value tracks the new shape.
  void _syncWidths(List<HandDrawnTableColumn> columns, double contentWidth) {
    if (_widths != null && _widths!.length == columns.length) return;

    final hadWidths = _widths != null;
    final restored = widget.initialColumnWidths;
    if (!hadWidths && restored != null && restored.length == columns.length) {
      _widths = List.of(restored);
      return;
    }

    _widths = _defaultWidths(columns, contentWidth);
    // A count change that discarded prior widths (or ignored a now-stale
    // restored list) must report the reset so persisted widths don't go stale.
    // This runs during layout, so defer the consumer callback to after the
    // frame rather than calling it mid-build.
    if (hadWidths) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reportWidths();
      });
    }
  }

  /// Default pixel widths: proportional to column [flex] when any column
  /// carries it, otherwise an equal split of [contentWidth]. Each width is
  /// floored at [_minColumnWidth] so it stays positive even under a degenerate
  /// (zero or unmeasured) layout width.
  List<double> _defaultWidths(
    List<HandDrawnTableColumn> columns,
    double contentWidth,
  ) {
    final width = contentWidth <= 0 ? 0.0 : contentWidth;
    final totalFlex = columns.fold(0, (sum, c) => sum + c.flex);
    final hasFlexIntent = columns.any((c) => c.flex != 1);
    if (hasFlexIntent && totalFlex > 0) {
      return [
        for (final c in columns)
          math.max(_minColumnWidth, width * c.flex / totalFlex),
      ];
    }
    return [
      for (final _ in columns)
        math.max(_minColumnWidth, width / columns.length),
    ];
  }

  /// Drags the boundary between columns [boundary] and [boundary] + 1, moving
  /// width between them while keeping each at or above [_minColumnWidth] and
  /// the total constant.
  void _onDrag(int boundary, double delta) {
    setState(() {
      final widths = _widths!;
      // Room to move in each direction, floored at zero: a column already at
      // the minimum yields zero room on its shrink side but still allows the
      // boundary to move the other way (growing it back). Flooring keeps the
      // clamp range valid (lower <= upper) without freezing the boundary.
      final maxGrow = math.max(0.0, widths[boundary + 1] - _minColumnWidth);
      final maxShrink = math.max(0.0, widths[boundary] - _minColumnWidth);
      final clamped = delta.clamp(-maxShrink, maxGrow);
      widths[boundary] += clamped;
      widths[boundary + 1] -= clamped;
    });
  }

  void _reportWidths() {
    final widths = _widths;
    if (widths == null) return;
    // Skip a repeat of the same effective widths so binding the callback to
    // setState can't drive a report/rebuild feedback loop.
    if (_lastReported != null && listEquals(_lastReported, widths)) return;
    _lastReported = List.of(widths);
    widget.onColumnWidthsChanged?.call(List.of(widths));
  }
}

/// A prominent single-value display backed by an analytics scalar result.
///
/// Unlike the chart widgets this is a leaf with no toolkit template — there is
/// no upstream big-number widget — so it composes a [HandDrawnContainer] with
/// the value and an optional label. Styling is exposed directly as constructor
/// fields. Pass the already-run [result] (e.g. from a card); a null result
/// renders the loading placeholder.
class HandDrawnAnalyticsBigNumber extends StatelessWidget {
  const HandDrawnAnalyticsBigNumber({
    required this.result,
    this.formatters = const BridgeFormatters(),
    this.title,
    this.valueStyle,
    this.labelStyle,
    this.titleStyle,
    this.color,
    this.backgroundColor,
    this.padding,
    this.loadingPlaceholder,
    super.key,
  });

  /// The scalar result to display, or null while loading.
  final AnalyticsResult? result;
  final BridgeFormatters formatters;

  /// Optional heading above the value.
  final String? title;
  final TextStyle? valueStyle;
  final TextStyle? labelStyle;
  final TextStyle? titleStyle;

  /// Optional value color; falls back to the value text style / theme.
  final Color? color;
  final Color? backgroundColor;
  final EdgeInsets? padding;

  /// Widget shown while [result] is null.
  final Widget? loadingPlaceholder;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    if (result == null) {
      return loadingPlaceholder ?? const SizedBox.shrink();
    }

    final mapped = scalarToBigNumber(result, formatters: formatters);
    return switch (mapped) {
      Err(error: final e) => _container(
        context,
        child: Text(e.humanMessage, style: labelStyle),
      ),
      Ok(value: final big) => _container(
        context,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(title!, style: titleStyle),
              const SizedBox(height: 4),
            ],
            Text(
              big.displayValue,
              style: (valueStyle ?? _defaultValueStyle(context)).copyWith(
                color: color ?? valueStyle?.color,
              ),
            ),
            if (big.label != null) ...[
              const SizedBox(height: 2),
              Text(big.label!, style: labelStyle),
            ],
          ],
        ),
      ),
    };
  }

  Widget _container(BuildContext context, {required Widget child}) {
    return HandDrawnContainer(
      backgroundColor:
          backgroundColor ?? HandDrawnDefaults.containerBackgroundColor,
      padding:
          padding ?? const EdgeInsets.all(HandDrawnDefaults.containerPadding),
      child: child,
    );
  }

  TextStyle _defaultValueStyle(BuildContext context) {
    return Theme.of(context).textTheme.headlineMedium ??
        const TextStyle(fontSize: 32, fontWeight: FontWeight.bold);
  }
}

/// A streak leaderboard backed by a `StreakMeasure` query, styled by a
/// [HandDrawnTable] template.
///
/// A `StreakMeasure` produces a fixed-shape [TableResult]: `entityId`
/// (group key), `entityLabel`, `currentStreak`, `longestStreak`, already sorted
/// by current streak descending with `topN` applied. This widget maps those
/// fixed columns to a readable leaderboard: the raw entity id is hidden by
/// default, the label takes the wide column, and the two streak counts are
/// narrow. Per-column header labels are overridable.
///
/// Streak measures do not support a date range, so this widget exposes no
/// date-range inputs.
class HandDrawnAnalyticsStreakLeaderboard extends StatelessWidget {
  const HandDrawnAnalyticsStreakLeaderboard({
    // Analytics inputs.
    required this.query,
    required this.chart,
    this.asOf,
    this.runner,
    this.formatters,
    // Column header overrides.
    this.entityLabelHeader = 'Name',
    this.currentStreakHeader = 'Current',
    this.longestStreakHeader = 'Longest',
    // Bridge knobs.
    this.showEntityId = false,
    this.entityIdHeader = 'ID',
    super.key,
  });

  // Analytics inputs.
  final SingleQuerySpec query;
  final HandDrawnTable chart;

  /// Reference date the streak is computed as of. When null, the runner
  /// resolves it to the wall clock at fetch time; pass an explicit value to
  /// pin "current streak" to a known instant.
  final DateTime? asOf;
  final WidgetQueryRunner? runner;
  final BridgeFormatters? formatters;

  // Overrides.
  final String entityLabelHeader;
  final String currentStreakHeader;
  final String longestStreakHeader;

  // Bridge knobs.
  /// Whether to show the raw entity-id group-key column. Hidden by default.
  final bool showEntityId;
  final String entityIdHeader;

  @override
  Widget build(BuildContext context) {
    final config = resolveChartConfig(
      context,
      runner: runner,
      formatters: formatters,
    );

    return switch (config) {
      Err(error: final e) => _emptyState(e),
      Ok(value: final c) => buildChartHost(
        runner: c.runner,
        payload: query,
        dateRangeMode: const NoDateRange(),
        asOf: asOf,
        loading: (_) => chart,
        error: (_, e) => _emptyState(e),
        data: (context, result) => _buildData(c, result),
      ),
    };
  }

  Widget _buildData(ResolvedChartConfig config, BridgeResult result) {
    if (result is! SingleResult || result.result is! TableResult) {
      return _emptyState(
        BridgeShapeMismatch(
          expected: ResultShape.table,
          actual: bridgeShapeOf(result),
          suggestion: 'a query whose measure is a StreakMeasure',
        ),
      );
    }
    return _render(result.result as TableResult, config.formatters);
  }

  Widget _render(TableResult table, BridgeFormatters formatters) {
    final mapping = streakToTable(
      table,
      formatters: formatters,
      options: StreakTableOptions(
        entityLabelHeader: entityLabelHeader,
        currentStreakHeader: currentStreakHeader,
        longestStreakHeader: longestStreakHeader,
        showEntityId: showEntityId,
        entityIdHeader: entityIdHeader,
      ),
    );

    // Not streak-shaped: fall back to a generic table rather than a broken
    // leaderboard.
    if (mapping == null) {
      final generic = resultToTable(table, formatters: formatters);
      return switch (generic) {
        Err(error: final e) => _emptyState(e),
        Ok(value: final m) => HandDrawnTableView(mapping: m, chart: chart),
      };
    }

    // Render through the table view so a topN-capped leaderboard inherits the
    // "+N more" truncation footer.
    return HandDrawnTableView(mapping: mapping, chart: chart);
  }

  Widget _emptyState(BridgeError error) {
    return chart.copyWith(
      columns: const [HandDrawnTableColumn(header: '')],
      rows: const [],
      emptyMessage: error.humanMessage,
    );
  }
}
