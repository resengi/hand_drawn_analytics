import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';

/// Test fixture builders. Keep these tiny and explicit so each test reads as a
/// data table rather than constructor noise.

SeriesBucket bucket(BucketKey key, TypedValue? value) =>
    SeriesBucket(key: key, value: value);

SeriesResult series(
  List<SeriesBucket> buckets, {
  SeriesGroupKind groupKind = SeriesGroupKind.categorical,
  String measureLabel = 'measure',
  FieldType measureFieldType = FieldType.integer,
  String? semanticTag,
}) {
  return SeriesResult(
    buckets: buckets,
    groupKind: groupKind,
    groupColumnLabel: 'group',
    groupColumnFieldType: FieldType.string,
    measureLabel: measureLabel,
    measureFieldType: measureFieldType,
    semanticTag: semanticTag,
  );
}

MultiSeriesResult multiSeries({
  required List<XAxisPosition> xAxis,
  required List<NamedSeries> seriesList,
  FieldType measureFieldType = FieldType.integer,
}) {
  return MultiSeriesResult(
    xAxis: xAxis,
    series: seriesList,
    groupKind: SeriesGroupKind.categorical,
    primaryColumnLabel: 'primary',
    primaryColumnFieldType: FieldType.string,
    secondaryColumnLabel: 'secondary',
    secondaryColumnFieldType: FieldType.string,
    measureLabel: 'measure',
    measureFieldType: measureFieldType,
  );
}

MultiMeasureSeriesResult multiMeasure({
  required List<XAxisPosition> xAxis,
  required List<MeasureSeries> seriesList,
}) {
  return MultiMeasureSeriesResult(
    xAxis: xAxis,
    series: seriesList,
    groupKind: SeriesGroupKind.categorical,
    groupColumnLabel: 'group',
    groupColumnFieldType: FieldType.string,
  );
}

StringBucketKey sk(String v) => StringBucketKey(v);
IntValue iv(int v) => IntValue(v);
DoubleValue dv(double v) => DoubleValue(v);

/// A streak-shaped [TableResult] with the fixed leaderboard columns the streak
/// executor emits: `entityId`, `entityLabel`, `currentStreak`, `longestStreak`.
TableResult streakTable(
  List<({String id, String label, int current, int longest})> rows, {
  int truncatedCount = 0,
}) {
  return TableResult(
    columns: [
      TableColumn(
        label: 'entityId',
        fieldType: FieldType.string,
        kind: TableColumnKind.groupKey,
        values: [for (final r in rows) StringValue(r.id)],
      ),
      TableColumn(
        label: 'entityLabel',
        fieldType: FieldType.string,
        kind: TableColumnKind.measure,
        values: [for (final r in rows) StringValue(r.label)],
      ),
      TableColumn(
        label: 'currentStreak',
        fieldType: FieldType.integer,
        kind: TableColumnKind.measure,
        values: [for (final r in rows) IntValue(r.current)],
      ),
      TableColumn(
        label: 'longestStreak',
        fieldType: FieldType.integer,
        kind: TableColumnKind.measure,
        values: [for (final r in rows) IntValue(r.longest)],
      ),
    ],
    rowKeys: [
      for (final r in rows) RowKey([StringBucketKey(r.id)]),
    ],
    truncatedCount: truncatedCount,
  );
}

/// A persisted [AnalyticsWidgetSpec] built from typed payloads, encoded with
/// the real [WidgetPayloadCodec] so the JSON blobs match what storage holds.
AnalyticsWidgetSpec widgetSpec({
  required QueryPayload payload,
  String id = 'widget-1',
  String title = 'Card',
  String displayType = 'bar',
  DateRangeMode dateRangeMode = const NoDateRange(),
}) {
  return AnalyticsWidgetSpec(
    id: id,
    title: title,
    queryJson: WidgetPayloadCodec.encodeQueryPayload(payload),
    displayJson: WidgetPayloadCodec.encodeDisplaySpec(
      DisplaySpec(displayType: displayType),
    ),
    dateRangeModeJson: WidgetPayloadCodec.encodeDateRangeMode(dateRangeMode),
    sortOrder: 0,
    createdAt: DateTime.utc(2025),
    updatedAt: DateTime.utc(2025),
  );
}

/// A [WidgetQueryRunner] with stubbed execution that counts its query runs.
///
/// [runCount] increments once per [runSingle] or [runPaired] invocation, so a
/// widget test can assert exactly how many fetches an interaction triggered.
/// Execution bypasses real aggregation: a single run returns [result]; a
/// paired run returns it for both halves. [result] and [error] are settable so
/// a test can change what the next run produces.
class CountingStubRunner extends WidgetQueryRunner {
  CountingStubRunner({
    required List<SourceDef> sources,
    AnalyticsResult? result,
    AnalyticsError? error,
  }) : this._(_StubExecution(result: result, error: error), sources);

  CountingStubRunner._(this._execution, List<SourceDef> sources)
    : super(
        listSources: () => sources,
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: _execution.run,
      );

  final _StubExecution _execution;

  /// How many queries this runner has run.
  int runCount = 0;

  /// The result the next run returns (both halves of a paired run).
  set result(AnalyticsResult? value) => _execution.result = value;

  /// When non-null, the next run fails with this error instead of a result.
  set error(AnalyticsError? value) => _execution.error = value;

  @override
  Future<Result<BridgeResult, BridgeError>> runSingle(
    AnalyticsQuerySpec query, {
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
    DateTime? asOf,
  }) {
    runCount++;
    return super.runSingle(
      query,
      dateRangeMode: dateRangeMode,
      pageRange: pageRange,
      earliestDataDate: earliestDataDate,
      today: today,
      asOf: asOf,
    );
  }

  @override
  Future<Result<BridgeResult, BridgeError>> runPaired(
    PairedQuerySpec payload, {
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
    DateTime? asOf,
  }) {
    runCount++;
    return super.runPaired(
      payload,
      dateRangeMode: dateRangeMode,
      pageRange: pageRange,
      earliestDataDate: earliestDataDate,
      today: today,
      asOf: asOf,
    );
  }
}

/// Mutable execution stub backing [CountingStubRunner].
class _StubExecution {
  _StubExecution({this.result, this.error});

  AnalyticsResult? result;
  AnalyticsError? error;

  Result<AnalyticsResult, AnalyticsError> run(ExecuteQueryRequest request) {
    final e = error;
    if (e != null) return Err(e);
    return Ok(result ?? series(const []));
  }
}
