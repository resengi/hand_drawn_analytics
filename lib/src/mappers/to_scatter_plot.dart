import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../errors.dart';
import '../formatters.dart';
import 'mapper_support.dart';

/// The result of [pairedToScatter]: the chart data plus how many buckets were
/// dropped during alignment, so a widget can optionally surface the data loss
/// (mirroring the table mapper's truncated-row count).
class ScatterMapping {
  const ScatterMapping({required this.data, required this.droppedCount});

  /// The aligned, plottable scatter data.
  final ScatterPlotData data;

  /// Buckets discarded during alignment: those present in only one series, plus
  /// aligned pairs whose value was null or non-numeric on either side. Zero
  /// when every bucket aligned cleanly.
  final int droppedCount;
}

/// Aligns two series by [BucketKey] and maps the matched `(x, y)` pairs to a
/// [ScatterMapping].
///
/// Buckets present in only one series are dropped; buckets whose value is null
/// in either series are dropped. The count of dropped buckets is reported on
/// the returned [ScatterMapping]. When no aligned, fully-defined pair survives,
/// returns an empty-but-valid mapping (the shape fit; only the values produced
/// nothing) whose [ScatterMapping.droppedCount] distinguishes "data existed but
/// nothing aligned" from "nothing there at all", so the widget shows its empty
/// state rather than an error.
///
/// Both series' measure types must be chartable; a non-numeric measure (e.g. a
/// `dateTime` axis) is rejected up front.
Result<ScatterMapping, BridgeError> pairedToScatter(
  SeriesResult x,
  SeriesResult y, {
  required BridgeFormatters formatters,
  String? xAxisLabel,
  String? yAxisLabel,
}) {
  if (!isChartableFieldType(x.measureFieldType)) {
    return Err(unchartableValueError(x.measureFieldType));
  }
  if (!isChartableFieldType(y.measureFieldType)) {
    return Err(unchartableValueError(y.measureFieldType));
  }

  final yByKey = {for (final b in y.buckets) b.key: b.value};

  final points = <ScatterPoint>[];
  final xs = <double?>[];
  final ys = <double?>[];
  var dropped = 0;
  for (final bucket in x.buckets) {
    if (!yByKey.containsKey(bucket.key)) {
      dropped++; // present only in x
      continue;
    }
    final xv = formatters.chartNumeric(bucket.value);
    final yv = formatters.chartNumeric(yByKey[bucket.key]);
    if (xv == null || yv == null) {
      dropped++; // aligned but unplottable on one side
      continue;
    }
    points.add(ScatterPoint(x: xv, y: yv));
    xs.add(xv);
    ys.add(yv);
  }
  // Keys present only in y are dropped too.
  final xKeys = {for (final b in x.buckets) b.key};
  for (final bucket in y.buckets) {
    if (!xKeys.contains(bucket.key)) dropped++;
  }

  // No aligned, fully-defined pair survived. This is a value-level outcome (the
  // shape fit; the values produced nothing), so report an empty-but-valid
  // mapping the widget's empty state can render, still carrying droppedCount so
  // a builder can tell "data existed but nothing aligned" (droppedCount > 0)
  // from "nothing there at all" (droppedCount == 0).
  if (points.isEmpty) {
    return Ok(
      ScatterMapping(
        droppedCount: dropped,
        data: ScatterPlotData(
          points: const [],
          minX: 0,
          maxX: 1,
          minY: 0,
          maxY: 1,
          xAxisLabel: xAxisLabel ?? x.measureLabel,
          yAxisLabel: yAxisLabel ?? y.measureLabel,
        ),
      ),
    );
  }

  final xRange = nicePaddedRange(xs);
  final yRange = nicePaddedRange(ys);
  return Ok(
    ScatterMapping(
      droppedCount: dropped,
      data: ScatterPlotData(
        points: points,
        minX: xRange?.min ?? 0,
        maxX: xRange?.max ?? 1,
        minY: yRange?.min ?? 0,
        maxY: yRange?.max ?? 1,
        xAxisLabel: xAxisLabel ?? x.measureLabel,
        yAxisLabel: yAxisLabel ?? y.measureLabel,
      ),
    ),
  );
}
