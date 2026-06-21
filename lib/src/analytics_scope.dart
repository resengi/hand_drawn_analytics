import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';

import 'colors.dart';
import 'formatters.dart';
import 'runner.dart';

/// The closed set of visualizations the bridge knows how to render.
///
/// This is the bridge's display vocabulary. It is deliberately the bridge's
/// concern and not the analytics layer's: `DisplaySpec.displayType` is a
/// free-form string opaque to `analytics_toolkit`, so the mapping from that
/// string to a concrete widget lives here, behind [resolve].
enum HandDrawnVisualizationKind {
  bar,
  groupedBar,
  stackedBar,
  line,
  multiLine,
  scatter,
  table,
  bigNumber,
  streakLeaderboard;

  /// The canonical lower-camel token for this kind, used as the default
  /// spelling when matching a `displayType` string.
  String get canonicalName => name;

  /// Resolves a free-form [displayType] to a kind.
  ///
  /// Matching is: exact canonical-name match first, then a consumer-provided
  /// [aliases] map (alias → canonical name). Unknown strings yield an
  /// [Err] of [UnknownDisplayType] so the caller can render guidance rather
  /// than guessing a default.
  static Result<HandDrawnVisualizationKind, UnknownDisplayType> resolve(
    String displayType, {
    Map<String, String> aliases = const {},
  }) {
    for (final kind in values) {
      if (kind.canonicalName == displayType) return Ok(kind);
    }
    final aliased = aliases[displayType];
    if (aliased != null) {
      for (final kind in values) {
        if (kind.canonicalName == aliased) return Ok(kind);
      }
    }
    return Err(UnknownDisplayType(displayType));
  }
}

/// Returned by [HandDrawnVisualizationKind.resolve] when a `displayType`
/// string matches neither a canonical name nor a configured alias.
class UnknownDisplayType {
  const UnknownDisplayType(this.displayType);

  /// The unrecognized display-type string.
  final String displayType;

  @override
  String toString() => 'UnknownDisplayType($displayType)';
}

/// Carries shared bridge configuration down the widget tree for the common
/// one-config-per-page case.
///
/// Every bridge widget can read its sources, cache, palette, formatters,
/// color resolver, and display aliases from the nearest enclosing scope, so a
/// dashboard configures them once rather than threading them through every
/// widget. Any individual widget may still override a field locally.
///
/// The scope also derives and owns a [WidgetQueryRunner] for widgets that are
/// not given one explicitly. The runner lives in the scope's [State], so it is
/// stable across rebuilds: a new instance is created only when [sources] or
/// [cache] is replaced. Descendants read the scope through
/// [AnalyticsScope.of] / [AnalyticsScope.maybeOf], which return the
/// [AnalyticsScopeData] this widget publishes.
class AnalyticsScope extends StatefulWidget {
  const AnalyticsScope({
    required this.sources,
    required this.cache,
    required this.child,
    this.palette = const BridgePalette(),
    this.formatters = const BridgeFormatters(),
    this.colorResolver,
    this.displayAliases = const {},
    super.key,
  });

  /// The source catalog queries validate and execute against.
  ///
  /// Treat the list as immutable while it is in scope: to change the catalog,
  /// pass a different list instance. The scope detects change by identity and
  /// derives a fresh [AnalyticsScopeData.runner] from the new instance;
  /// in-place mutation changes neither.
  final List<SourceDef> sources;

  /// The per-page record cache. Hosts compose its `getOrFetch` into the
  /// runner's fetch seam.
  ///
  /// As with [sources], treat it as immutable while in scope and pass a
  /// different instance to change it.
  final SourceSnapshotCache cache;

  /// Default palette for series / segment coloring.
  final BridgePalette palette;

  /// Default display-formatting policy.
  final BridgeFormatters formatters;

  /// Optional semantic color resolver consulted ahead of the palette.
  final SemanticColorResolver? colorResolver;

  /// Display-type aliases (alias → canonical kind name) used by
  /// [HandDrawnVisualizationKind.resolve] when dispatching by display type.
  final Map<String, String> displayAliases;

  /// The subtree this scope configures.
  final Widget child;

  /// The nearest enclosing scope's data, or `null` if there is none.
  static AnalyticsScopeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AnalyticsScopeData>();

  /// The nearest enclosing scope's data. Asserts (in debug) when absent — use
  /// [maybeOf] when the scope is optional.
  static AnalyticsScopeData of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'No AnalyticsScope found in the widget tree.');
    return scope!;
  }

  @override
  State<AnalyticsScope> createState() => _AnalyticsScopeState();
}

class _AnalyticsScopeState extends State<AnalyticsScope> {
  late WidgetQueryRunner _runner = _buildRunner();

  /// Builds a runner over a snapshot of the current [AnalyticsScope.sources]
  /// and [AnalyticsScope.cache] references.
  ///
  /// Capturing the snapshot — rather than reading through `widget` — keeps a
  /// runner's behavior fixed to the data source it was created from, so
  /// identity and meaning stay in lockstep even while an older runner is
  /// still held by an in-flight controller.
  WidgetQueryRunner _buildRunner() {
    final sources = widget.sources;
    final cache = widget.cache;
    return WidgetQueryRunner(
      listSources: () => sources,
      fetchRecords: (sourceId, {dateBound}) =>
          cache.getOrFetch(sourceId, dateBound: dateBound),
    );
  }

  @override
  void didUpdateWidget(AnalyticsScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The runner is replaced only when the data source itself is replaced;
    // render-only fields (palette, formatters, …) flow through without
    // touching it. [WidgetQueryRunner] holds no resources, so the previous
    // instance needs no teardown.
    if (!identical(widget.sources, oldWidget.sources) ||
        !identical(widget.cache, oldWidget.cache)) {
      _runner = _buildRunner();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnalyticsScopeData(
      sources: widget.sources,
      cache: widget.cache,
      palette: widget.palette,
      formatters: widget.formatters,
      colorResolver: widget.colorResolver,
      displayAliases: widget.displayAliases,
      runner: _runner,
      child: widget.child,
    );
  }
}

/// The configuration an [AnalyticsScope] publishes to its descendants.
///
/// Constructed by the scope and read through [AnalyticsScope.of] /
/// [AnalyticsScope.maybeOf]. [updateShouldNotify] compares field by field, so
/// dependents rebuild only when something they could actually consume has
/// changed.
class AnalyticsScopeData extends InheritedWidget {
  const AnalyticsScopeData({
    required this.sources,
    required this.cache,
    required this.palette,
    required this.formatters,
    required this.colorResolver,
    required this.displayAliases,
    required this.runner,
    required super.child,
    super.key,
  });

  /// The source catalog queries validate and execute against.
  final List<SourceDef> sources;

  /// The per-page record cache backing [runner]'s fetch seam.
  final SourceSnapshotCache cache;

  /// Default palette for series / segment coloring.
  final BridgePalette palette;

  /// Default display-formatting policy.
  final BridgeFormatters formatters;

  /// Optional semantic color resolver consulted ahead of the palette.
  final SemanticColorResolver? colorResolver;

  /// Display-type aliases (alias → canonical kind name) used by
  /// [HandDrawnVisualizationKind.resolve] when dispatching by display type.
  final Map<String, String> displayAliases;

  /// The runner derived from [sources] and [cache].
  ///
  /// Bridge widgets that aren't given an explicit runner fall back to this,
  /// so the common case — one configured scope per page — needs no per-widget
  /// runner wiring. `listSources` returns [sources]; `fetchRecords` reads
  /// through [cache]'s `getOrFetch`.
  ///
  /// The instance is stable across scope rebuilds while [sources] and [cache]
  /// are identity-unchanged, so a different runner instance means the data
  /// source changed. Hosts compare it by identity to decide when to refetch.
  final WidgetQueryRunner runner;

  @override
  bool updateShouldNotify(AnalyticsScopeData oldWidget) {
    // A sources/cache replacement implies a new [runner], so the runner needs
    // no comparison of its own.
    return !identical(sources, oldWidget.sources) ||
        !identical(cache, oldWidget.cache) ||
        palette != oldWidget.palette ||
        formatters != oldWidget.formatters ||
        colorResolver != oldWidget.colorResolver ||
        !mapEquals(displayAliases, oldWidget.displayAliases);
  }
}
