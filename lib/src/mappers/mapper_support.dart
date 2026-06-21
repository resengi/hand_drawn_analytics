import 'dart:math' as math;

import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../errors.dart';
import '../formatters.dart';

/// A uniform read-only view over the two "named series" shapes the analytics
/// layer produces:
///
/// * [NamedSeries] (from [MultiSeriesResult]) — keyed by a [BucketKey], one
///   measure across a secondary group-by dimension.
/// * [MeasureSeries] (from [MultiMeasureSeriesResult]) — keyed by a string
///   label, each carrying its own output [FieldType].
///
/// Normalizing both to one shape lets the multi-series mappers work from a
/// single representation regardless of which result type produced them.
class SeriesView {
  const SeriesView({
    required this.label,
    required this.values,
    required this.fieldType,
    required this.semanticTag,
    required this.key,
  });

  /// Builds a view over a [NamedSeries]. Its label is the formatted bucket key;
  /// its field type is the shared measure field type passed in.
  factory SeriesView.fromNamed(
    NamedSeries series, {
    required FieldType measureFieldType,
    required BridgeFormatters formatters,
  }) {
    return SeriesView(
      label: formatters.bucketKey(series.key),
      values: series.values,
      fieldType: measureFieldType,
      semanticTag: series.semanticTag,
      key: series.key,
    );
  }

  /// Builds a view over a [MeasureSeries]. Its label and field type come
  /// straight from the measure series; it has no bucket key.
  factory SeriesView.fromMeasure(MeasureSeries series) {
    return SeriesView(
      label: series.label,
      values: series.values,
      fieldType: series.fieldType,
      semanticTag: series.semanticTag,
      key: null,
    );
  }

  /// Display label for the series (legend entry, etc.).
  final String label;

  /// Values aligned to the parent result's x-axis.
  final List<TypedValue?> values;

  /// The output field type of this series' values.
  final FieldType fieldType;

  /// Optional opaque semantic identity, for coloring.
  final String? semanticTag;

  /// The bucket key when the series came from a [NamedSeries]; `null` for a
  /// [MeasureSeries].
  final BucketKey? key;
}

/// Whether [type] can be projected onto a numeric chart axis.
///
/// Only `integer`, `double`, and `duration` have a numeric projection (duration
/// via [BridgeFormatters.chartNumeric] → minutes). Every other type
/// (`dateTime`, `enum`, `string`, `bool`, and the list types) is unchartable
/// and must be rejected before any chart data is built, so a non-numeric
/// measure doesn't silently render as a chart of zeros.
bool isChartableFieldType(FieldType type) => switch (type) {
  FieldType.integer || FieldType.double || FieldType.duration => true,
  _ => false,
};

/// The error returned when a measure's output [type] cannot be plotted on a
/// numeric axis. Suggests a table, which can render any value.
BridgeError unchartableValueError(FieldType type) => BridgeIncompatibleValues(
  reason: IncompatibleValuesReason.nonNumericType,
  fieldType: type,
);

/// Guards against plotting series whose values carry incompatible units on a
/// single shared axis.
///
/// A [MultiMeasureSeriesResult] can mix, say, a duration measure and a count
/// measure; stacking or sharing a Y axis across those would be meaningless.
/// Returns a [BridgeIncompatibleValues] error when the [views] do not all share
/// one unit family, and `null` when they are unit-compatible (or there is
/// nothing to compare).
///
/// Field types are grouped into compatible families rather than compared
/// exactly: integer and double are both plain numerics and may share an axis;
/// duration is its own unit; everything else is non-numeric and handled by
/// [isChartableFieldType] upstream.
BridgeError? mixedUnitGuard(List<SeriesView> views) {
  if (views.length < 2) return null;

  FieldType? firstType;
  int? family;
  for (final v in views) {
    final f = _unitFamily(v.fieldType);
    if (family == null) {
      family = f;
      firstType = v.fieldType;
    } else if (f != family) {
      return BridgeIncompatibleValues(
        reason: IncompatibleValuesReason.mixedUnits,
        fieldType: firstType,
        otherFieldType: v.fieldType,
      );
    }
  }
  return null;
}

/// `0` = plain numeric (integer/double), `1` = duration, `2` = other.
int _unitFamily(FieldType type) => switch (type) {
  FieldType.integer || FieldType.double => 0,
  FieldType.duration => 1,
  _ => 2,
};

/// Guards epoch-millisecond spacing against non-temporal keys.
///
/// Under [TemporalSpacing.epochMs] every key must be a [TimeBucketKey] so it
/// has a real time position; a non-temporal key has none, and mixing
/// timestamp-scale and index-scale positions on one axis renders meaningless
/// geometry. Returns a typed value-level error when [spacing] is `epochMs` and
/// any key is non-temporal, else `null`.
BridgeError? epochSpacingGuard(List<BucketKey> keys, TemporalSpacing spacing) {
  if (spacing != TemporalSpacing.epochMs) return null;
  final hasNonTemporal = keys.any((k) => k is! TimeBucketKey);
  if (!hasNonTemporal) return null;
  return const BridgeIncompatibleValues(
    reason: IncompatibleValuesReason.nonTemporalForEpochSpacing,
  );
}

/// Projects the [views] into a dense `series × position` grid of plottable
/// `double?`s, using [formatters] to map each typed value to a chart number.
///
/// The outer list is one entry per series (matching [views] order); each inner
/// list is aligned to the x-axis positions. A `null` cell means "no value to
/// plot here" (an undefined aggregation or a non-numeric value).
List<List<double?>> projectMultiSeries(
  List<SeriesView> views, {
  required BridgeFormatters formatters,
}) {
  return [
    for (final v in views)
      [for (final value in v.values) formatters.chartNumeric(value)],
  ];
}

// ── Nice-axis logic ──────────────────────────────────────────────────────────

/// A computed `[min, max]` axis range.
typedef NiceRange = ({double min, double max});

/// Computes a tidy Y range for bar/line charts from the plottable [values].
///
/// Rules:
/// * Non-negative data floors the range at `0` (bars grow from a zero
///   baseline).
/// * Mixed-sign data uses a symmetric-ish signed span covering both extremes.
/// * The upper (and, for signed data, lower) bound is rounded to a "nice"
///   number so tick labels land on round values.
/// * When [integerValued] is true the bounds snap to whole numbers.
///
/// Returns `null` when there is nothing to plot (all values null/empty), so the
/// caller can fall back to the toolkit's own default range.
NiceRange? niceYRange(Iterable<double?> values, {bool integerValued = false}) {
  double? lo;
  double? hi;
  for (final v in values) {
    if (v == null) continue;
    lo = lo == null ? v : math.min(lo, v);
    hi = hi == null ? v : math.max(hi, v);
  }
  if (lo == null || hi == null) return null;

  final hasNegative = lo < 0;
  if (!hasNegative) {
    // Floor at zero, round the top up to a nice bound.
    final top = niceUpperBound(hi, integerValued: integerValued);
    return (min: 0, max: top == 0 ? 1.0 : top);
  }

  // Mixed sign (or all-negative): expand symmetrically to nice bounds.
  final magnitude = math.max(hi.abs(), lo.abs());
  final niceMag = niceUpperBound(magnitude, integerValued: integerValued);
  final top = hi <= 0 ? 0.0 : niceMag;
  final bottom = lo >= 0 ? 0.0 : -niceMag;
  return (min: bottom, max: top == bottom ? bottom + 1.0 : top);
}

/// A padded range for scatter plots: unlike [niceYRange] this never floors at
/// zero — it pads both ends so points don't sit on the axis. Returns `null`
/// when there is nothing to plot.
NiceRange? nicePaddedRange(Iterable<double?> values) {
  double? lo;
  double? hi;
  for (final v in values) {
    if (v == null) continue;
    lo = lo == null ? v : math.min(lo, v);
    hi = hi == null ? v : math.max(hi, v);
  }
  if (lo == null || hi == null) return null;

  if (lo == hi) {
    // Degenerate single value: pad around it so the point is centered.
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.1;
    return (min: lo - pad, max: hi + pad);
  }
  final pad = (hi - lo) * 0.05;
  return (min: lo - pad, max: hi + pad);
}

/// Rounds [value] up to a visually tidy bound (1/2/2.5/5 × 10ⁿ). For
/// [integerValued] data the result is at least the ceiling of [value] and is
/// itself a whole number.
double niceUpperBound(double value, {bool integerValued = false}) {
  if (value <= 0) return 0;

  final exponent = (math.log(value) / math.ln10).floor();
  final pow10 = math.pow(10, exponent).toDouble();
  final fraction = value / pow10; // in [1, 10)

  double niceFraction;
  if (fraction <= 1) {
    niceFraction = 1;
  } else if (fraction <= 2) {
    niceFraction = 2;
  } else if (fraction <= 2.5) {
    niceFraction = 2.5;
  } else if (fraction <= 5) {
    niceFraction = 5;
  } else {
    niceFraction = 10;
  }

  final result = niceFraction * pow10;
  if (integerValued) {
    final snapped = result.ceilToDouble();
    return snapped < value.ceilToDouble() ? value.ceilToDouble() : snapped;
  }
  return result;
}

/// A Y-axis tick formatter that appends the measure's unit (only durations
/// carry one), or `null` when no unit annotation applies.
///
/// Shared by the bar and line mappers so the unit-suffix policy lives in one
/// place.
AxisValueFormatter? unitAxisFormatter(
  BridgeFormatters formatters,
  FieldType fieldType,
) {
  final unit = formatters.chartUnitLabel(fieldType);
  if (unit == null) return null;
  return (v) => '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)} $unit';
}

/// The [ResultShape] corresponding to a concrete [AnalyticsResult]. Used when
/// building a [BridgeShapeMismatch] so the error reports the actual shape.
ResultShape resultShapeOf(AnalyticsResult result) => switch (result) {
  ScalarResult() => ResultShape.scalar,
  SeriesResult() => ResultShape.series,
  MultiSeriesResult() => ResultShape.multiSeries,
  MultiMeasureSeriesResult() => ResultShape.multiMeasureSeries,
  TableResult() => ResultShape.table,
};

/// The [ResultShape] of a [BridgeResult]. Used when building a
/// [BridgeShapeMismatch] so the error reports the shape that was actually
/// produced rather than a fixed placeholder.
ResultShape bridgeShapeOf(BridgeResult result) => switch (result) {
  SingleResult(result: final r) => resultShapeOf(r),
  PairedResult() => ResultShape.pairedSeries,
};

// ── Inferred defaults ─────────────────────────────────────────────────────────

/// Whether [measure] inherently produces integer-valued output, so a chart axis
/// should default to integer ticks.
///
/// [outputType], when supplied, is the measure's resolved output [FieldType]
/// (available from the result after a query runs). It sharpens the answer for
/// [FieldMeasure]: a sum/min/max over an integer field is integer-valued, which
/// the measure alone cannot reveal. When [outputType] is null the decision is
/// made from the measure shape alone (the conservative pre-query view).
///
/// Rules: [CountMeasure] and [StreakMeasure] are always integer. A
/// [FieldMeasure] is integer when its aggregation always yields an integer
/// ([DistinctCountAgg]), or when the aggregation preserves its input type
/// (sum/min/max) and that resolved output type is integer. A
/// [TransformedMeasure] or [CalculatedMeasure] is an arithmetic expression
/// whose output type the engine resolves (via its scalar-op and combine type
/// rules); it is integer when that resolved [outputType] is integer, and so
/// conservatively non-integer pre-query when [outputType] is null — the same
/// stance as the [FieldMeasure] sum/min/max case.
bool isIntegerMeasure(Measure measure, {FieldType? outputType}) {
  return switch (measure) {
    CountMeasure() => true,
    StreakMeasure() => true,
    FieldMeasure(aggregation: final agg) => switch (agg) {
      DistinctCountAgg() => true,
      SumAgg() || MinAgg() || MaxAgg() => outputType == FieldType.integer,
      AverageAgg() || PercentileAgg() => false,
    },
    // Arithmetic expression nodes: the engine resolves their output type via
    // its scalar-op / combine type rules, so they are integer-valued exactly
    // when that resolved type is integer (conservatively non-integer pre-query
    // when outputType is null, matching the FieldMeasure sum/min/max case).
    TransformedMeasure() ||
    CalculatedMeasure() => outputType == FieldType.integer,
  };
}

/// Resolves the effective integer-valued axis flag for a chart widget.
///
/// [explicit] wins when non-null. Otherwise the value is inferred: a
/// single-measure query is integer when [isIntegerMeasure] holds for its
/// measure (with the resolved [outputType]); a multi-measure query sharing one
/// axis is integer only when *every* measure is integer-valued. [outputType] is
/// the result's measure output type, or null when unknown.
bool resolveIntegerValued({
  required bool? explicit,
  required List<Measure> measures,
  FieldType? outputType,
}) {
  if (explicit != null) return explicit;
  if (measures.isEmpty) return false;
  return measures.every((m) => isIntegerMeasure(m, outputType: outputType));
}

/// How points are positioned along a line chart's X axis.
enum TemporalSpacing {
  /// Evenly spaced integer positions (`0, 1, 2, …`) with categorical
  /// [LineChartData.xLabels]. The default — visually even regardless of the
  /// real gaps between buckets.
  uniform,

  /// Real time positions in epoch milliseconds, with numeric X ticks (no
  /// categorical labels). Use when the spacing between buckets carries meaning.
  epochMs,
}

/// Builds [LineChartData] with computed Y/X ranges, the zero-crossing axis
/// default, categorical labels (under uniform spacing), and a unit-suffixed Y
/// formatter.
///
/// Shared by the single/multi line mappers so every line-shaped output
/// inherits the same range, axis-display, label, and legend logic.
/// [numericGrid] is one row per series, each aligned to [positions];
/// [keys] are the bucket keys backing those positions (used for labels and the
/// multi-year check). [legend] is passed through verbatim.
LineChartData assembleLineChartData({
  required List<LineSeriesData> series,
  required List<BucketKey> keys,
  required List<double> positions,
  required List<List<double?>> numericGrid,
  required BridgeFormatters formatters,
  required TemporalSpacing temporalSpacing,
  required bool integerValued,
  required FieldType unitType,
  required List<LegendEntry> legend,
}) {
  // Y range across every series' plottable values.
  final allY = [for (final row in numericGrid) ...row];
  final yRange = niceYRange(allY, integerValued: integerValued);

  // X range from positions (fall back to a unit range when empty). Use the
  // actual extremes rather than first/last so the range is correct even if
  // positions are not strictly ascending.
  var minX = positions.isEmpty ? 0.0 : positions.first;
  var maxX = positions.isEmpty ? 1.0 : positions.first;
  for (final p in positions) {
    if (p < minX) minX = p;
    if (p > maxX) maxX = p;
  }

  final uniform = temporalSpacing == TemporalSpacing.uniform;
  final includeYear = formatters.spansMultipleYears(keys);

  return LineChartData(
    series: series,
    minX: minX,
    maxX: minX == maxX ? maxX + 1 : maxX,
    minY: yRange?.min ?? 0,
    maxY: yRange?.max ?? 1,
    axisDisplay: defaultAxisDisplayFor(yRange),
    xLabels: uniform
        ? [
            for (final k in keys)
              formatters.bucketKey(k, includeYear: includeYear),
          ]
        : const [],
    yValueFormatter: unitAxisFormatter(formatters, unitType),
    legend: legend,
  );
}

/// The measure output [FieldType] a chart axis should format against, or `null`
/// when there is no single such type.
///
/// Series and multi-series results carry one shared `measureFieldType`;
/// multi-measure, scalar, and table results have no single axis type (a
/// multi-measure chart can mix units, scalar/table have no numeric axis), so
/// those return `null`. Defined exhaustively so a new result shape forces a
/// decision here.
FieldType? outputTypeOf(AnalyticsResult result) => switch (result) {
  SeriesResult(measureFieldType: final t) => t,
  MultiSeriesResult(measureFieldType: final t) => t,
  MultiMeasureSeriesResult() => null,
  ScalarResult() => null,
  TableResult() => null,
};

/// The default [AxisDisplay] for a value axis spanning [range].
///
/// When the range strictly straddles zero (a signed series — a delta, a running
/// net), the value axis is drawn at the zero line; otherwise it stays at the
/// chart edge ([AxisDisplay.edge], which is also the chart's own default). A
/// null [range] (nothing computed) also yields edge.
///
/// The value axis on bar/line charts is the horizontal zero line, so this sets
/// [AxisDisplay.horizontal]. The toolkit independently reverts to edge if zero
/// is not inside the range, so this is a safe default to set.
AxisDisplay defaultAxisDisplayFor(NiceRange? range) {
  if (range == null) return AxisDisplay.edge;
  final straddlesZero = range.min < 0 && range.max > 0;
  if (!straddlesZero) return AxisDisplay.edge;
  return const AxisDisplay(horizontal: AxisDisplayMode.zeroCrossing);
}
