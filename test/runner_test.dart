import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';

import 'support.dart';

// Exercises the runner's orchestration directly: the resolved date range
// reaches both the fetcher and the executor, thrown failures become typed
// errors, one reference date is observed across a run, and the execution
// seam works synchronously or asynchronously.

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

SourceDef _source() => SourceDef(
  sourceId: 'events',
  displayName: 'Events',
  fields: [_field('at', FieldType.dateTime), _field('n', FieldType.integer)],
  primaryDateFieldId: 'at',
);

// A streak measure does not support a date range, so its query is the natural
// fixture for the no-range execution path.
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

SourceDef _habitSource() => SourceDef(
  sourceId: 'habits',
  displayName: 'Habits',
  fields: [
    _habitField('habitId', FieldType.string),
    _habitField('scheduledFor', FieldType.dateTime),
    _habitField('status', FieldType.enumeration),
  ],
);

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

// A Count/Field measure supports a date range, so the validator's cross-rule
// requires a non-NoDateRange mode. allTime is self-contained (no page range).
const _mode = FixedOverride(
  range: PresetRange(preset: DateRangePreset.allTime),
);

SingleQuerySpec _countByDay() => SingleQuerySpec(
  query: AnalyticsQuerySpec(
    source: 'events',
    measures: const [CountMeasure()],
    groupBys: [
      TimeGroupBy(
        dateFieldRef: const FieldRef(sourceId: 'events', fieldId: 'at'),
        grain: TimeGrain.day,
      ),
    ],
  ),
);

SingleQuerySpec _countByCategory() => SingleQuerySpec(
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

PairedQuerySpec _pairedByDay() =>
    PairedQuerySpec(xQuery: _countByDay().query, yQuery: _countByDay().query);

void main() {
  group('date range into execution', () {
    test(
      'a TimeGroupBy(day) query over a sparse range densifies gap days',
      () async {
        final start = DateTime.utc(2025, 4, 1);
        // CustomRange endpoints are inclusive, so Apr 1–7 spans seven days. The
        // records land on the first and last day, leaving five gap days between.
        final end = DateTime.utc(2025, 4, 7);
        final records = [
          SourceRecord(
            fields: {
              'at': DateTimeValue(DateTime.utc(2025, 4, 1, 9)),
              'n': const IntValue(1),
            },
          ),
          SourceRecord(
            fields: {
              'at': DateTimeValue(DateTime.utc(2025, 4, 7, 9)),
              'n': const IntValue(1),
            },
          ),
        ];

        final runner = WidgetQueryRunner(
          listSources: () => [_source()],
          fetchRecords: (_, {dateBound}) async => records,
        );

        final result = await runner.runSingle(
          _countByDay().query,
          dateRangeMode: FixedOverride(
            range: CustomRange(start: start, end: end),
          ),
        );
        final single = result.okOrNull! as SingleResult;
        final temporal = single.result as SeriesResult;
        // One bucket per day in the range, including the five empty ones, so a
        // temporal chart dips to zero rather than bridging the gap.
        expect(temporal.buckets, hasLength(7));
        expect(temporal.buckets.any((b) => b.isSynthetic), isTrue);
      },
    );

    test(
      'the executor seam receives the same range passed to the fetcher',
      () async {
        (DateTime, DateTime)? fetchBound;
        (DateTime, DateTime)? executeRange;

        final runner = WidgetQueryRunner(
          listSources: () => [_source()],
          fetchRecords: (_, {dateBound}) async {
            fetchBound = dateBound;
            return const [];
          },
          executeQuery: (request) {
            executeRange = request.dateRange;
            return Ok(series(const []));
          },
        );

        await runner.runSingle(_countByDay().query, dateRangeMode: _mode);

        expect(fetchBound, isNotNull);
        expect(executeRange, fetchBound);
      },
    );

    test(
      'both paired halves fetch and execute against one shared bound',
      () async {
        final fetchBounds = <(DateTime, DateTime)?>[];
        final executeRanges = <(DateTime, DateTime)?>[];

        final runner = WidgetQueryRunner(
          listSources: () => [_source()],
          fetchRecords: (_, {dateBound}) async {
            fetchBounds.add(dateBound);
            return const [];
          },
          executeQuery: (request) {
            executeRanges.add(request.dateRange);
            return Ok(series(const []));
          },
        );

        await runner.runPaired(_pairedByDay(), dateRangeMode: _mode);

        expect(fetchBounds, hasLength(2));
        expect(fetchBounds.first, fetchBounds.last);
        expect(executeRanges, hasLength(2));
        expect(executeRanges.first, fetchBounds.first);
        expect(executeRanges.last, fetchBounds.first);
      },
    );

    test(
      'a no-range query executes with a null range at the executor',
      () async {
        final runner = WidgetQueryRunner(
          listSources: () => [_habitSource()],
          fetchRecords: (_, {dateBound}) async => const [],
          executeQuery: (request) {
            expect(request.dateRange, isNull);
            return Ok(streakTable(const []));
          },
        );

        // A streak measure does not take a date range, so NoDateRange is its
        // valid mode and the resolved bound is null.
        final result = await runner.runSingle(
          _streakQuery().query,
          dateRangeMode: const NoDateRange(),
          asOf: DateTime.utc(2025, 1, 1),
        );
        expect(result.isOk, isTrue);
      },
    );
  });

  group('thrown failures become typed errors', () {
    // A Count measure supports a date range, so a FixedOverride mode passes
    // validation and the run reaches the fetch/execute steps where the injected
    // failures are thrown.
    Future<BridgeError?> errorFrom(WidgetQueryRunner runner) async {
      final result = await runner.runSingle(
        _countByCategory().query,
        dateRangeMode: _mode,
      );
      return result.errOrNull;
    }

    void expectUnexpected(BridgeError? error) {
      final analytics = error as BridgeAnalyticsError;
      expect(analytics.error.kind, AnalyticsErrorKind.unexpected);
    }

    test('listSources throwing yields an unexpected error', () async {
      final runner = WidgetQueryRunner(
        listSources: () => throw StateError('no sources'),
        fetchRecords: (_, {dateBound}) async => const [],
      );
      expectUnexpected(await errorFrom(runner));
    });

    test('fetchRecords throwing yields an unexpected error', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => throw StateError('db down'),
      );
      expectUnexpected(await errorFrom(runner));
    });

    test('an injected executor throwing yields an unexpected error', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (_) => throw StateError('bad invariant'),
      );
      expectUnexpected(await errorFrom(runner));
    });

    test('an async executor throwing yields an unexpected error', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (_) async => throw StateError('bad invariant'),
      );
      expectUnexpected(await errorFrom(runner));
    });

    test('the human message does not leak the thrown detail', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async =>
            throw StateError('secret://connection-string'),
      );
      final error = await errorFrom(runner);
      expect(error!.humanMessage, isNot(contains('secret')));
    });

    test('a thrown failure in a paired run is also typed', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => throw StateError('db down'),
      );
      final result = await runner.runPaired(
        _pairedByDay(),
        dateRangeMode: _mode,
      );
      expectUnexpected(result.errOrNull);
    });
  });

  group('one reference date per run', () {
    test('projection, fetch, and execution observe the same range', () async {
      (DateTime, DateTime)? fetchBound;
      (DateTime, DateTime)? executeRange;
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async {
          fetchBound = dateBound;
          return const [];
        },
        executeQuery: (request) {
          executeRange = request.dateRange;
          return Ok(series(const []));
        },
      );

      await runner.runSingle(_countByDay().query, dateRangeMode: _mode);

      expect(executeRange, fetchBound);
    });

    test('supplying today makes the resolved range deterministic', () async {
      final today = DateTime.utc(2025, 6, 15, 12);
      (DateTime, DateTime)? first;
      (DateTime, DateTime)? second;

      final runnerA = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (request) {
          first = request.dateRange;
          return Ok(series(const []));
        },
      );
      await runnerA.runSingle(
        _countByDay().query,
        dateRangeMode: const FixedOverride(
          range: PresetRange(preset: DateRangePreset.thisMonth),
        ),
        today: today,
      );

      final runnerB = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (request) {
          second = request.dateRange;
          return Ok(series(const []));
        },
      );
      await runnerB.runSingle(
        _countByDay().query,
        dateRangeMode: const FixedOverride(
          range: PresetRange(preset: DateRangePreset.thisMonth),
        ),
        today: today,
      );

      expect(first, isNotNull);
      expect(first, second);
    });

    test('a streak query runs without an explicit asOf', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_habitSource()],
        fetchRecords: (_, {dateBound}) async => const [],
      );

      // Through the real executor: the run supplies its own reference date,
      // which satisfies the executor's StreakMeasure precondition.
      final result = await runner.runSingle(
        _streakQuery().query,
        dateRangeMode: const NoDateRange(),
      );

      final single = result.okOrNull as SingleResult?;
      expect(single, isNotNull);
      expect(single!.result, isA<TableResult>());
    });

    test('an omitted asOf resolves to the run\'s reference date', () async {
      final today = DateTime.utc(2025, 6, 15, 12);
      DateTime? executedAsOf;
      final runner = WidgetQueryRunner(
        listSources: () => [_habitSource()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (request) {
          executedAsOf = request.asOf;
          return Ok(streakTable(const []));
        },
      );

      await runner.runSingle(
        _streakQuery().query,
        dateRangeMode: const NoDateRange(),
        today: today,
      );

      // The same instant that resolves relative date ranges backs asOf, so
      // range resolution and streak evaluation share one reference date.
      expect(executedAsOf, today);
    });

    test('an explicit asOf is passed through unchanged', () async {
      final asOf = DateTime.utc(2025, 3, 9);
      DateTime? executedAsOf;
      final runner = WidgetQueryRunner(
        listSources: () => [_habitSource()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (request) {
          executedAsOf = request.asOf;
          return Ok(streakTable(const []));
        },
      );

      await runner.runSingle(
        _streakQuery().query,
        dateRangeMode: const NoDateRange(),
        today: DateTime.utc(2025, 6, 15),
        asOf: asOf,
      );

      expect(executedAsOf, asOf);
    });

    test('both halves of a paired run receive the same asOf', () async {
      final today = DateTime.utc(2025, 6, 15, 12);
      final executedAsOfs = <DateTime?>[];
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (request) {
          executedAsOfs.add(request.asOf);
          return Ok(series(const []));
        },
      );

      await runner.runPaired(
        _pairedByDay(),
        dateRangeMode: _mode,
        today: today,
      );

      expect(executedAsOfs, hasLength(2));
      expect(executedAsOfs.first, today);
      expect(executedAsOfs.last, today);
    });
  });

  group('asynchronous executeQuery', () {
    test('an async executor\'s result is awaited', () async {
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (_) async {
          await Future<void>.delayed(Duration.zero);
          return Ok(series(const []));
        },
      );

      final result = await runner.runSingle(
        _countByCategory().query,
        dateRangeMode: _mode,
      );

      final single = result.okOrNull as SingleResult?;
      expect(single, isNotNull);
      expect(single!.result, isA<SeriesResult>());
    });

    test('a paired run awaits the executor for both halves', () async {
      var executions = 0;
      final runner = WidgetQueryRunner(
        listSources: () => [_source()],
        fetchRecords: (_, {dateBound}) async => const [],
        executeQuery: (_) async {
          await Future<void>.delayed(Duration.zero);
          executions += 1;
          return Ok(series(const []));
        },
      );

      final result = await runner.runPaired(
        _pairedByDay(),
        dateRangeMode: _mode,
      );

      expect(executions, 2);
      expect(result.okOrNull, isA<PairedResult>());
    });
  });
}
