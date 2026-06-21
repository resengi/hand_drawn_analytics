import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

FieldDef _field(String id, FieldType type) => FieldDef(
  fieldId: id,
  sourceId: 'workouts',
  displayName: id,
  fieldType: type,
  filterable: true,
  groupable: true,
  aggregatable: true,
  sortable: true,
);

// A temporal source: a primary date field is required for date-range
// projection, which the date-range cross-rule forces for a Sum measure.
SourceDef _source() => SourceDef(
  sourceId: 'workouts',
  displayName: 'Workouts',
  fields: [
    _field('at', FieldType.dateTime),
    _field('day', FieldType.string),
    _field('reps', FieldType.integer),
  ],
  primaryDateFieldId: 'at',
);

void main() {
  testWidgets(
    'runner → real cache → executor → rendered bar chart with summed data',
    (tester) async {
      // Timestamps within the resolved range (allTime → roughly the last
      // year), so projection's date filter keeps them.
      final now = DateTime.now();
      final recent = DateTime(now.year, now.month, now.day);
      final records = <String, List<SourceRecord>>{
        'workouts': [
          SourceRecord(
            fields: {
              'at': DateTimeValue(recent),
              'day': const StringValue('Mon'),
              'reps': const IntValue(10),
            },
          ),
          SourceRecord(
            fields: {
              'at': DateTimeValue(recent),
              'day': const StringValue('Mon'),
              'reps': const IntValue(5),
            },
          ),
          SourceRecord(
            fields: {
              'at': DateTimeValue(recent),
              'day': const StringValue('Tue'),
              'reps': const IntValue(20),
            },
          ),
        ],
      };

      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async => records[sourceId] ?? const [],
      );

      final query = SingleQuerySpec(
        query: AnalyticsQuerySpec(
          source: 'workouts',
          measures: const [
            FieldMeasure(
              fieldRef: FieldRef(sourceId: 'workouts', fieldId: 'reps'),
              aggregation: SumAgg(),
            ),
          ],
          groupBys: const [
            FieldGroupBy(
              fieldRef: FieldRef(sourceId: 'workouts', fieldId: 'day'),
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AnalyticsScope(
            sources: [_source()],
            cache: cache,
            child: HandDrawnAnalyticsBarChart(
              query: query,
              chart: const HandDrawnBarChart(data: null),
              // A Sum measure supports a date range, so a non-NoDateRange mode
              // is required by the validator's cross-rule.
              dateRangeMode: const FixedOverride(
                range: PresetRange(preset: DateRangePreset.allTime),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final chart = tester.widget<HandDrawnBarChart>(
        find.byType(HandDrawnBarChart),
      );
      expect(chart.data, isNotNull);
      expect(chart.data!.bars, hasLength(2));
      // Values are summed by the real executor.
      final values = chart.data!.bars
          .map((b) => b.segments.first.value)
          .toList();
      expect(values, containsAll(<double>[15, 20]));
    },
  );
}
