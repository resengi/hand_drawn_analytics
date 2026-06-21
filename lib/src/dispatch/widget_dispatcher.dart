import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../analytics_scope.dart';
import '../colors.dart';
import '../errors.dart';
import '../formatters.dart';
import '../mappers/mapper_support.dart';
import '../mappers/to_bar_chart.dart';
import '../mappers/to_line_chart.dart';
import '../mappers/to_scatter_plot.dart';
import '../mappers/to_table.dart';
import '../widgets/analytics_table.dart';

/// Consumer-supplied widget builders keyed by the bridge's mapped data class.
///
/// Each slot, when set, replaces the dispatcher's default rendering for the
/// kinds that map to that data class, receiving the finished, bridge-mapped
/// data. This is how a spec-driven dashboard carries the consumer's own
/// interactivity: the bridge still owns the result-to-data mapping, and the
/// builder owns only the final data-to-widget step.
///
/// Every slot is optional; an unset slot leaves that kind on default
/// rendering, so supplying builders is purely additive. Slots are keyed by
/// data class rather than by kind because several kinds collapse onto one
/// data class (all three bar kinds map to [BarChartData]; the `line` and
/// `multiLine` kinds map to [LineChartData]). The single/paired result split is
/// resolved before a builder runs, so builders only ever see a finished data
/// class.
///
/// Builders run only on a successful mapping. Error and empty results keep the
/// dispatcher's default empty-state rendering, so a builder never has to
/// reimplement the bridge's failure presentation.
class AnalyticsWidgetBuilders {
  const AnalyticsWidgetBuilders({
    this.bar,
    this.line,
    this.scatter,
    this.table,
  });

  /// Receives mapped [BarChartData] (the `bar`, `groupedBar`, and `stackedBar`
  /// kinds).
  final Widget Function(BarChartData data)? bar;

  /// Receives mapped [LineChartData] (the `line` and `multiLine` kinds,
  /// including a paired result reduced to a single line via a
  /// [SeriesCombination]).
  final Widget Function(LineChartData data)? line;

  /// Receives the mapped [ScatterMapping] (the `scatter` kind).
  ///
  /// The mapping carries [ScatterMapping.droppedCount] alongside the plottable
  /// data, so a builder can surface alignment data loss if it chooses.
  final Widget Function(ScatterMapping mapping)? scatter;

  /// Receives the mapped [TableMapping] (the `table` and `streakLeaderboard`
  /// kinds).
  ///
  /// The mapping carries [TableMapping.truncatedCount], not a pre-built footer
  /// row. A builder that delegates to [HandDrawnTableView] gets footer handling
  /// (and resizing) for free; a builder returning a different table widget is
  /// responsible for rendering its own footer from that count.
  final Widget Function(TableMapping mapping)? table;
}

/// Renders an already-computed [BridgeResult] according to a free-form
/// `displayType`, without running a query itself.
///
/// This is the routing layer: it resolves [displayType] to a
/// [HandDrawnVisualizationKind] (honoring any [AnalyticsScope] aliases), then
/// maps and renders the [result] with the matching per-kind template. It does
/// no fetching — a card or controller supplies [result]. An unrecognized
/// display type, or a result whose shape the chosen kind can't draw, renders an
/// error box rather than throwing.
///
/// Templates are optional; a kind with no supplied template uses a default
/// instance. Because this widget already holds the result, it maps directly
/// with the pure mappers instead of going through the query-running widgets.
class HandDrawnAnalyticsWidget extends StatelessWidget {
  const HandDrawnAnalyticsWidget({
    required this.result,
    required this.displayType,
    this.palette,
    this.formatters,
    this.colorResolver,
    this.barTemplate,
    this.lineTemplate,
    this.scatterTemplate,
    this.tableTemplate,
    this.builders,
    this.barMode = BarMode.single,
    this.combination,
    this.combinePolicy = UnmatchedBucketPolicy.drop,
    super.key,
  });

  /// The already-computed result to render.
  final BridgeResult result;

  /// The free-form display type, resolved against the kind vocabulary.
  final String displayType;

  final BridgePalette? palette;
  final BridgeFormatters? formatters;
  final SemanticColorResolver? colorResolver;

  /// Per-kind styling templates; defaulted when null.
  final HandDrawnBarChart? barTemplate;
  final HandDrawnLineChart? lineTemplate;
  final HandDrawnScatterPlot? scatterTemplate;
  final HandDrawnTable? tableTemplate;

  /// Optional consumer builders that replace default rendering per mapped data
  /// class. A null registry, or a registry with the relevant slot unset, uses
  /// the per-kind template instead.
  final AnalyticsWidgetBuilders? builders;

  /// Bar layout used when the resolved kind is the generic `bar` (the explicit
  /// `groupedBar` / `stackedBar` kinds set their own mode).
  final BarMode barMode;

  /// How to fold a [PairedResult] into a single series before rendering it as
  /// the resolved kind.
  ///
  /// Required when [result] is a [PairedResult] and the resolved kind is not
  /// `scatter`; the paired query's x and y series are combined under this
  /// operation (aligned by bucket key) into one series, which then renders
  /// through the ordinary single-series path. Ignored for a [SingleResult] and
  /// for the `scatter` kind (which consumes the pair directly). When null and a
  /// reduction is needed, the dispatcher renders an error box.
  final SeriesCombination? combination;

  /// How unmatched buckets are treated when [combination] reduces a paired
  /// result. Defaults to [UnmatchedBucketPolicy.drop] (intersection of keys).
  final UnmatchedBucketPolicy combinePolicy;

  @override
  Widget build(BuildContext context) {
    final scope = AnalyticsScope.maybeOf(context);
    final palette = this.palette ?? scope?.palette ?? const BridgePalette();
    final formatters =
        this.formatters ?? scope?.formatters ?? const BridgeFormatters();
    final resolver = colorResolver ?? scope?.colorResolver;
    final aliases = scope?.displayAliases ?? const {};

    final kind = HandDrawnVisualizationKind.resolve(
      displayType,
      aliases: aliases,
    );
    return switch (kind) {
      Err(error: final e) => _errorBox(
        'Unknown display type "${e.displayType}".',
      ),
      Ok(value: final k) => _renderKind(k, palette, formatters, resolver),
    };
  }

  Widget _renderKind(
    HandDrawnVisualizationKind kind,
    BridgePalette palette,
    BridgeFormatters formatters,
    SemanticColorResolver? resolver,
  ) {
    final result = this.result;

    // Scatter is the one display that consumes a paired result directly: it
    // plots x against y and has no single-series form to reduce to.
    if (kind == HandDrawnVisualizationKind.scatter) {
      if (result is! PairedResult) return _shapeError();
      return _renderScatter(
        pairedToScatter(result.x, result.y, formatters: formatters),
      );
    }

    // Every other kind renders one series. A SingleResult supplies it
    // directly; a PairedResult is first reduced to one series via [combination]
    // (aligned by bucket key in analytics_toolkit), then rendered through
    // exactly the same single-series path. The combination is orthogonal to
    // the chart kind, which is why "rate as a line", "net as bars", etc. need
    // no per-combination widget or kind.
    final AnalyticsResult single;
    switch (result) {
      case SingleResult(result: final r):
        single = r;
      case PairedResult(x: final x, y: final y):
        final combination = this.combination;
        if (combination == null) {
          return _errorBox(
            'A paired result needs a combination to render as "$displayType".',
          );
        }
        switch (SeriesAlgebra.combine(
          x,
          y,
          op: combination,
          policy: combinePolicy,
        )) {
          case Err(error: final e):
            return _errorBox(e.humanMessage);
          case Ok(value: final s):
            single = s;
        }
    }
    return _renderSingle(kind, single, palette, formatters, resolver);
  }

  Widget _renderSingle(
    HandDrawnVisualizationKind kind,
    AnalyticsResult result,
    BridgePalette palette,
    BridgeFormatters formatters,
    SemanticColorResolver? resolver,
  ) {
    switch (kind) {
      case HandDrawnVisualizationKind.bar:
      case HandDrawnVisualizationKind.groupedBar:
      case HandDrawnVisualizationKind.stackedBar:
        final mode = switch (kind) {
          HandDrawnVisualizationKind.groupedBar => BarMode.grouped,
          HandDrawnVisualizationKind.stackedBar => BarMode.stacked,
          _ => barMode,
        };
        return _renderBar(_barFor(result, mode, palette, formatters, resolver));
      case HandDrawnVisualizationKind.line:
      case HandDrawnVisualizationKind.multiLine:
        return _renderLine(_lineFor(result, palette, formatters, resolver));
      case HandDrawnVisualizationKind.streakLeaderboard:
        return _renderStreak(result, formatters);
      case HandDrawnVisualizationKind.table:
        return _renderTable(resultToTable(result, formatters: formatters));
      case HandDrawnVisualizationKind.bigNumber:
        return HandDrawnAnalyticsBigNumber(
          result: result,
          formatters: formatters,
        );
      case HandDrawnVisualizationKind.scatter:
        // Handled by _renderKind before reaching here.
        return _shapeError();
    }
  }

  // The spec-driven path uses each mapper's default axis formatting. The
  // integer-tick override lives on the standalone bar/line widgets, which is
  // where a caller in hand of the query can ask for it.
  Result<BarChartData, BridgeError> _barFor(
    AnalyticsResult result,
    BarMode mode,
    BridgePalette palette,
    BridgeFormatters formatters,
    SemanticColorResolver? resolver,
  ) {
    return switch (result) {
      SeriesResult() => seriesToBar(
        result,
        palette: palette,
        formatters: formatters,
        resolver: resolver,
      ),
      MultiSeriesResult() => multiSeriesToBar(
        result,
        mode: mode,
        palette: palette,
        formatters: formatters,
        resolver: resolver,
      ),
      MultiMeasureSeriesResult() => multiMeasureToBar(
        result,
        mode: mode,
        palette: palette,
        formatters: formatters,
        resolver: resolver,
      ),
      _ => Err(
        BridgeShapeMismatch(
          expected: ResultShape.series,
          actual: resultShapeOf(result),
          suggestion: 'a table or big-number display',
        ),
      ),
    };
  }

  Result<LineChartData, BridgeError> _lineFor(
    AnalyticsResult result,
    BridgePalette palette,
    BridgeFormatters formatters,
    SemanticColorResolver? resolver,
  ) {
    return switch (result) {
      SeriesResult() => seriesToLine(
        result,
        palette: palette,
        formatters: formatters,
        resolver: resolver,
      ),
      MultiSeriesResult() => multiSeriesToLine(
        result,
        palette: palette,
        formatters: formatters,
        resolver: resolver,
      ),
      MultiMeasureSeriesResult() => multiMeasureToLine(
        result,
        palette: palette,
        formatters: formatters,
        resolver: resolver,
      ),
      _ => Err(
        BridgeShapeMismatch(
          expected: ResultShape.series,
          actual: resultShapeOf(result),
          suggestion: 'a table or big-number display',
        ),
      ),
    };
  }

  // ── Renderers ───────────────────────────────────────────────────────────

  Widget _renderBar(Result<BarChartData, BridgeError> mapped) {
    final template = barTemplate ?? const HandDrawnBarChart(data: null);
    return switch (mapped) {
      Err(error: final e) => template.copyWith(
        data: const BarChartData(),
        emptyMessage: e.humanMessage,
      ),
      Ok(value: final data) =>
        builders?.bar?.call(data) ?? template.copyWith(data: data),
    };
  }

  Widget _renderLine(Result<LineChartData, BridgeError> mapped) {
    final template = lineTemplate ?? const HandDrawnLineChart(data: null);
    return switch (mapped) {
      Err(error: final e) => template.copyWith(
        data: _emptyLine,
        emptyMessage: e.humanMessage,
      ),
      Ok(value: final data) =>
        builders?.line?.call(data) ?? template.copyWith(data: data),
    };
  }

  Widget _renderScatter(Result<ScatterMapping, BridgeError> mapped) {
    final template = scatterTemplate ?? const HandDrawnScatterPlot(data: null);
    return switch (mapped) {
      Err(error: final e) => template.copyWith(
        data: _emptyScatter,
        emptyMessage: e.humanMessage,
      ),
      Ok(value: final m) =>
        builders?.scatter?.call(m) ?? template.copyWith(data: m.data),
    };
  }

  Widget _renderTable(Result<TableMapping, BridgeError> mapped) {
    final template =
        tableTemplate ?? const HandDrawnTable(columns: [], rows: []);
    return switch (mapped) {
      Err(error: final e) => template.copyWith(
        columns: const [HandDrawnTableColumn(header: '')],
        rows: const [],
        emptyMessage: e.humanMessage,
      ),
      // The default rendering goes through [HandDrawnTableView], which styles
      // itself from the template and renders the whole [TableMapping] —
      // including the truncation footer when rows were capped.
      Ok(value: final m) =>
        builders?.table?.call(m) ??
            HandDrawnTableView(mapping: m, chart: template),
    };
  }

  /// Streak results get the leaderboard layout, falling back to a generic table
  /// projection when the result isn't streak-shaped.
  Widget _renderStreak(AnalyticsResult result, BridgeFormatters formatters) {
    if (result is TableResult) {
      final streak = streakToTable(result, formatters: formatters);
      if (streak != null) {
        return _renderTable(Ok(streak));
      }
    }
    return _renderTable(resultToTable(result, formatters: formatters));
  }

  Widget _shapeError() =>
      _errorBox('This data cannot be shown as "$displayType".');

  Widget _errorBox(String message) => HandDrawnContainer(child: Text(message));

  static const LineChartData _emptyLine = LineChartData(
    series: [],
    minX: 0,
    maxX: 1,
    minY: 0,
    maxY: 1,
  );
  static const ScatterPlotData _emptyScatter = ScatterPlotData(
    points: [],
    minX: 0,
    maxX: 1,
    minY: 0,
    maxY: 1,
  );
}

/// A predicate deciding whether a widget should reload in response to an
/// [AnalyticsChange]. [mySourceIds] is the set of source ids the widget reads.
typedef AnalyticsCardReloadPredicate =
    bool Function(AnalyticsChange change, Set<String> mySourceIds);

/// The default reload policy (matches the locked change semantics):
///
/// * `dateRange` → don't reload. A widget receives its date range through its
///   own props (the page range, its date-range mode) and refetches when those
///   change, so a trigger reload would re-run the query with the same inputs.
/// * `sourceData` → reload only if the changed sources intersect [mySourceIds]
///   (a null change scope means "all sources", so reload).
/// * `widgetSet`, `widgetOrder`, `restore` → don't reload (no data this widget
///   reads has changed).
bool defaultShouldReload(AnalyticsChange change, Set<String> mySourceIds) {
  return switch (change.kind) {
    AnalyticsChangeKind.dateRange => false,
    AnalyticsChangeKind.sourceData =>
      change.sourceIds == null ||
          change.sourceIds!.intersection(mySourceIds).isNotEmpty,
    AnalyticsChangeKind.widgetSet ||
    AnalyticsChangeKind.widgetOrder ||
    AnalyticsChangeKind.restore => false,
  };
}
