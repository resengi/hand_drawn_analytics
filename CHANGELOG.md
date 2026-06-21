# Change Log



## 2026-06-21

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`hand_drawn_analytics` - `v0.1.0+1`](#hand_drawn_analytics---v0101)

---

#### `hand_drawn_analytics` - `v0.1.0+1`

 - **FIX**: attempting to address deployment issues ([#3](https://github.com/resengi/hand_drawn_analytics/issues/3)). ([67f2b785](https://github.com/resengi/hand_drawn_analytics/commit/67f2b78559c1a857c37d244be2e683d27dfb58ef))
 - **FIX**: patching the pubspec.yaml file ([#2](https://github.com/resengi/hand_drawn_analytics/issues/2)). ([f69ecf3f](https://github.com/resengi/hand_drawn_analytics/commit/f69ecf3fc4ebb6a520a73cff50ffced7a84158d3))

## 0.1.0+1

 - **FIX**: attempting to address deployment issues ([#3](https://github.com/resengi/hand_drawn_analytics/issues/3)). ([67f2b785](https://github.com/resengi/hand_drawn_analytics/commit/67f2b78559c1a857c37d244be2e683d27dfb58ef))
 - **FIX**: patching the pubspec.yaml file ([#2](https://github.com/resengi/hand_drawn_analytics/issues/2)). ([f69ecf3f](https://github.com/resengi/hand_drawn_analytics/commit/f69ecf3fc4ebb6a520a73cff50ffced7a84158d3))

# Changelog

## 0.1.0

Initial release.

A bridge between `analytics_toolkit` (a rendering-agnostic query engine) and
`hand_drawn_toolkit` (sketchy chart and table widgets): it runs a typed query,
maps the result into the toolkit's data class, and renders it, defaulting only
the values the consumer left unset.

- **Query-backed widgets**: `HandDrawnAnalyticsBarChart`,
  `HandDrawnAnalyticsLineChart`, `HandDrawnAnalyticsScatterPlot`, and
  `HandDrawnAnalyticsTable`, plus the `HandDrawnAnalyticsBigNumber` leaf and the
  `HandDrawnAnalyticsStreakLeaderboard`. Each styles itself from a
  `hand_drawn_toolkit` template built with `data: null`.
- **Spec-driven cards**: `HandDrawnAnalyticsCard` decodes a persisted
  `AnalyticsWidgetSpec` (query, display type, and date-range mode, all JSON),
  runs it, dispatches by display type, and reloads on typed `AnalyticsChange`
  events; `AnalyticsScalarCard` covers the single-KPI case.
- **One-scope configuration**: `AnalyticsScope` supplies a shared runner,
  palette, formatters, color resolver, and display aliases to a subtree, with a
  runner that stays instance-stable across rebuilds so widgets refetch only when
  the data source actually changes.
- **Display-type dispatch**: `HandDrawnAnalyticsWidget` routes an
  already-computed result to a widget by a free-form `displayType` string, with
  consumer aliases and an optional `AnalyticsWidgetBuilders` registry for custom
  rendering of mapped data.
- **Paired-query rendering**: scatter plots consume a paired result directly;
  every other display reduces a paired result to one series with a
  `SeriesCombination` aligned by bucket key.
- **Pure mapper layer**: every result-to-chart-data conversion is an exported
  pure function (`seriesToBar`, `pairedToScatter`, `resultToTable`, …).
- **Typed, graceful failure**: expected problems surface as a sealed
  `BridgeError` family rendered as the toolkit's own empty states, never thrown.
- **Semantic coloring**: a resolver → tag-pin → positional-palette resolution
  order via `BridgePalette`.
- **Locale-aware formatting**: one `BridgeFormatters` policy object for table
  cells, big numbers, axis ticks, unit labels, and bucket-key labels, reactive
  to runtime locale switches.`BridgeFormatters` policy object for table
  cells, big numbers, axis ticks, unit labels, and bucket-key labels, reactive
  to runtime locale switches.