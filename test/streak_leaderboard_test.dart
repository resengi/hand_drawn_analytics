import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import 'support.dart';

// The leaderboard renders through HandDrawnTableView, so a topN-capped streak
// result surfaces the "+N more" footer.

FieldDef _field(String id, FieldType type) => FieldDef(
  fieldId: id,
  sourceId: 'habits',
  displayName: id,
  fieldType: type,
  filterable: true,
  groupable: true,
  aggregatable: true,
  sortable: true,
);

SourceDef _source() => SourceDef(
  sourceId: 'habits',
  displayName: 'Habits',
  fields: [
    _field('habitId', FieldType.string),
    _field('scheduledFor', FieldType.dateTime),
    _field('status', FieldType.enumeration),
  ],
);

WidgetQueryRunner _streakRunner(TableResult table) => WidgetQueryRunner(
  listSources: () => [_source()],
  fetchRecords: (_, {dateBound}) async => const [],
  executeQuery: (_) => Ok(table),
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

void main() {
  testWidgets('a truncated streak result renders the "+N more" footer', (
    tester,
  ) async {
    final runner = _streakRunner(
      streakTable([
        (id: 'u1', label: 'Ada', current: 5, longest: 9),
      ], truncatedCount: 3),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsStreakLeaderboard(
          query: _streakQuery(),
          chart: const HandDrawnTable(columns: [], rows: []),
          asOf: DateTime.utc(2025, 1, 1),
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<HandDrawnTable>(find.byType(HandDrawnTable));
    // One data row plus the footer row.
    expect(table.rows, hasLength(2));
    expect(table.rows.last.cells.first, '+3 more');
  });

  testWidgets('an untruncated streak result has no footer', (tester) async {
    final runner = _streakRunner(
      streakTable([(id: 'u1', label: 'Ada', current: 5, longest: 9)]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsStreakLeaderboard(
          query: _streakQuery(),
          chart: const HandDrawnTable(columns: [], rows: []),
          asOf: DateTime.utc(2025, 1, 1),
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<HandDrawnTable>(find.byType(HandDrawnTable));
    expect(table.rows, hasLength(1));
  });

  testWidgets('the leaderboard renders without an explicit asOf', (
    tester,
  ) async {
    final runner = _streakRunner(
      streakTable([(id: 'u1', label: 'Ada', current: 5, longest: 9)]),
    );
    // asOf is optional: when omitted, the runner resolves the reference date
    // at fetch time.
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsStreakLeaderboard(
          query: _streakQuery(),
          chart: const HandDrawnTable(columns: [], rows: []),
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<HandDrawnTable>(find.byType(HandDrawnTable));
    expect(table.rows, hasLength(1));
    expect(table.rows.first.cells, contains('Ada'));
  });
}
