import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../colors.dart';
import '../errors.dart';
import '../formatters.dart';
import '../mappers/mapper_support.dart';
import '../mappers/to_line_chart.dart';
import '../runner.dart';
import 'chart_internals.dart';

/// A line chart backed by an analytics query and styled by a
/// `hand_drawn_toolkit` template.
///
/// A single-series result becomes one line; a multi-series or multi-measure
/// result becomes one line each (mixed-unit measures are rejected). [chart] is
/// the styling template (built with `data: null`); the bridge fills its data
/// and any nullable override field left null. [temporalSpacing] chooses between
/// evenly-spaced categorical positions and real epoch-millisecond positions.
class HandDrawnAnalyticsLineChart extends StatelessWidget {
  const HandDrawnAnalyticsLineChart({
    // Analytics inputs.
    required this.query,
    required this.chart,
    this.runner,
    this.palette,
    this.formatters,
    this.colorResolver,
    this.dateRangeMode = const NoDateRange(),
    this.pageRange,
    this.earliestDataDate,
    this.today,
    // Data-object overrides (null = bridge computes).
    this.minX,
    this.maxX,
    this.minY,
    this.maxY,
    this.axisDisplay,
    this.legend,
    this.yValueFormatter,
    this.xValueFormatter,
    this.title,
    this.yAxisLabel,
    this.xAxisLabel,
    // Bridge knobs.
    this.temporalSpacing = TemporalSpacing.uniform,
    this.integerValued,
    this.onTap,
    this.onTapMiss,
    // Defaults mirror the toolkit's line hit-test tolerances (the upstream
    // constants are not exported from its public barrel, so we restate them).
    this.pointTolerance = 12.0,
    this.lineTolerance = 16.0,
    super.key,
  });

  // Analytics inputs.
  final SingleQuerySpec query;
  final HandDrawnLineChart chart;
  final WidgetQueryRunner? runner;
  final BridgePalette? palette;
  final BridgeFormatters? formatters;
  final SemanticColorResolver? colorResolver;
  final DateRangeMode dateRangeMode;
  final (DateTime, DateTime)? pageRange;
  final DateTime? earliestDataDate;
  final DateTime? today;

  // Overrides.
  final double? minX;
  final double? maxX;
  final double? minY;
  final double? maxY;
  final AxisDisplay? axisDisplay;
  final List<LegendEntry>? legend;
  final AxisValueFormatter? yValueFormatter;
  final AxisValueFormatter? xValueFormatter;
  final String? title;
  final String? yAxisLabel;
  final String? xAxisLabel;

  // Bridge knobs.
  final TemporalSpacing temporalSpacing;

  /// Forces integer (`true`) or non-integer (`false`) Y-axis formatting. When
  /// null the bridge infers it from the query measures and the result's output
  /// type.
  final bool? integerValued;
  final void Function(LineHitTestResult hit)? onTap;

  /// Called when a tap lands inside the chart but on no data element; use it
  /// to clear a pinned selection.
  final void Function()? onTapMiss;
  final double pointTolerance;
  final double lineTolerance;

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

  Result<LineChartData, BridgeError> _runMapper(
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
      SeriesResult() => seriesToLine(
        result,
        palette: config.palette,
        formatters: config.formatters,
        resolver: config.colorResolver,
        temporalSpacing: temporalSpacing,
        integerValued: resolved,
      ),
      MultiSeriesResult() => multiSeriesToLine(
        result,
        palette: config.palette,
        formatters: config.formatters,
        resolver: config.colorResolver,
        temporalSpacing: temporalSpacing,
        integerValued: resolved,
      ),
      MultiMeasureSeriesResult() => multiMeasureToLine(
        result,
        palette: config.palette,
        formatters: config.formatters,
        resolver: config.colorResolver,
        temporalSpacing: temporalSpacing,
        integerValued: resolved,
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

  LineChartData _applyOverrides(LineChartData computed) {
    return computed.copyWith(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      axisDisplay: axisDisplay,
      legend: legend,
      yValueFormatter: yValueFormatter,
      xValueFormatter: xValueFormatter,
      title: title,
      yAxisLabel: yAxisLabel,
      xAxisLabel: xAxisLabel,
    );
  }

  Widget _render(LineChartData data) {
    final filled = chart.copyWith(data: data);
    return wrapWithTap<LineHitTestResult>(
      child: filled,
      onTap: onTap,
      onTapMiss: onTapMiss,
      computeHit: (size, localPosition) {
        final painter = _painterFor(filled, data);
        return painter
            .computeLayout(size)
            .hitTest(
              localPosition,
              pointTolerance: pointTolerance,
              lineTolerance: lineTolerance,
            );
      },
    );
  }

  /// Reconstructs the painter with the same styling that drew [filled], so the
  /// hit-test geometry matches the rendered chart. The bridge widget owns the
  /// styling, so this stays out of `chart_internals`.
  HandDrawnLineChartPainter _painterFor(
    HandDrawnLineChart filled,
    LineChartData data,
  ) {
    return HandDrawnLineChartPainter(
      data: data,
      seed: filled.seed,
      axisColor: filled.axisColor,
      grid: filled.grid,
      labelStyle: filled.labelStyle,
      irregularity: filled.irregularity,
      segments: filled.segments,
      yDivisions: filled.yDivisions,
      xDivisions: filled.xDivisions,
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
      data: const LineChartData(series: [], minX: 0, maxX: 1, minY: 0, maxY: 1),
      emptyMessage: error.humanMessage,
    );
  }
}
