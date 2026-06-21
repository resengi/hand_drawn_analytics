import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../colors.dart';
import '../errors.dart';
import '../formatters.dart';
import 'mapper_support.dart';

/// Maps a single [SeriesResult] to a one-line [LineChartData].
Result<LineChartData, BridgeError> seriesToLine(
  SeriesResult result, {
  required BridgePalette palette,
  required BridgeFormatters formatters,
  SemanticColorResolver? resolver,
  TemporalSpacing temporalSpacing = TemporalSpacing.uniform,
  bool integerValued = false,
}) {
  if (!isChartableFieldType(result.measureFieldType)) {
    return Err(unchartableValueError(result.measureFieldType));
  }

  final keys = [for (final b in result.buckets) b.key];
  final spacingError = epochSpacingGuard(keys, temporalSpacing);
  if (spacingError != null) return Err(spacingError);

  final color = palette.resolve(
    index: 0,
    semanticTag: result.semanticTag,
    key: result.buckets.isEmpty ? null : result.buckets.first.key,
    resolver: resolver,
  );

  final positions = _xPositions(keys, temporalSpacing);
  final numerics = [
    for (final b in result.buckets) formatters.chartNumeric(b.value),
  ];

  final points = <LinePoint>[];
  for (var i = 0; i < numerics.length; i++) {
    final y = numerics[i];
    if (y == null) continue; // skip undefined buckets; line bridges the gap
    points.add(LinePoint(x: positions[i], y: y));
  }

  return Ok(
    assembleLineChartData(
      series: [
        LineSeriesData(name: result.measureLabel, points: points, color: color),
      ],
      keys: keys,
      positions: positions,
      numericGrid: [numerics],
      formatters: formatters,
      temporalSpacing: temporalSpacing,
      integerValued: integerValued,
      unitType: result.measureFieldType,
      legend: const [],
    ),
  );
}

/// Maps a [MultiSeriesResult] to a multi-line [LineChartData] — one line per
/// secondary-group series.
Result<LineChartData, BridgeError> multiSeriesToLine(
  MultiSeriesResult result, {
  required BridgePalette palette,
  required BridgeFormatters formatters,
  SemanticColorResolver? resolver,
  TemporalSpacing temporalSpacing = TemporalSpacing.uniform,
  bool integerValued = false,
}) {
  final views = [
    for (final s in result.series)
      SeriesView.fromNamed(
        s,
        measureFieldType: result.measureFieldType,
        formatters: formatters,
      ),
  ];
  return _multiLine(
    views: views,
    keys: [for (final p in result.xAxis) p.key],
    palette: palette,
    formatters: formatters,
    resolver: resolver,
    temporalSpacing: temporalSpacing,
    integerValued: integerValued,
    unitType: result.measureFieldType,
    guardUnits: false,
  );
}

/// Maps a [MultiMeasureSeriesResult] to a multi-line [LineChartData] — one line
/// per measure. Rejects mixed-unit measures.
Result<LineChartData, BridgeError> multiMeasureToLine(
  MultiMeasureSeriesResult result, {
  required BridgePalette palette,
  required BridgeFormatters formatters,
  SemanticColorResolver? resolver,
  TemporalSpacing temporalSpacing = TemporalSpacing.uniform,
  bool integerValued = false,
}) {
  final views = [for (final s in result.series) SeriesView.fromMeasure(s)];
  return _multiLine(
    views: views,
    keys: [for (final p in result.xAxis) p.key],
    palette: palette,
    formatters: formatters,
    resolver: resolver,
    temporalSpacing: temporalSpacing,
    integerValued: integerValued,
    unitType: views.isEmpty ? FieldType.double : views.first.fieldType,
    guardUnits: true,
  );
}

// ── Shared multi-line path ──────────────────────────────────────────────────

Result<LineChartData, BridgeError> _multiLine({
  required List<SeriesView> views,
  required List<BucketKey> keys,
  required BridgePalette palette,
  required BridgeFormatters formatters,
  required SemanticColorResolver? resolver,
  required TemporalSpacing temporalSpacing,
  required bool integerValued,
  required FieldType unitType,
  required bool guardUnits,
}) {
  if (guardUnits) {
    final unitError = mixedUnitGuard(views);
    if (unitError != null) return Err(unitError);
  }
  if (!isChartableFieldType(unitType)) {
    return Err(unchartableValueError(unitType));
  }
  final spacingError = epochSpacingGuard(keys, temporalSpacing);
  if (spacingError != null) return Err(spacingError);

  final positions = _xPositions(keys, temporalSpacing);
  final numericGrid = projectMultiSeries(views, formatters: formatters);

  final series = <LineSeriesData>[];
  final legend = <LegendEntry>[];
  for (var s = 0; s < views.length; s++) {
    final color = palette.resolve(
      index: s,
      semanticTag: views[s].semanticTag,
      key: views[s].key,
      resolver: resolver,
    );
    final points = <LinePoint>[];
    for (var i = 0; i < positions.length; i++) {
      final y = numericGrid[s][i];
      if (y == null) continue;
      points.add(LinePoint(x: positions[i], y: y));
    }
    series.add(
      LineSeriesData(name: views[s].label, points: points, color: color),
    );
    legend.add(LegendEntry(label: views[s].label, color: color));
  }

  return Ok(
    assembleLineChartData(
      series: series,
      keys: keys,
      positions: positions,
      numericGrid: numericGrid,
      formatters: formatters,
      temporalSpacing: temporalSpacing,
      integerValued: integerValued,
      unitType: unitType,
      // A single line needs no legend; multi-line gets one.
      legend: series.length > 1 ? legend : const [],
    ),
  );
}

/// Computes X positions for the buckets. Uniform → `0, 1, 2, …`; epochMs →
/// each temporal key's epoch ms (non-temporal keys fall back to their index).
List<double> _xPositions(List<BucketKey> keys, TemporalSpacing spacing) {
  if (spacing == TemporalSpacing.uniform) {
    return [for (var i = 0; i < keys.length; i++) i.toDouble()];
  }
  return [
    for (var i = 0; i < keys.length; i++)
      switch (keys[i]) {
        TimeBucketKey(instant: final t) => t.millisecondsSinceEpoch.toDouble(),
        _ => i.toDouble(),
      },
  ];
}
