import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../errors.dart';
import '../formatters.dart';
import '../mappers/mapper_support.dart';
import '../mappers/to_scatter_plot.dart';
import '../runner.dart';
import 'chart_internals.dart';

/// A scatter plot of two analytics series aligned by bucket key, styled by a
/// `hand_drawn_toolkit` template.
///
/// Takes a [PairedQuerySpec]: the x-series and y-series are computed
/// independently, then aligned by [BucketKey] (unmatched / null-valued buckets
/// are dropped). `dotColor` is a native template field, so it stays on [chart]
/// rather than becoming a bridge knob.
class HandDrawnAnalyticsScatterPlot extends StatelessWidget {
  const HandDrawnAnalyticsScatterPlot({
    // Analytics inputs.
    required this.query,
    required this.chart,
    this.runner,
    this.formatters,
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
    this.yValueFormatter,
    this.xValueFormatter,
    this.title,
    this.xAxisLabel,
    this.yAxisLabel,
    // Bridge knobs.
    this.onTap,
    this.onTapMiss,
    this.tolerance = 16.0, // mirrors the toolkit's scatter hit-test default.
    super.key,
  });

  // Analytics inputs.
  final PairedQuerySpec query;
  final HandDrawnScatterPlot chart;
  final WidgetQueryRunner? runner;
  final BridgeFormatters? formatters;
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
  final AxisValueFormatter? yValueFormatter;
  final AxisValueFormatter? xValueFormatter;
  final String? title;
  final String? xAxisLabel;
  final String? yAxisLabel;

  // Bridge knobs.
  final void Function(ScatterHitTestResult hit)? onTap;

  /// Called when a tap lands inside the chart but on no data element; use it
  /// to clear a pinned selection.
  final void Function()? onTapMiss;
  final double tolerance;

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
    if (result is! PairedResult) {
      return _emptyState(
        BridgeShapeMismatch(
          expected: ResultShape.pairedSeries,
          actual: bridgeShapeOf(result),
          suggestion: 'a paired query (xQuery + yQuery)',
        ),
      );
    }

    final mapped = pairedToScatter(
      result.x,
      result.y,
      formatters: config.formatters,
      xAxisLabel: xAxisLabel,
      yAxisLabel: yAxisLabel,
    );
    return switch (mapped) {
      Err(error: final e) => _emptyState(e),
      Ok(value: final mapping) => _render(_applyOverrides(mapping.data)),
    };
  }

  ScatterPlotData _applyOverrides(ScatterPlotData computed) {
    return computed.copyWith(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      axisDisplay: axisDisplay,
      yValueFormatter: yValueFormatter,
      xValueFormatter: xValueFormatter,
      title: title,
      xAxisLabel: xAxisLabel,
      yAxisLabel: yAxisLabel,
    );
  }

  Widget _render(ScatterPlotData data) {
    final filled = chart.copyWith(data: data);
    return wrapWithTap<ScatterHitTestResult>(
      child: filled,
      onTap: onTap,
      onTapMiss: onTapMiss,
      computeHit: (size, localPosition) {
        final painter = _painterFor(filled, data);
        return painter
            .computeLayout(size)
            .hitTest(localPosition, tolerance: tolerance);
      },
    );
  }

  HandDrawnScatterPlotPainter _painterFor(
    HandDrawnScatterPlot filled,
    ScatterPlotData data,
  ) {
    return HandDrawnScatterPlotPainter(
      data: data,
      dotColor: filled.dotColor,
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
      axisStrokeWidth: filled.axisStrokeWidth,
      clipToChartArea: filled.clipToChartArea,
      xLabelConfig: filled.xLabelConfig,
      legendConfig: filled.legendConfig,
      legendStyle: filled.legendStyle,
    );
  }

  Widget _emptyState(BridgeError error) {
    return chart.copyWith(
      data: const ScatterPlotData(
        points: [],
        minX: 0,
        maxX: 1,
        minY: 0,
        maxY: 1,
      ),
      emptyMessage: error.humanMessage,
    );
  }
}
