import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/painting.dart' show Alignment, Color;
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../errors.dart';
import '../formatters.dart';
import 'mapper_support.dart';

/// The bridge's stringified table projection of any analytics result.
class TableMapping {
  const TableMapping({
    required this.columns,
    required this.rows,
    required this.truncatedCount,
  });

  /// Column definitions with alignment derived from column kind.
  final List<HandDrawnTableColumn> columns;

  /// Rows of stringified cells, one cell per column.
  final List<HandDrawnTableRow> rows;

  /// Rows dropped upstream (e.g. by `topN` / `limit`); 0 means none.
  final int truncatedCount;
}

/// Universal intake: maps any [AnalyticsResult] to a [TableMapping].
///
/// This is the totality guarantee — every result is at least renderable as a
/// table. Scalars become a 1×1 table; the chart-shape views project via their
/// `toTableResult()`; a [TableResult] is consumed directly. Measure columns are
/// right-aligned, group-key columns left-aligned. Every value is stringified
/// through [formatters] (the toolkit's cells are `List<String>`).
Result<TableMapping, BridgeError> resultToTable(
  AnalyticsResult result, {
  required BridgeFormatters formatters,
}) {
  final table = switch (result) {
    ScalarResult() => _scalarTable(result, formatters),
    SeriesResult() => _fromTableResult(result.toTableResult(), formatters),
    MultiSeriesResult() => _fromTableResult(result.toTableResult(), formatters),
    MultiMeasureSeriesResult() => _fromTableResult(
      result.toTableResult(),
      formatters,
    ),
    TableResult() => _fromTableResult(result, formatters),
  };
  return Ok(table);
}

/// The big-number projection of a scalar result: a display string, the
/// measure label, and an optional color (left null — the widget decides).
///
/// Returns an [Err] when handed a non-scalar result, naming the table display
/// as the fitting alternative.
Result<({String displayValue, String? label, Color? color}), BridgeError>
scalarToBigNumber(
  AnalyticsResult result, {
  required BridgeFormatters formatters,
}) {
  if (result is! ScalarResult) {
    return Err(
      BridgeShapeMismatch(
        expected: ResultShape.scalar,
        actual: resultShapeOf(result),
        suggestion: 'a table',
      ),
    );
  }
  return Ok((
    displayValue: formatters.scalarValue(result.value),
    label: result.measureLabel,
    color: null,
  ));
}

/// Options controlling how a streak [TableResult] is laid out as a leaderboard.
class StreakTableOptions {
  const StreakTableOptions({
    this.entityLabelHeader = 'Name',
    this.currentStreakHeader = 'Current',
    this.longestStreakHeader = 'Longest',
    this.showEntityId = false,
    this.entityIdHeader = 'ID',
  });

  final String entityLabelHeader;
  final String currentStreakHeader;
  final String longestStreakHeader;
  final bool showEntityId;
  final String entityIdHeader;
}

/// Maps a `StreakMeasure` [TableResult] to a readable leaderboard [TableMapping]
/// (raw entity id hidden by default, wide name column, narrow streak counts).
///
/// Returns `null` when [table] is not streak-shaped (the expected
/// `entityLabel` / `currentStreak` / `longestStreak` columns are absent), so
/// the caller can fall back to a generic [resultToTable] projection.
TableMapping? streakToTable(
  TableResult table, {
  required BridgeFormatters formatters,
  StreakTableOptions options = const StreakTableOptions(),
}) {
  final byLabel = {for (final c in table.columns) c.label: c};
  final entityId = byLabel['entityId'];
  final entityLabel = byLabel['entityLabel'];
  final current = byLabel['currentStreak'];
  final longest = byLabel['longestStreak'];

  if (entityLabel == null || current == null || longest == null) return null;

  final includeId = options.showEntityId && entityId != null;
  final columns = <HandDrawnTableColumn>[
    if (includeId)
      HandDrawnTableColumn(header: options.entityIdHeader, flex: 2),
    HandDrawnTableColumn(header: options.entityLabelHeader, flex: 3),
    HandDrawnTableColumn(
      header: options.currentStreakHeader,
      alignment: Alignment.centerRight,
    ),
    HandDrawnTableColumn(
      header: options.longestStreakHeader,
      alignment: Alignment.centerRight,
    ),
  ];

  final rows = <HandDrawnTableRow>[];
  for (var r = 0; r < table.rowCount; r++) {
    rows.add(
      HandDrawnTableRow(
        cells: [
          if (includeId) formatters.tableCell(entityId.values[r]),
          formatters.tableCell(entityLabel.values[r]),
          formatters.tableCell(current.values[r]),
          formatters.tableCell(longest.values[r]),
        ],
      ),
    );
  }

  return TableMapping(
    columns: columns,
    rows: rows,
    truncatedCount: table.truncatedCount,
  );
}

// ── Internals ────────────────────────────────────────────────────────────────

TableMapping _scalarTable(ScalarResult result, BridgeFormatters formatters) {
  final header = result.measureLabel ?? 'Value';
  return TableMapping(
    columns: [
      HandDrawnTableColumn(header: header, alignment: Alignment.centerRight),
    ],
    rows: [
      HandDrawnTableRow(cells: [formatters.scalarValue(result.value)]),
    ],
    truncatedCount: 0,
  );
}

TableMapping _fromTableResult(TableResult table, BridgeFormatters formatters) {
  final columns = [
    for (final c in table.columns)
      HandDrawnTableColumn(
        header: c.label,
        alignment: c.kind == TableColumnKind.measure
            ? Alignment.centerRight
            : Alignment.centerLeft,
      ),
  ];

  final rows = <HandDrawnTableRow>[];
  for (var r = 0; r < table.rowCount; r++) {
    rows.add(
      HandDrawnTableRow(
        cells: [
          for (final c in table.columns) formatters.tableCell(c.values[r]),
        ],
      ),
    );
  }

  return TableMapping(
    columns: columns,
    rows: rows,
    truncatedCount: table.truncatedCount,
  );
}
