import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import 'support.dart';

// A Count/Field measure supports a date range, so the validator's
// cross-rule requires a non-NoDateRange mode. allTime is self-contained
// (no pageRange needed) and the stubbed executor ignores the resulting
// filters, so it keeps these widget tests deterministic.
const _mode = FixedOverride(
  range: PresetRange(preset: DateRangePreset.allTime),
);

/// A field declaration with the common boolean capability flags enabled.
FieldDef _field(String id, FieldType type) => FieldDef(
  fieldId: id,
  sourceId: 'events',
  displayName: id,
  fieldType: type,
  filterable: true,
  groupable: true,
  aggregatable: true,
  sortable: true,
);

/// A source with a primary date field so date-range projection is valid.
SourceDef _source() => SourceDef(
  sourceId: 'events',
  displayName: 'Events',
  fields: [_field('when', FieldType.dateTime), _field('n', FieldType.integer)],
  primaryDateFieldId: 'when',
);

/// Builds a runner whose execution is stubbed to return [result] (or an error),
/// bypassing real aggregation so widget tests stay deterministic.
WidgetQueryRunner _stubRunner({
  AnalyticsResult? result,
  AnalyticsError? error,
}) {
  return WidgetQueryRunner(
    listSources: () => [_source()],
    fetchRecords: (_, {dateBound}) async => const [],
    executeQuery: (_) =>
        error != null ? Err(error) : Ok(result ?? series(const [])),
  );
}

SingleQuerySpec _countQuery() => SingleQuerySpec(
  query: AnalyticsQuerySpec(
    source: 'events',
    measures: const [CountMeasure()],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'events', fieldId: 'n'),
      ),
    ],
  ),
);

SingleQuerySpec _sumQuery() => SingleQuerySpec(
  query: AnalyticsQuerySpec(
    source: 'events',
    measures: const [
      FieldMeasure(
        fieldRef: FieldRef(sourceId: 'events', fieldId: 'n'),
        aggregation: SumAgg(),
      ),
    ],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'events', fieldId: 'n'),
      ),
    ],
  ),
);

SingleQuerySpec _averageQuery() => SingleQuerySpec(
  query: AnalyticsQuerySpec(
    source: 'events',
    measures: const [
      FieldMeasure(
        fieldRef: FieldRef(sourceId: 'events', fieldId: 'n'),
        aggregation: AverageAgg(),
      ),
    ],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'events', fieldId: 'n'),
      ),
    ],
  ),
);

Future<BarChartData> _pumpBarData(
  WidgetTester tester, {
  required SingleQuerySpec query,
  required AnalyticsResult result,
  bool? integerValued,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HandDrawnAnalyticsBarChart(
        query: query,
        chart: const HandDrawnBarChart(data: null),
        dateRangeMode: _mode,
        runner: _stubRunner(result: result),
        integerValued: integerValued,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.widget<HandDrawnBarChart>(find.byType(HandDrawnBarChart)).data!;
}

void main() {
  testWidgets('renders the template (loading) before data resolves', (
    tester,
  ) async {
    final runner = _stubRunner(result: series([bucket(sk('a'), iv(1))]));
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsBarChart(
          query: _countQuery(),
          chart: const HandDrawnBarChart(data: null),
          dateRangeMode: _mode,
          runner: runner,
        ),
      ),
    );
    // First synchronous frame: the controller is still loading, so the bare
    // template is shown. It must build without throwing.
    expect(find.byType(HandDrawnBarChart), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('resolves to data and fills the template', (tester) async {
    final runner = _stubRunner(
      result: series([bucket(sk('a'), iv(3)), bucket(sk('b'), iv(6))]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsBarChart(
          query: _countQuery(),
          chart: const HandDrawnBarChart(data: null),
          dateRangeMode: _mode,
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chart = tester.widget<HandDrawnBarChart>(
      find.byType(HandDrawnBarChart),
    );
    expect(chart.data, isNotNull);
    expect(chart.data!.bars, hasLength(2));
  });

  testWidgets('an explicit override replaces the bridge-computed value', (
    tester,
  ) async {
    final runner = _stubRunner(result: series([bucket(sk('a'), iv(3))]));
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsBarChart(
          query: _countQuery(),
          chart: const HandDrawnBarChart(data: null),
          dateRangeMode: _mode,
          runner: runner,
          maxY: 999, // explicit override
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chart = tester.widget<HandDrawnBarChart>(
      find.byType(HandDrawnBarChart),
    );
    expect(chart.data!.maxY, 999);
  });

  testWidgets('an execution error renders the empty state with a message', (
    tester,
  ) async {
    final runner = _stubRunner(
      error: const AnalyticsError(
        kind: AnalyticsErrorKind.unexpected,
        humanMessage: 'boom',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsBarChart(
          query: _countQuery(),
          chart: const HandDrawnBarChart(data: null),
          dateRangeMode: _mode,
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chart = tester.widget<HandDrawnBarChart>(
      find.byType(HandDrawnBarChart),
    );
    expect(chart.data, isNotNull); // empty data, not null
    expect(chart.data!.isEmpty, isTrue);
    expect(chart.emptyMessage, 'boom');
  });

  testWidgets('resolves the runner from an enclosing AnalyticsScope', (
    tester,
  ) async {
    final cache = SourceSnapshotCache(
      fetcher: (sourceId, {dateBound}) async => const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsScope(
          sources: [_source()],
          cache: cache,
          child: HandDrawnAnalyticsBarChart(
            query: _countQuery(),
            chart: const HandDrawnBarChart(data: null),
            dateRangeMode: _mode,
            // No runner passed — must come from the scope.
          ),
        ),
      ),
    );
    // Builds without a missing-scope empty state on the first frame.
    expect(find.byType(HandDrawnBarChart), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'without a runner or scope, shows the missing-config empty state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HandDrawnAnalyticsBarChart(
            query: _countQuery(),
            chart: const HandDrawnBarChart(data: null),
            dateRangeMode: _mode,
          ),
        ),
      );
      await tester.pump();
      final chart = tester.widget<HandDrawnBarChart>(
        find.byType(HandDrawnBarChart),
      );
      expect(chart.emptyMessage, contains('runner'));
    },
  );

  testWidgets('changing today on a preset-range widget re-runs the query', (
    tester,
  ) async {
    var executions = 0;
    final runner = WidgetQueryRunner(
      listSources: () => [_source()],
      fetchRecords: (_, {dateBound}) async => const [],
      executeQuery: (_) {
        executions++;
        return Ok(series([bucket(sk('a'), iv(1))]));
      },
    );

    Widget build(DateTime today) => MaterialApp(
      home: HandDrawnAnalyticsBarChart(
        query: _countQuery(),
        chart: const HandDrawnBarChart(data: null),
        dateRangeMode: const FixedOverride(
          range: PresetRange(preset: DateRangePreset.thisMonth),
        ),
        runner: runner,
        today: today,
      ),
    );

    await tester.pumpWidget(build(DateTime.utc(2025, 6, 15)));
    await tester.pumpAndSettle();
    expect(executions, 1);

    // A different reference date is a data-defining input, so the host rebuilds
    // its controller and the query runs again.
    await tester.pumpWidget(build(DateTime.utc(2025, 7, 15)));
    await tester.pumpAndSettle();
    expect(executions, 2);
  });

  testWidgets('swapping the runner re-runs the query through the new runner', (
    tester,
  ) async {
    final runnerA = CountingStubRunner(sources: [_source()]);
    final runnerB = CountingStubRunner(sources: [_source()]);

    Widget build(WidgetQueryRunner runner) => MaterialApp(
      home: HandDrawnAnalyticsBarChart(
        query: _countQuery(),
        chart: const HandDrawnBarChart(data: null),
        dateRangeMode: _mode,
        runner: runner,
      ),
    );

    await tester.pumpWidget(build(runnerA));
    await tester.pumpAndSettle();
    expect(runnerA.runCount, 1);

    // A different runner instance means different data, so the host rebuilds
    // its controller and the query runs against the new runner.
    await tester.pumpWidget(build(runnerB));
    await tester.pumpAndSettle();
    expect(runnerB.runCount, 1);
    expect(runnerA.runCount, 1);
  });

  testWidgets('a multi-series result renders grouped under the default mode', (
    tester,
  ) async {
    final result = multiSeries(
      xAxis: [
        const XAxisPosition(key: StringBucketKey('Q1')),
        const XAxisPosition(key: StringBucketKey('Q2')),
      ],
      seriesList: [
        NamedSeries(key: sk('A'), values: [iv(1), iv(2)]),
        NamedSeries(key: sk('B'), values: [iv(3), iv(4)]),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsBarChart(
          query: _countQuery(),
          chart: const HandDrawnBarChart(data: null),
          dateRangeMode: _mode,
          runner: _stubRunner(result: result),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chart = tester.widget<HandDrawnBarChart>(
      find.byType(HandDrawnBarChart),
    );
    expect(chart.data!.categories, hasLength(2));
    expect(chart.data!.legend, hasLength(2));
  });

  group('integer-axis inference at the widget layer', () {
    // 2.5 snaps to a whole number (3) under integer formatting and stays 2.5
    // otherwise, so maxY is the observable signal that the right flag reached
    // the mapper.
    testWidgets('a sum over an integer field defaults to integer ticks', (
      tester,
    ) async {
      final data = await _pumpBarData(
        tester,
        query: _sumQuery(),
        result: series([
          bucket(sk('a'), dv(2.5)),
        ], measureFieldType: FieldType.integer),
      );
      expect(data.maxY, 3); // snapped to a whole number
    });

    testWidgets('an average defaults to non-integer ticks', (tester) async {
      final data = await _pumpBarData(
        tester,
        query: _averageQuery(),
        result: series([
          bucket(sk('a'), dv(2.5)),
        ], measureFieldType: FieldType.double),
      );
      expect(data.maxY, 2.5); // not snapped
    });

    testWidgets('an explicit false forces non-integer ticks', (tester) async {
      // The measure would infer integer, but the explicit flag wins.
      final data = await _pumpBarData(
        tester,
        query: _countQuery(),
        result: series([
          bucket(sk('a'), dv(2.5)),
        ], measureFieldType: FieldType.integer),
        integerValued: false,
      );
      expect(data.maxY, 2.5);
    });

    testWidgets('an explicit true forces integer ticks', (tester) async {
      final data = await _pumpBarData(
        tester,
        query: _averageQuery(),
        result: series([
          bucket(sk('a'), dv(2.5)),
        ], measureFieldType: FieldType.double),
        integerValued: true,
      );
      expect(data.maxY, 3);
    });
  });
}
