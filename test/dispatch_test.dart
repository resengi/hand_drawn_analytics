import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import 'support.dart';

// The dispatcher routes an already-computed result + a display-type string to a
// widget. These tests cover the builder registry: a matching builder replaces
// the default template-based rendering, an unset slot falls back, and error or
// empty mappings always use the default (builders never see failures).

/// A sentinel the consumer's builder returns, so its presence proves the
/// builder ran instead of the default template.
const _sentinel = Key('consumer-widget');
Widget _consumerWidget(Object _) => const SizedBox(key: _sentinel);

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('builder registry', () {
    testWidgets('a bar builder replaces the default bar rendering', (
      tester,
    ) async {
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(series([bucket(sk('a'), iv(1))])),
          displayType: 'bar',
          builders: const AnalyticsWidgetBuilders(bar: _consumerWidget),
        ),
      );
      expect(find.byKey(_sentinel), findsOneWidget);
      expect(find.byType(HandDrawnBarChart), findsNothing);
    });

    testWidgets('with no builders the default template renders', (
      tester,
    ) async {
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(series([bucket(sk('a'), iv(1))])),
          displayType: 'bar',
        ),
      );
      expect(find.byKey(_sentinel), findsNothing);
      expect(find.byType(HandDrawnBarChart), findsOneWidget);
    });

    testWidgets('a partial registry leaves unlisted kinds on defaults', (
      tester,
    ) async {
      // Only `bar` is supplied; a `table` display must still use the default.
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(series([bucket(sk('a'), iv(1))])),
          displayType: 'table',
          builders: const AnalyticsWidgetBuilders(bar: _consumerWidget),
        ),
      );
      expect(find.byKey(_sentinel), findsNothing);
      expect(find.byType(HandDrawnTable), findsOneWidget);
    });

    testWidgets('the scatter builder receives a ScatterMapping', (
      tester,
    ) async {
      ScatterMapping? received;
      final x = series([bucket(sk('a'), iv(1)), bucket(sk('b'), iv(2))]);
      final y = series([bucket(sk('a'), iv(3)), bucket(sk('b'), iv(4))]);
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: PairedResult(x: x, y: y),
          displayType: 'scatter',
          builders: AnalyticsWidgetBuilders(
            scatter: (mapping) {
              received = mapping;
              return const SizedBox(key: _sentinel);
            },
          ),
        ),
      );
      expect(find.byKey(_sentinel), findsOneWidget);
      expect(received, isNotNull);
      expect(received!.data.points, hasLength(2));
      expect(received!.droppedCount, 0);
    });

    testWidgets('the table builder receives a TableMapping', (tester) async {
      TableMapping? received;
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(series([bucket(sk('a'), iv(1))])),
          displayType: 'table',
          builders: AnalyticsWidgetBuilders(
            table: (mapping) {
              received = mapping;
              return const SizedBox(key: _sentinel);
            },
          ),
        ),
      );
      expect(find.byKey(_sentinel), findsOneWidget);
      expect(received, isNotNull);
      expect(received!.columns, isNotEmpty);
    });

    testWidgets('a shape-mismatched result uses the default, not the builder', (
      tester,
    ) async {
      // A single result handed to `scatter` (which needs a paired result) is a
      // shape error; the builder must not run.
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(series([bucket(sk('a'), iv(1))])),
          displayType: 'scatter',
          builders: AnalyticsWidgetBuilders(
            scatter: (_) {
              return const SizedBox(key: _sentinel);
            },
          ),
        ),
      );
      expect(find.byKey(_sentinel), findsNothing);
    });

    testWidgets('streak routes through the table builder', (tester) async {
      var ran = false;
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(
            streakTable([(id: 'u1', label: 'Ann', current: 3, longest: 9)]),
          ),
          displayType: 'streakLeaderboard',
          builders: AnalyticsWidgetBuilders(
            table: (_) {
              ran = true;
              return const SizedBox(key: _sentinel);
            },
          ),
        ),
      );
      expect(ran, isTrue);
      expect(find.byKey(_sentinel), findsOneWidget);
    });
  });

  group('default table rendering', () {
    testWidgets('a truncated table result renders the "+N more" footer', (
      tester,
    ) async {
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(
            streakTable([
              (id: 'u1', label: 'Ann', current: 3, longest: 9),
            ], truncatedCount: 2),
          ),
          displayType: 'table',
        ),
      );
      final table = tester.widget<HandDrawnTable>(find.byType(HandDrawnTable));
      // One data row plus the footer row.
      expect(table.rows, hasLength(2));
      expect(table.rows.last.cells.first, '+2 more');
    });

    testWidgets('a truncated streak leaderboard renders the "+N more" footer', (
      tester,
    ) async {
      await _pump(
        tester,
        HandDrawnAnalyticsWidget(
          result: SingleResult(
            streakTable([
              (id: 'u1', label: 'Ann', current: 3, longest: 9),
            ], truncatedCount: 4),
          ),
          displayType: 'streakLeaderboard',
        ),
      );
      final table = tester.widget<HandDrawnTable>(find.byType(HandDrawnTable));
      expect(table.rows, hasLength(2));
      expect(table.rows.last.cells.first, '+4 more');
    });
  });
}
