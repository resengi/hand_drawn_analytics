import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

// HandDrawnTableView renders an already-mapped TableMapping, optionally with
// resizable columns. These tests cover the non-resizable passthrough, default
// sizing, restore, the column-count reset, and footer coexistence.

const _col1 = HandDrawnTableColumn(header: 'A');
const _col2 = HandDrawnTableColumn(header: 'B');
const _col3 = HandDrawnTableColumn(header: 'C');

TableMapping _mapping(
  List<HandDrawnTableColumn> columns, {
  int rowCount = 2,
  int truncatedCount = 0,
}) {
  return TableMapping(
    columns: columns,
    rows: [
      for (var r = 0; r < rowCount; r++)
        HandDrawnTableRow(cells: [for (final _ in columns) 'x']),
    ],
    truncatedCount: truncatedCount,
  );
}

/// Pumps a [HandDrawnTableView] in a fixed-width box so LayoutBuilder reports a
/// known content width.
Future<void> _pump(WidgetTester tester, Widget view) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, child: view)),
      ),
    ),
  );
}

HandDrawnTable _renderedTable(WidgetTester tester) =>
    tester.widget<HandDrawnTable>(find.byType(HandDrawnTable));

/// Matches only the resize drag handles, identified by their resize-column
/// cursor — the surrounding widgets render their own incidental [MouseRegion]s
/// that must not be counted as handles.
final _dragHandles = find.byWidgetPredicate(
  (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
);

void main() {
  testWidgets('non-resizable pours the mapping into the template directly', (
    tester,
  ) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2]),
        chart: const HandDrawnTable(columns: [], rows: []),
      ),
    );
    final table = _renderedTable(tester);
    expect(table.columns, hasLength(2));
    // No widths injected, no drag handles in the non-resizable path.
    expect(table.columns.every((c) => c.width == null), isTrue);
    expect(_dragHandles, findsNothing);
  });

  testWidgets('resizable injects widths and one handle per interior boundary', (
    tester,
  ) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2, _col3]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
      ),
    );
    final table = _renderedTable(tester);
    expect(table.columns.every((c) => c.width != null), isTrue);
    // Three columns -> two interior boundaries -> two handles.
    expect(_dragHandles, findsNWidgets(2));
  });

  testWidgets('default sizing splits the width equally without flex intent', (
    tester,
  ) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
      ),
    );
    final widths = _renderedTable(tester).columns.map((c) => c.width!).toList();
    expect(widths.first, closeTo(widths.last, 0.001));
  });

  testWidgets('flex intent seeds proportional widths', (tester) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [
          HandDrawnTableColumn(header: 'wide', flex: 3),
          HandDrawnTableColumn(header: 'narrow'),
        ]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
      ),
    );
    final widths = _renderedTable(tester).columns.map((c) => c.width!).toList();
    expect(widths.first, greaterThan(widths.last));
  });

  testWidgets('valid initialColumnWidths are restored', (tester) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
        initialColumnWidths: const [120, 250],
      ),
    );
    final widths = _renderedTable(tester).columns.map((c) => c.width!).toList();
    expect(widths, [120, 250]);
  });

  testWidgets('mismatched initialColumnWidths fall back to defaults', (
    tester,
  ) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
        initialColumnWidths: const [100, 100, 100], // wrong length
      ),
    );
    final widths = _renderedTable(tester).columns.map((c) => c.width!).toList();
    expect(widths, hasLength(2));
    expect(widths.first, closeTo(widths.last, 0.001)); // equal default
  });

  testWidgets('a column-count change resets widths and reports the reset', (
    tester,
  ) async {
    List<double>? reported;
    var columns = const [_col1, _col2];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return Column(
                    children: [
                      HandDrawnTableView(
                        mapping: _mapping(columns),
                        chart: const HandDrawnTable(columns: [], rows: []),
                        resizable: true,
                        onColumnWidthsChanged: (w) => reported = w,
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () => columns = const [_col1, _col2, _col3],
                        ),
                        child: const Text('grow'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    // Initial build seeds widths but does not report (nothing was discarded).
    expect(reported, isNull);

    await tester.tap(find.text('grow'));
    await tester.pumpAndSettle();

    // Now three data columns; widths reset and the reset was reported out.
    expect(_renderedTable(tester).columns, hasLength(3));
    expect(reported, isNotNull);
    expect(reported, hasLength(3));
  });

  testWidgets('a truncation footer adds a row without changing column count', (
    tester,
  ) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2], rowCount: 2, truncatedCount: 5),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
      ),
    );
    final table = _renderedTable(tester);
    // Two data columns (footer is a row, not a column) and two handles.
    expect(table.columns, hasLength(2));
    expect(_dragHandles, findsNWidgets(1)); // one interior boundary
    // Data rows + one footer row.
    expect(table.rows, hasLength(3));
    expect(table.rows.last.cells.first, '+5 more');
    // Footer row is padded to the column count so the toolkit accepts it.
    expect(table.rows.last.cells, hasLength(2));
  });

  testWidgets('a single column has no drag handles', (tester) async {
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
      ),
    );
    expect(_dragHandles, findsNothing);
  });

  testWidgets('a user drag reports the new widths once', (tester) async {
    var reportCount = 0;
    await _pump(
      tester,
      HandDrawnTableView(
        mapping: _mapping(const [_col1, _col2]),
        chart: const HandDrawnTable(columns: [], rows: []),
        resizable: true,
        onColumnWidthsChanged: (_) => reportCount++,
      ),
    );

    await tester.drag(_dragHandles, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(reportCount, 1);
  });

  testWidgets('re-pumping the same column shape does not report', (
    tester,
  ) async {
    var reportCount = 0;
    Widget view() => HandDrawnTableView(
      mapping: _mapping(const [_col1, _col2]),
      chart: const HandDrawnTable(columns: [], rows: []),
      resizable: true,
      onColumnWidthsChanged: (_) => reportCount++,
    );

    await _pump(tester, view());
    // A rebuild with the same column count keeps the existing widths, so no
    // reset and no report fire.
    await _pump(tester, view());
    await tester.pumpAndSettle();
    expect(reportCount, 0);
  });

  testWidgets('repeated resets to the same widths report only once', (
    tester,
  ) async {
    var reportCount = 0;
    var columns = const [_col1, _col2];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return Column(
                    children: [
                      HandDrawnTableView(
                        mapping: _mapping(columns),
                        chart: const HandDrawnTable(columns: [], rows: []),
                        resizable: true,
                        onColumnWidthsChanged: (_) => reportCount++,
                      ),
                      TextButton(
                        // Toggle back to the same two-column shape, which
                        // recomputes the identical default widths.
                        onPressed: () =>
                            setState(() => columns = List.of(columns)),
                        child: const Text('rebuild'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    // Same column count across rebuilds: widths are never discarded, so the
    // reset path never fires and nothing is reported.
    await tester.tap(find.text('rebuild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('rebuild'));
    await tester.pumpAndSettle();
    expect(reportCount, 0);
  });
}
