import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../colors.dart';
import '../errors.dart';
import '../formatters.dart';
import '../mappers/mapper_support.dart';
import '../mappers/to_bar_chart.dart';
import '../runner.dart';
import 'chart_internals.dart';

/// A bar chart backed by an analytics query and styled by a `hand_drawn_toolkit`
/// template.
///
/// The constructor parameters fall into three kinds:
///
/// * **Analytics inputs**: [query], the [chart] styling template (built with
///   `data: null`), the [mode], optional configuration overrides, and the
///   date-range inputs.
/// * **Data-object overrides**: nullable fields ([minY], [maxY], [legend],
///   titles, formatters) that, when non-null, replace the value the bridge
///   would otherwise compute. Null means "let the bridge default it."
/// * **Bridge knobs**: behavior the toolkit data class doesn't express, such
///   as [integerValued], [fillAlpha], and [onTap].
///
/// The bridge never stands between the consumer and a toolkit styling knob:
/// every native styling field lives on [chart] and is preserved verbatim. The
/// bridge only fills [chart]'s `data` and the override fields the consumer left
/// blank.
class HandDrawnAnalyticsBarChart extends StatelessWidget {
  const HandDrawnAnalyticsBarChart({
    required this.query,
    required this.chart,
    this.mode = BarMode.single,
    this.runner,
    this.palette,
    this.formatters,
    this.colorResolver,
    this.dateRangeMode = const NoDateRange(),
    this.pageRange,
    this.earliestDataDate,
    this.today,
    this.minY,
    this.maxY,
    this.axisDisplay,
    this.legend,
    this.yValueFormatter,
    this.title,
    this.yAxisLabel,
    this.xAxisLabel,
    this.integerValued,
    this.fillAlpha,
    this.onTap,
    this.onTapMiss,
    super.key,
  });

  // Analytics inputs.
  final SingleQuerySpec query;
  final HandDrawnBarChart chart;
  final BarMode mode;
  final WidgetQueryRunner? runner;
  final BridgePalette? palette;
  final BridgeFormatters? formatters;
  final SemanticColorResolver? colorResolver;
  final DateRangeMode dateRangeMode;
  final (DateTime, DateTime)? pageRange;
  final DateTime? earliestDataDate;
  final DateTime? today;

  // Data-object overrides (null = bridge computes).
  final double? minY;
  final double? maxY;
  final AxisDisplay? axisDisplay;
  final List<LegendEntry>? legend;
  final AxisValueFormatter? yValueFormatter;
  final String? title;
  final String? yAxisLabel;
  final String? xAxisLabel;

  // Bridge knobs.
  /// Forces integer (`true`) or non-integer (`false`) Y-axis formatting. When
  /// null the bridge infers it from the query measures and the result's output
  /// type.
  final bool? integerValued;
  final double? fillAlpha;
  final void Function(BarHitTestResult hit)? onTap;

  /// Called when a tap lands inside the chart but on no data element; use it
  /// to clear a pinned selection.
  final void Function()? onTapMiss;

  @override
  Widget build(BuildContext context) {
    final config = resolveChartConfig(
      context,
      runner: runner,
      palette: palette,
      formatters: formatters,
      colorResolver: colorResolver,
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
        loading: (_) => chart, // null-data template renders loading itself.
        error: (_, e) => _emptyState(e),
        data: (context, result) => _buildData(context, c, result),
      ),
    };
  }

  Widget _buildData(
    BuildContext context,
    ResolvedChartConfig config,
    BridgeResult result,
  ) {
    if (result is! SingleResult) {
      return _emptyState(
        BridgeShapeMismatch(
          expected: ResultShape.series,
          actual: bridgeShapeOf(result),
          suggestion: 'a single (non-paired) query',
        ),
      );
    }

    final mapped = _runMapper(config, result.result);
    return switch (mapped) {
      Err(error: final e) => _emptyState(e),
      Ok(value: final data) => _render(_applyOverrides(data)),
    };
  }

  /// Selects the mapper for the result shape and runs it.
  Result<BarChartData, BridgeError> _runMapper(
    ResolvedChartConfig config,
    AnalyticsResult result,
  ) {
    // Resolve the integer-axis flag here, where both the query and the result
    // are in hand, and pass a plain bool to the query-unaware mappers.
    final resolved = resolveIntegerValued(
      explicit: integerValued,
      measures: query.query.measures,
      outputType: outputTypeOf(result),
    );
    return switch (result) {
      SeriesResult() => seriesToBar(
        result,
        palette: config.palette,
        formatters: config.formatters,
        resolver: config.colorResolver,
        integerValued: resolved,
        fillAlpha: fillAlpha,
      ),
      MultiSeriesResult() => multiSeriesToBar(
        result,
        mode: mode,
        palette: config.palette,
        formatters: config.formatters,
        resolver: config.colorResolver,
        integerValued: resolved,
        fillAlpha: fillAlpha,
      ),
      MultiMeasureSeriesResult() => multiMeasureToBar(
        result,
        mode: mode,
        palette: config.palette,
        formatters: config.formatters,
        resolver: config.colorResolver,
        integerValued: resolved,
        fillAlpha: fillAlpha,
      ),
      ScalarResult() => const Err(
        BridgeShapeMismatch(
          expected: ResultShape.series,
          actual: ResultShape.scalar,
          suggestion: 'a big-number display',
        ),
      ),
      TableResult() => const Err(
        BridgeShapeMismatch(
          expected: ResultShape.series,
          actual: ResultShape.table,
          suggestion: 'a table display',
        ),
      ),
    };
  }

  /// Layers the consumer's override fields on top of the bridge-computed data.
  /// A null override leaves the bridge value in place.
  BarChartData _applyOverrides(BarChartData computed) {
    return computed.copyWith(
      minY: minY,
      maxY: maxY,
      axisDisplay: axisDisplay,
      legend: legend,
      yValueFormatter: yValueFormatter,
      title: title,
      yAxisLabel: yAxisLabel,
      xAxisLabel: xAxisLabel,
    );
  }

  /// Pours the mapped data into the template and optionally wraps for taps.
  Widget _render(BarChartData data) {
    final filled = chart.copyWith(data: data);
    return wrapWithTap<BarHitTestResult>(
      child: filled,
      onTap: onTap,
      onTapMiss: onTapMiss,
      computeHit: (size, localPosition) {
        final painter = _painterFor(filled, data);
        return painter.computeLayout(size).hitTest(localPosition);
      },
    );
  }

  /// Reconstructs the painter with the same styling that drew [filled], so the
  /// hit-test geometry matches the rendered chart. The bridge widget owns the
  /// styling, so this stays out of `chart_internals`.
  HandDrawnBarChartPainter _painterFor(
    HandDrawnBarChart filled,
    BarChartData data,
  ) {
    return HandDrawnBarChartPainter(
      data: data,
      seed: filled.seed,
      axisColor: filled.axisColor,
      grid: filled.grid,
      labelStyle: filled.labelStyle,
      irregularity: filled.irregularity,
      segments: filled.segments,
      yDivisions: filled.yDivisions,
      padding: filled.padding,
      titleStyle: filled.titleStyle,
      legendStyle: filled.legendStyle,
      axisStrokeWidth: filled.axisStrokeWidth,
      clipToChartArea: filled.clipToChartArea,
      xLabelConfig: filled.xLabelConfig,
      legendConfig: filled.legendConfig,
    );
  }

  Widget _emptyState(BridgeError error) {
    return chart.copyWith(
      data: const BarChartData(),
      emptyMessage: error.humanMessage,
    );
  }
}
