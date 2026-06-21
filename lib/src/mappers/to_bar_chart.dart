import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../colors.dart';
import '../errors.dart';
import '../formatters.dart';
import 'mapper_support.dart';

/// How a multi-dimension result is laid out as bars.
enum BarMode {
  /// One bar per category. On a multi-series shape — which has no single-bar
  /// layout — the multi-series mappers render this mode as [grouped].
  single,

  /// Side-by-side bars per category (one inner bar per series).
  grouped,

  /// Stacked segments per category (one segment per series).
  stacked,
}

/// Maps a single [SeriesResult] to [BarChartData]: one bar per bucket.
///
/// Pure: computes default colors (from [palette]/[resolver]) and a nice Y
/// range; the widget layers consumer overrides on top via
/// `BarChartData.copyWith`. Empty input maps to empty (renderable) data.
Result<BarChartData, BridgeError> seriesToBar(
  SeriesResult result, {
  required BridgePalette palette,
  required BridgeFormatters formatters,
  SemanticColorResolver? resolver,
  bool integerValued = false,
  double? fillAlpha,
}) {
  if (!isChartableFieldType(result.measureFieldType)) {
    return Err(unchartableValueError(result.measureFieldType));
  }

  final includeYear = formatters.spansMultipleYears(
    result.buckets.map((b) => b.key),
  );

  final bars = <BarGroup>[];
  final numerics = <double?>[];
  for (final bucket in result.buckets) {
    final numeric = formatters.chartNumeric(bucket.value);
    numerics.add(numeric);
    // Color encodes series identity, as in the multi-series mappers where
    // colors map to legend entries: every bar belongs to the one series, so
    // all share its color — the palette's first, unless a resolver or tag pin
    // overrides per bucket. The x-axis labels distinguish the categories.
    final color = palette.resolve(
      index: 0,
      semanticTag: result.semanticTag,
      key: bucket.key,
      resolver: resolver,
    );
    bars.add(
      BarGroup(
        label: formatters.bucketKey(bucket.key, includeYear: includeYear),
        segments: [
          BarSegment(
            category: result.measureLabel,
            value: numeric ?? 0,
            color: color,
            fillAlpha: fillAlpha,
          ),
        ],
      ),
    );
  }

  final range = niceYRange(numerics, integerValued: integerValued);
  return Ok(
    BarChartData(
      bars: bars,
      minY: range?.min,
      maxY: range?.max,
      axisDisplay: defaultAxisDisplayFor(range),
      yValueFormatter: unitAxisFormatter(formatters, result.measureFieldType),
    ),
  );
}

/// Maps a [MultiSeriesResult] to grouped or stacked [BarChartData].
///
/// [BarMode.single] has no meaning for a multi-series shape — every x-axis
/// position carries one bar per series — so it renders as [BarMode.grouped].
/// Each x-axis position becomes one category; each series contributes one
/// inner bar (grouped) or one segment (stacked).
Result<BarChartData, BridgeError> multiSeriesToBar(
  MultiSeriesResult result, {
  required BarMode mode,
  required BridgePalette palette,
  required BridgeFormatters formatters,
  SemanticColorResolver? resolver,
  bool integerValued = false,
  double? fillAlpha,
}) {
  final effectiveMode = mode == BarMode.single ? BarMode.grouped : mode;

  final views = [
    for (final s in result.series)
      SeriesView.fromNamed(
        s,
        measureFieldType: result.measureFieldType,
        formatters: formatters,
      ),
  ];
  return _multiBar(
    views: views,
    keys: [for (final p in result.xAxis) p.key],
    positionLabels: [for (final p in result.xAxis) p.label],
    mode: effectiveMode,
    palette: palette,
    formatters: formatters,
    resolver: resolver,
    integerValued: integerValued,
    fillAlpha: fillAlpha,
    unitType: result.measureFieldType,
    guardUnits: false,
  );
}

/// Maps a [MultiMeasureSeriesResult] to grouped or stacked [BarChartData].
///
/// Rejects mixed-unit measures. [BarMode.single] has no meaning for a
/// multi-measure shape, so it renders as [BarMode.grouped]. Each measure
/// becomes one inner bar (grouped) or one segment (stacked) per category.
Result<BarChartData, BridgeError> multiMeasureToBar(
  MultiMeasureSeriesResult result, {
  required BarMode mode,
  required BridgePalette palette,
  required BridgeFormatters formatters,
  SemanticColorResolver? resolver,
  bool integerValued = false,
  double? fillAlpha,
}) {
  final effectiveMode = mode == BarMode.single ? BarMode.grouped : mode;

  final views = [for (final s in result.series) SeriesView.fromMeasure(s)];
  // All views share a unit (the guard inside _multiBar enforces this), so any
  // view's field type yields the right axis unit label.
  final unitType = views.isEmpty ? FieldType.double : views.first.fieldType;
  return _multiBar(
    views: views,
    keys: [for (final p in result.xAxis) p.key],
    positionLabels: [for (final p in result.xAxis) p.label],
    mode: effectiveMode,
    palette: palette,
    formatters: formatters,
    resolver: resolver,
    integerValued: integerValued,
    fillAlpha: fillAlpha,
    unitType: unitType,
    guardUnits: true,
  );
}

// ── Shared multi-series path ────────────────────────────────────────────────

/// Builds grouped or stacked [BarChartData] from normalized [views].
///
/// Both [multiSeriesToBar] and [multiMeasureToBar] funnel through here once
/// they've produced their [SeriesView]s, so the category-building logic lives
/// in one place. [guardUnits] applies the mixed-unit check (needed only for
/// multi-measure inputs, whose series can differ in unit).
Result<BarChartData, BridgeError> _multiBar({
  required List<SeriesView> views,
  required List<BucketKey> keys,
  required List<String?> positionLabels,
  required BarMode mode,
  required BridgePalette palette,
  required BridgeFormatters formatters,
  required SemanticColorResolver? resolver,
  required bool integerValued,
  required double? fillAlpha,
  required FieldType unitType,
  required bool guardUnits,
}) {
  if (guardUnits) {
    final unitError = mixedUnitGuard(views);
    if (unitError != null) return Err(unitError);
  }
  // All views share a unit family by this point (guarded above for
  // multi-measure; intrinsic for multi-series), so the representative unitType
  // decides chartability for the whole axis.
  if (!isChartableFieldType(unitType)) {
    return Err(unchartableValueError(unitType));
  }

  final colors = _seriesColors(views, palette, resolver);
  final includeYear = formatters.spansMultipleYears(keys);
  final stacked = mode == BarMode.stacked;

  final categories = <BarCategory>[];
  final allNumerics = <double?>[];
  for (var x = 0; x < keys.length; x++) {
    final label =
        positionLabels[x] ??
        formatters.bucketKey(keys[x], includeYear: includeYear);

    if (stacked) {
      final segments = <BarSegment>[];
      // Positive segments stack upward from zero and negative segments
      // downward, so a single bar mixing signs spans both totals. Feeding both
      // extremes (rather than the net) keeps the Y range covering the visible
      // stack rather than clipping it.
      var positiveTotal = 0.0;
      var negativeTotal = 0.0;
      for (var s = 0; s < views.length; s++) {
        final value = formatters.chartNumeric(views[s].values[x]) ?? 0;
        if (value >= 0) {
          positiveTotal += value;
        } else {
          negativeTotal += value;
        }
        segments.add(_segment(views[s].label, value, colors[s], fillAlpha));
      }
      allNumerics
        ..add(positiveTotal)
        ..add(negativeTotal);
      categories.add(
        BarCategory(
          label: label,
          bars: [BarGroup(label: label, segments: segments)],
        ),
      );
    } else {
      final innerBars = <BarGroup>[];
      for (var s = 0; s < views.length; s++) {
        final numeric = formatters.chartNumeric(views[s].values[x]);
        allNumerics.add(numeric);
        innerBars.add(
          BarGroup(
            label: views[s].label,
            segments: [
              _segment(views[s].label, numeric ?? 0, colors[s], fillAlpha),
            ],
          ),
        );
      }
      categories.add(BarCategory(label: label, bars: innerBars));
    }
  }

  final range = niceYRange(allNumerics, integerValued: integerValued);
  return Ok(
    BarChartData(
      categories: categories,
      legend: [
        for (var s = 0; s < views.length; s++)
          LegendEntry(label: views[s].label, color: colors[s]),
      ],
      minY: range?.min,
      maxY: range?.max,
      axisDisplay: defaultAxisDisplayFor(range),
      yValueFormatter: unitAxisFormatter(formatters, unitType),
    ),
  );
}

BarSegment _segment(String category, double value, Color color, double? alpha) {
  return BarSegment(
    category: category,
    value: value,
    color: color,
    fillAlpha: alpha,
  );
}

List<Color> _seriesColors(
  List<SeriesView> views,
  BridgePalette palette,
  SemanticColorResolver? resolver,
) {
  return [
    for (var i = 0; i < views.length; i++)
      palette.resolve(
        index: i,
        semanticTag: views[i].semanticTag,
        key: views[i].key,
        resolver: resolver,
      ),
  ];
}
