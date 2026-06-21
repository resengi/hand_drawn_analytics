import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import 'support.dart';

// Cards own an AnalyticsQueryController and refetch exactly when a
// fetch-defining input changes: the payload (for the spec card, anything in
// the persisted data spec), the date-range mode, the runner instance, and the
// date inputs the mode actually consults. Everything else — chrome, styling,
// scope fields the query doesn't read — re-renders without a refetch.
// Reload triggers refresh in place, except `dateRange` events, which are
// prop-driven and skipped outright.

const _allTime = FixedOverride(
  range: PresetRange(preset: DateRangePreset.allTime),
);
const _last30 = FixedOverride(
  range: PresetRange(preset: DateRangePreset.last30Days),
);
const _pageMode = UsePageRange();

final _r1 = (DateTime.utc(2025, 1, 1), DateTime.utc(2025, 2, 1));
final _r2 = (DateTime.utc(2025, 2, 1), DateTime.utc(2025, 3, 1));
final _t1 = DateTime.utc(2025, 6, 15);
final _t2 = DateTime.utc(2025, 7, 15);

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

FieldDef _habitField(String id, FieldType type) => FieldDef(
  fieldId: id,
  sourceId: 'habits',
  displayName: id,
  fieldType: type,
  filterable: true,
  groupable: true,
  aggregatable: true,
  sortable: true,
);

SourceDef _habitsSource() => SourceDef(
  sourceId: 'habits',
  displayName: 'Habits',
  fields: [
    _habitField('habitId', FieldType.string),
    _habitField('scheduledFor', FieldType.dateTime),
    _habitField('status', FieldType.enumeration),
  ],
);

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

PairedQuerySpec _pairedQuery() {
  final half = AnalyticsQuerySpec(
    source: 'events',
    measures: const [CountMeasure()],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'events', fieldId: 'n'),
      ),
    ],
  );
  return PairedQuerySpec(xQuery: half, yQuery: half);
}

SingleQuerySpec _streakQuery() => SingleQuerySpec(
  query: AnalyticsQuerySpec(
    source: 'habits',
    measures: const [
      StreakMeasure(
        entityIdField: FieldRef(sourceId: 'habits', fieldId: 'habitId'),
        scheduledDateField: FieldRef(
          sourceId: 'habits',
          fieldId: 'scheduledFor',
        ),
        statusField: FieldRef(sourceId: 'habits', fieldId: 'status'),
        completedStatusValue: 'done',
      ),
    ],
  ),
);

CountingStubRunner _runner({AnalyticsResult? result}) =>
    CountingStubRunner(sources: [_source()], result: result);

Widget _app(Widget child) => MaterialApp(home: child);

void main() {
  group('spec content changes', () {
    testWidgets('a changed query under the same id refetches and renders the '
        'new result', (tester) async {
      final runner = _runner(result: series([bucket(sk('a'), iv(1))]));
      await tester.pumpWidget(
        _app(
          HandDrawnAnalyticsCard(
            spec: widgetSpec(payload: _countQuery(), dateRangeMode: _allTime),
            runner: runner,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      // Same id and title; only the query payload differs.
      runner.result = series([bucket(sk('a'), iv(1)), bucket(sk('b'), iv(2))]);
      await tester.pumpWidget(
        _app(
          HandDrawnAnalyticsCard(
            spec: widgetSpec(payload: _sumQuery(), dateRangeMode: _allTime),
            runner: runner,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 2);
      final chart = tester.widget<HandDrawnBarChart>(
        find.byType(HandDrawnBarChart),
      );
      expect(chart.data!.bars, hasLength(2));
    });

    testWidgets('a title-only change updates the chrome without a refetch', (
      tester,
    ) async {
      final runner = _runner(result: series([bucket(sk('a'), iv(1))]));
      Widget build(String title) => _app(
        HandDrawnAnalyticsCard(
          spec: widgetSpec(
            payload: _countQuery(),
            dateRangeMode: _allTime,
            title: title,
          ),
          runner: runner,
        ),
      );

      await tester.pumpWidget(build('Before'));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
      expect(find.text('Before'), findsOneWidget);

      await tester.pumpWidget(build('After'));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
      expect(find.text('After'), findsOneWidget);
    });
  });

  group('reload signals', () {
    testWidgets('a dateRange event is skipped even under an always-true '
        'predicate', (tester) async {
      final runner = _runner();
      final trigger = ValueNotifier<AnalyticsChange?>(null);
      addTearDown(trigger.dispose);
      await tester.pumpWidget(
        _app(
          HandDrawnAnalyticsCard(
            spec: widgetSpec(payload: _countQuery(), dateRangeMode: _pageMode),
            pageRange: _r1,
            runner: runner,
            reloadTrigger: trigger,
            shouldReload: (change, sourceIds) => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      trigger.value = AnalyticsChange(kind: AnalyticsChangeKind.dateRange);
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
    });

    testWidgets('a page-range change with a coincident dateRange event '
        'fetches exactly once', (tester) async {
      final runner = _runner();
      final trigger = ValueNotifier<AnalyticsChange?>(null);
      addTearDown(trigger.dispose);
      Widget build((DateTime, DateTime) pageRange) => _app(
        HandDrawnAnalyticsCard(
          spec: widgetSpec(payload: _countQuery(), dateRangeMode: _pageMode),
          pageRange: pageRange,
          runner: runner,
          reloadTrigger: trigger,
          shouldReload: (change, sourceIds) => true,
        ),
      );

      await tester.pumpWidget(build(_r1));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      // A page-level range move arrives twice: as a trigger event and as a
      // new pageRange prop. Only the prop fetches.
      trigger.value = AnalyticsChange(kind: AnalyticsChangeKind.dateRange);
      await tester.pumpWidget(build(_r2));
      await tester.pumpAndSettle();
      expect(runner.runCount, 2);
    });

    testWidgets('a sourceData event for a read source refreshes in place', (
      tester,
    ) async {
      final runner = _runner();
      final trigger = ValueNotifier<AnalyticsChange?>(null);
      addTearDown(trigger.dispose);
      await tester.pumpWidget(
        _app(
          HandDrawnAnalyticsCard(
            spec: widgetSpec(payload: _countQuery(), dateRangeMode: _allTime),
            runner: runner,
            reloadTrigger: trigger,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      trigger.value = AnalyticsChange(
        kind: AnalyticsChangeKind.sourceData,
        sourceIds: {'events'},
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 2);
    });

    testWidgets('a sourceData event scoped to an unread source is skipped by '
        'the default predicate', (tester) async {
      final runner = _runner();
      final trigger = ValueNotifier<AnalyticsChange?>(null);
      addTearDown(trigger.dispose);
      await tester.pumpWidget(
        _app(
          HandDrawnAnalyticsCard(
            spec: widgetSpec(payload: _countQuery(), dateRangeMode: _allTime),
            runner: runner,
            reloadTrigger: trigger,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      trigger.value = AnalyticsChange(
        kind: AnalyticsChangeKind.sourceData,
        sourceIds: {'somewhere-else'},
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
    });

    test('the default predicate treats dateRange as prop-driven', () {
      final dateRange = AnalyticsChange(kind: AnalyticsChangeKind.dateRange);
      expect(defaultShouldReload(dateRange, {'events'}), isFalse);

      final unscoped = AnalyticsChange(kind: AnalyticsChangeKind.sourceData);
      expect(defaultShouldReload(unscoped, {'events'}), isTrue);
    });
  });

  group('fetch-defining inputs', () {
    testWidgets('a preset-range card refetches when today or the earliest '
        'data date moves', (tester) async {
      final runner = _runner();
      Widget build({required DateTime today, DateTime? earliest}) => _app(
        AnalyticsScalarCard(
          query: _countQuery(),
          dateRangeMode: _last30,
          runner: runner,
          today: today,
          earliestDataDate: earliest,
        ),
      );

      await tester.pumpWidget(build(today: _t1));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      await tester.pumpWidget(build(today: _t2));
      await tester.pumpAndSettle();
      expect(runner.runCount, 2);

      await tester.pumpWidget(
        build(today: _t2, earliest: DateTime.utc(2024, 1, 1)),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 3);
    });

    testWidgets('a page-range card refetches on the page range and ignores '
        'today', (tester) async {
      final runner = _runner();
      Widget build({
        required (DateTime, DateTime) pageRange,
        required DateTime today,
      }) => _app(
        AnalyticsScalarCard(
          query: _countQuery(),
          dateRangeMode: _pageMode,
          runner: runner,
          pageRange: pageRange,
          today: today,
        ),
      );

      await tester.pumpWidget(build(pageRange: _r1, today: _t1));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      await tester.pumpWidget(build(pageRange: _r1, today: _t2));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      await tester.pumpWidget(build(pageRange: _r2, today: _t2));
      await tester.pumpAndSettle();
      expect(runner.runCount, 2);
    });

    testWidgets('a custom-range card ignores every date input', (tester) async {
      final runner = _runner();
      final mode = FixedOverride(
        range: CustomRange(
          start: DateTime.utc(2025, 1, 1),
          end: DateTime.utc(2025, 3, 31),
        ),
      );
      Widget build({
        (DateTime, DateTime)? pageRange,
        DateTime? today,
        DateTime? earliest,
      }) => _app(
        AnalyticsScalarCard(
          query: _countQuery(),
          dateRangeMode: mode,
          runner: runner,
          pageRange: pageRange,
          today: today,
          earliestDataDate: earliest,
        ),
      );

      await tester.pumpWidget(build(pageRange: _r1, today: _t1));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      await tester.pumpWidget(
        build(pageRange: _r2, today: _t2, earliest: DateTime.utc(2024, 1, 1)),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
    });

    testWidgets('a streak card (no date range) ignores page-range changes', (
      tester,
    ) async {
      final runner = CountingStubRunner(
        sources: [_habitsSource()],
        result: streakTable([(id: 'u1', label: 'Ada', current: 2, longest: 5)]),
      );
      final asOf = DateTime.utc(2025, 1, 1);
      Widget build((DateTime, DateTime) pageRange) => _app(
        HandDrawnAnalyticsCard(
          spec: widgetSpec(
            payload: _streakQuery(),
            displayType: 'streakLeaderboard',
            dateRangeMode: const NoDateRange(),
          ),
          pageRange: pageRange,
          asOf: asOf,
          runner: runner,
        ),
      );

      await tester.pumpWidget(build(_r1));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
      expect(find.byType(HandDrawnTable), findsOneWidget);

      await tester.pumpWidget(build(_r2));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
    });

    testWidgets('an explicit runner swap refetches through the new runner', (
      tester,
    ) async {
      final runnerA = _runner();
      final runnerB = _runner();
      Widget build(WidgetQueryRunner runner) => _app(
        AnalyticsScalarCard(
          query: _countQuery(),
          dateRangeMode: _allTime,
          runner: runner,
        ),
      );

      await tester.pumpWidget(build(runnerA));
      await tester.pumpAndSettle();
      expect(runnerA.runCount, 1);

      await tester.pumpWidget(build(runnerB));
      await tester.pumpAndSettle();
      expect(runnerB.runCount, 1);
      expect(runnerA.runCount, 1);
    });

    testWidgets('a render-only change does not refetch', (tester) async {
      final runner = _runner();
      Widget build(String title) => _app(
        AnalyticsScalarCard(
          query: _countQuery(),
          dateRangeMode: _allTime,
          runner: runner,
          title: title,
        ),
      );

      await tester.pumpWidget(build('Before'));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      await tester.pumpWidget(build('After'));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
      expect(find.text('After'), findsOneWidget);
    });
  });

  group('scope interplay', () {
    testWidgets('a card resolves the scope runner and fetches once on first '
        'load', (tester) async {
      var fetches = 0;
      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async {
          fetches++;
          return const [];
        },
      );
      await tester.pumpWidget(
        _app(
          AnalyticsScope(
            sources: [_source()],
            cache: cache,
            child: HandDrawnAnalyticsCard(
              spec: widgetSpec(payload: _countQuery(), dateRangeMode: _allTime),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fetches, 1);
      expect(find.byType(HandDrawnBarChart), findsOneWidget);
    });

    testWidgets('a coincident query and runner change fetches exactly once, '
        'on the new runner', (tester) async {
      // The query prop, the runner, and a scope field all change in the same
      // frame, so both lifecycle doors (didUpdateWidget and
      // didChangeDependencies) run. The card still fetches exactly once.
      final runnerA = _runner();
      final runnerB = _runner();
      final sources = [_source()];
      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async => const [],
      );
      Widget build({
        required SingleQuerySpec query,
        required WidgetQueryRunner runner,
        required BridgePalette palette,
      }) => _app(
        AnalyticsScope(
          sources: sources,
          cache: cache,
          palette: palette,
          child: AnalyticsScalarCard(
            query: query,
            dateRangeMode: _allTime,
            runner: runner,
            // No explicit formatters: the card reads them from the scope, so
            // scope notifications reach its didChangeDependencies.
          ),
        ),
      );

      await tester.pumpWidget(
        build(
          query: _countQuery(),
          runner: runnerA,
          palette: const BridgePalette(),
        ),
      );
      await tester.pumpAndSettle();
      expect(runnerA.runCount, 1);

      await tester.pumpWidget(
        build(
          query: _sumQuery(),
          runner: runnerB,
          palette: const BridgePalette(colors: [Color(0xFF112233)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(runnerB.runCount, 1);
      expect(runnerA.runCount, 1);
    });

    testWidgets('a palette-only scope change does not refetch', (tester) async {
      final runner = _runner();
      final sources = [_source()];
      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async => const [],
      );
      Widget build(BridgePalette palette) => _app(
        AnalyticsScope(
          sources: sources,
          cache: cache,
          palette: palette,
          child: AnalyticsScalarCard(
            query: _countQuery(),
            dateRangeMode: _allTime,
            runner: runner,
          ),
        ),
      );

      await tester.pumpWidget(build(const BridgePalette()));
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);

      await tester.pumpWidget(
        build(const BridgePalette(colors: [Color(0xFF112233)])),
      );
      await tester.pumpAndSettle();
      expect(runner.runCount, 1);
    });
  });

  group('decode failures', () {
    testWidgets('an unreadable spec renders a fixed message and runs nothing', (
      tester,
    ) async {
      final runner = _runner();
      final spec = AnalyticsWidgetSpec(
        id: 'w-bad',
        title: 'Bad',
        queryJson: 'not json',
        displayJson: WidgetPayloadCodec.encodeDisplaySpec(
          const DisplaySpec(displayType: 'bar'),
        ),
        dateRangeModeJson: WidgetPayloadCodec.encodeDateRangeMode(_allTime),
        sortOrder: 0,
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      );

      await tester.pumpWidget(
        _app(HandDrawnAnalyticsCard(spec: spec, runner: runner)),
      );
      await tester.pump();
      // The exact fixed message — decode internals never reach the card.
      expect(find.text('Analytics failed unexpectedly.'), findsOneWidget);
      expect(runner.runCount, 0);
    });
  });

  group('paired specs', () {
    testWidgets('a paired spec with a combination renders as a line chart', (
      tester,
    ) async {
      final runner = _runner(
        result: series([bucket(sk('a'), iv(2)), bucket(sk('b'), iv(4))]),
      );
      await tester.pumpWidget(
        _app(
          HandDrawnAnalyticsCard(
            spec: widgetSpec(
              payload: _pairedQuery(),
              displayType: 'line',
              dateRangeMode: _allTime,
            ),
            runner: runner,
            combination: const SumCombination(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(runner.runCount, 1);
      final chart = tester.widget<HandDrawnLineChart>(
        find.byType(HandDrawnLineChart),
      );
      expect(chart.data!.series, hasLength(1));
      expect(chart.data!.series.first.points, hasLength(2));
    });
  });
}
