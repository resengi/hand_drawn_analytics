/// A bridge between `analytics_toolkit` (a rendering-agnostic query engine) and
/// `hand_drawn_toolkit` (sketchy chart and table widgets).
///
/// Configure a `hand_drawn_toolkit` chart as a styling template (with
/// `data: null`), hand it plus a typed analytics query to one of the
/// `HandDrawnAnalytics*` widgets, and the bridge runs the query, maps the
/// result into the toolkit's data class, and renders it — defaulting only the
/// values you left unset, never reinterpreting your query.
library;

export 'src/analytics_scope.dart';
export 'src/cards/cards.dart';
export 'src/colors.dart';
// Display-type dispatch and dashboard cards.
export 'src/dispatch/widget_dispatcher.dart';
// Foundation vocabulary.
export 'src/errors.dart';
export 'src/formatters.dart';
// Pure mappers (result → chart data).
export 'src/mappers/mapper_support.dart';
export 'src/mappers/to_bar_chart.dart';
export 'src/mappers/to_line_chart.dart';
export 'src/mappers/to_scatter_plot.dart';
export 'src/mappers/to_table.dart';
export 'src/runner.dart';
// Query-backed widgets.
export 'src/widgets/analytics_bar_chart.dart';
export 'src/widgets/analytics_line_chart.dart';
export 'src/widgets/analytics_scatter_plot.dart';
export 'src/widgets/analytics_table.dart';

// NOT exported (internal plumbing):
//   src/controller/query_controller.dart
//   src/controller/chart_host.dart
//   src/widgets/chart_internals.dart
