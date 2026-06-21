import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import 'support.dart';

// The scatter widget colors its points from the template's native dotColor, so
// it exposes no palette/colorResolver of its own. These tests pin that the
// reduced surface still renders and that dotColor flows through unchanged.

const _mode = FixedOverride(
  range: PresetRange(preset: DateRangePreset.allTime),
);

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
  fields: [_field('when', FieldType.dateTime), _field('n', FieldType.integer)],
  primaryDateFieldId: 'when',
);

WidgetQueryRunner _pairedRunner(SeriesResult x, SeriesResult y) {
  var call = 0;
  return WidgetQueryRunner(
    listSources: () => [_source()],
    fetchRecords: (_, {dateBound}) async => const [],
    // The paired runner executes the x half then the y half; hand each back in
    // turn so the alignment has two real series to work with.
    executeQuery: (_) => Ok(call++ == 0 ? x : y),
  );
}

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

void main() {
  testWidgets('renders without palette or color-resolver arguments', (
    tester,
  ) async {
    final runner = _pairedRunner(
      series([bucket(sk('a'), iv(1)), bucket(sk('b'), iv(2))]),
      series([bucket(sk('a'), iv(3)), bucket(sk('b'), iv(4))]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsScatterPlot(
          query: _pairedQuery(),
          chart: const HandDrawnScatterPlot(data: null),
          dateRangeMode: _mode,
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scatter = tester.widget<HandDrawnScatterPlot>(
      find.byType(HandDrawnScatterPlot),
    );
    expect(scatter.data, isNotNull);
    expect(scatter.data!.points, hasLength(2));
  });

  testWidgets('the template dotColor is preserved on the rendered plot', (
    tester,
  ) async {
    const dotColor = Color(0xFF123456);
    final runner = _pairedRunner(
      series([bucket(sk('a'), iv(1))]),
      series([bucket(sk('a'), iv(3))]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HandDrawnAnalyticsScatterPlot(
          query: _pairedQuery(),
          chart: const HandDrawnScatterPlot(data: null, dotColor: dotColor),
          dateRangeMode: _mode,
          runner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scatter = tester.widget<HandDrawnScatterPlot>(
      find.byType(HandDrawnScatterPlot),
    );
    expect(scatter.dotColor, dotColor);
  });
}
